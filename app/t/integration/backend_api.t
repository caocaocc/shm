use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP ();
use URI::Escape qw(uri_escape_utf8);
use SHM;
use Core::Const;
use Core::Utils qw(utime_to_string encode_json);
use Core::System::ServiceManager qw(get_service);

# Exercise the real CGI router in fresh processes, with committed, isolated
# fixtures. No global billing/payment configuration or gateway is changed.
my $admin = SHM->new(user_id => 1);
my $dbh = $admin->dbh;
$dbh->{RaiseError} = 1;
my $database = $dbh->selectrow_array('SELECT DATABASE()');
plan skip_all => 'backend API integration requires an isolated *_test database'
    unless $database && $database =~ /(?:_test|test_)\b/;
my ($group_id, $service_id, $us_id, $wd_id, $owner, $other, $actor);
my @users;
my $audit_table = 'test_ledger_reference_' . $$;
my $created_audit_table;

sub cleanup {
    return unless $dbh;
    eval {
        $dbh->rollback;
        $dbh->do("DROP TABLE `$audit_table`") if $created_audit_table;
        for my $user_id (@users) {
            $dbh->do("DELETE FROM $_ WHERE user_id=?", undef, $user_id)
                for qw(logs_api spool spool_history withdraw_history pays_history bonus_history user_services);
            $dbh->do('DELETE FROM users WHERE user_id=?', undef, $user_id);
        }
        $dbh->do('DELETE FROM services WHERE service_id=?', undef, $service_id) if $service_id;
        $dbh->do('DELETE FROM user_groups WHERE gid=?', undef, $group_id) if $group_id;
        $dbh->commit;
        1;
    } or diag('isolated API fixture cleanup failed: ' . $@);
    undef $dbh;
}
END { cleanup() }

$dbh->do('INSERT INTO user_groups (name,is_admin,default_policy,rules) VALUES (?,1,?,?)',
    undef, 'backend-api-' . $$, 'allow', '[]');
$group_id = $dbh->{mysql_insertid};
for my $gid (0, 0, $group_id) {
    $dbh->do('INSERT INTO users (login,balance,credit,bonus,gid,settings) VALUES (?,0,0,0,?,?)',
        undef, 'backend-api-' . $$ . '-' . scalar(@users), $gid, '{}');
    push @users, $dbh->{mysql_insertid};
}
($owner, $other, $actor) = @users;
$dbh->do('INSERT INTO services (name,cost,period,category,config) VALUES (?,30,1,?,?)',
    undef, 'Backend API isolated fixture', 'api-' . $$, encode_json({remnawave => {traffic_limit_bytes => 1000}}));
$service_id = $dbh->{mysql_insertid};
my $fixture_epoch = time;
my ($start, $end) = map { utime_to_string($_) } ($fixture_epoch - 3600, $fixture_epoch + 3600);
$dbh->do('INSERT INTO user_services (user_id,service_id,expire,status_before,status,settings) VALUES (?,?,?,?,?,?)',
    undef, $owner, $service_id, $end, STATUS_INIT, STATUS_ACTIVE, '{}');
$us_id = $dbh->{mysql_insertid};
$dbh->do('INSERT INTO withdraw_history (user_id,service_id,user_service_id,withdraw_date,end_date,cost,total) VALUES (?,?,?,?,?,30,30)',
    undef, $owner, $service_id, $us_id, $start, $end);
$wd_id = $dbh->{mysql_insertid};
$dbh->do('UPDATE user_services SET withdraw_id=? WHERE user_service_id=?', undef, $wd_id, $us_id);
$dbh->do('UPDATE withdraw_history SET `usage`=? WHERE withdraw_id=?', undef,
    encode_json({limit_bytes=>1000, start_bytes=>647, start_reset_at=>undef, used_bytes=>0}), $wd_id);
$dbh->commit;

my $json = JSON::PP->new->utf8->canonical;
my $runner = <<'PERL';
use SHM;
# USER_ID is a trusted test-process environment value, never HTTP input. The
# router passes user_id=>undef, so preserve this actor only inside this runner.
my $new = \&SHM::new;
{
    no warnings 'redefine';
    *SHM::new = sub {
        my ($class, %args) = @_;
        $args{user_id} = $ENV{USER_ID} unless defined $args{user_id};
        return $new->($class, %args);
    };
}
do '/app/public_html/shm/v1.cgi';
die $@ if $@;
PERL

sub request {
    my ($user_id, $method, $path, $params, $format) = @_;
    $params ||= {};
    $format ||= 'json';
    my $form = join('&', map { uri_escape_utf8($_) . '=' . uri_escape_utf8($params->{$_}) } sort keys %$params);
    # CGI.pm exposes DELETE parameters from the query string, like the existing
    # SHM clients; JSON request bodies are used for POST/PUT.
    my $query_method = $method eq 'GET' || $method eq 'DELETE';
    my $body = $query_method ? '' : $format eq 'form' ? $form : $json->encode($params);
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION HTTP_SESSION_ID HTTP_LOGIN HTTP_PASSWORD HTTP_TEST SHM_TEST)};
    @ENV{qw(USER_ID REQUEST_METHOD SCRIPT_NAME PATH_INFO QUERY_STRING CONTENT_TYPE CONTENT_LENGTH REMOTE_ADDR)} =
        ($user_id, $method, '/shm/v1.cgi', $path, $query_method ? $form : '',
        $format eq 'form' ? 'application/x-www-form-urlencoded' : 'application/json', length($body), '127.0.0.1');
    my ($input, $output, $error) = (undef, undef, gensym);
    my $pid = open3($input, $output, $error, $^X, '-I/app/lib', '-e', $runner);
    print $input $body;
    close $input;
    my $stdout = do { local $/; <$output> } // '';
    my $stderr = do { local $/; <$error> } // '';
    waitpid($pid, 0);
    my ($headers, $payload) = split(/\r?\n\r?\n/, $stdout, 2);
    my $response = eval { $json->decode($payload // '') };
    die "CGI response was not JSON: $stdout\n$stderr" unless ref $response eq 'HASH';
    my ($status) = ($headers // '') =~ /^Status:\s*(\d+)/mi;
    $status //= $response->{status} // 200;
    return ($status, $response);
}

my %binding = (user_service_id => $us_id, withdraw_id => $wd_id);
my ($status, $response) = request($owner, 'GET', '/user/withdraw', {withdraw_id => $wd_id});
is($status, 200, 'owner reads bill through native CGI');
is_deeply($response->{data}[0]{usage}, {limit_bytes=>1000, used_bytes=>0}, 'history shows zero and hides the opening sample');
($status, $response) = request($other, 'GET', '/user/withdraw', {withdraw_id => $wd_id});
is_deeply($response->{data}, [], 'another customer cannot see this bill');
($status, $response) = request($actor, 'POST', '/admin/user/service/withdraw',
    {%binding, user_id => $owner, cost => 1, total => 1});
is($status, 409, 'frozen withdrawal rejects generic admin edit through CGI');
($status, $response) = request($actor, 'DELETE', '/admin/user/service/withdraw',
    {withdraw_id => $wd_id, user_id => $owner});
is($status, 409, 'frozen withdrawal rejects generic admin deletion through CGI');
$dbh->commit;
is($dbh->selectrow_array('SELECT total FROM withdraw_history WHERE withdraw_id=?', undef, $wd_id),
    '30.00', 'frozen withdrawal survives generic mutation attempts');

($status, $response) = request($actor, 'DELETE', '/admin/user', {user_id => $owner, force => 1});
is($status, 409, 'a prepaid period protects the owner before any dependent records are removed');
is($dbh->selectrow_array('SELECT COUNT(*) FROM user_services WHERE user_service_id=?', undef, $us_id),
    1, 'rejected user deletion preserves the existing service');

# A separately installed module can reference native rows without registering
# hooks with core. Use a real table so the CGI's connection can see its keys.
$dbh->do("CREATE TABLE `$audit_table` (owner_id INT NOT NULL, payment_id INT NOT NULL,
    FOREIGN KEY (owner_id) REFERENCES users(user_id),
    FOREIGN KEY (payment_id) REFERENCES pays_history(id)) ENGINE=InnoDB");
$created_audit_table = 1;
$dbh->do('INSERT INTO pays_history (user_id,money,pay_system_id) VALUES (?,123.45,?)',
    undef, $other, 'local');
my $payment_id = $dbh->{mysql_insertid};
$dbh->do("INSERT INTO `$audit_table` (owner_id,payment_id) VALUES (?,?)", undef, $other, $payment_id);
$dbh->commit;

($status, $response) = request($actor, 'DELETE', '/admin/user', {user_id => $other, force => 1});
is($status, 409, 'a restrictive external reference protects a non-metered account');
($status, $response) = request($actor, 'DELETE', '/admin/user/pay', {user_id => $other, id => $payment_id});
is($status, 409, 'a referenced payment cannot be deleted through the generic API');
is($dbh->selectrow_array('SELECT COUNT(*) FROM pays_history WHERE id=?', undef, $payment_id),
    1, 'rejected payment deletion preserves the credit');

cleanup();
done_testing;
