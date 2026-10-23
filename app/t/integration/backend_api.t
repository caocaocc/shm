use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP ();
use URI::Escape qw(uri_escape_utf8);
use File::Temp qw(tempfile);
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
my ($group_id, $service_id, $period_id, $us_id, $wd_id, $owner, $other, $actor);
my @users;
my ($trap_fh, $network_trap) = tempfile('shm-api-network-XXXX', TMPDIR => 1, UNLINK => 1);
close $trap_fh;
my $order_id = 'api_fixture_' . $$ . '_' . int(rand(1_000_000));

sub cleanup {
    return unless $dbh;
    eval {
        $dbh->rollback;
        if ($period_id) {
            $dbh->do('DELETE FROM consumption_readings WHERE period_id=?', undef, $period_id);
            $dbh->do('DELETE FROM consumption_generations WHERE period_id=?', undef, $period_id);
            $dbh->do('DELETE FROM consumption_periods WHERE id=?', undef, $period_id);
        }
        $dbh->do('DELETE FROM epay_orders WHERE out_trade_no=?', undef, $order_id);
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
    unlink $network_trap if defined $network_trap;
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
my $policy = {mode => 'PREPAID', quotas => {traffic => {limit => '10', unit => 'unit'}}};
$dbh->do('INSERT INTO services (name,cost,period,category,config) VALUES (?,30,1,?,?)',
    undef, 'Backend API isolated fixture', 'api-' . $$, encode_json({consumption => $policy}));
$service_id = $dbh->{mysql_insertid};
my $fixture_epoch = time;
my ($start, $end, $cutoff) = map { utime_to_string($_) }
    ($fixture_epoch - 3600, $fixture_epoch + 3600, $fixture_epoch - 60);
my ($start_epoch, $end_epoch) = ($fixture_epoch - 3600, $fixture_epoch + 3601);
$dbh->do('INSERT INTO user_services (user_id,service_id,expire,status_before,status,settings) VALUES (?,?,?,?,?,?)',
    undef, $owner, $service_id, $end, STATUS_INIT, STATUS_ACTIVE, '{}');
$us_id = $dbh->{mysql_insertid};
$dbh->do('INSERT INTO withdraw_history (user_id,service_id,user_service_id,withdraw_date,end_date,cost,total) VALUES (?,?,?,?,?,30,30)',
    undef, $owner, $service_id, $us_id, $start, $end);
$wd_id = $dbh->{mysql_insertid};
$dbh->do('UPDATE user_services SET withdraw_id=? WHERE user_service_id=?', undef, $wd_id, $us_id);
$dbh->do('INSERT INTO consumption_periods (withdraw_id,user_service_id,user_id,service_id,policy,currency,starts_at,ends_at,starts_epoch,ends_epoch,timezone,paid_cash,paid_bonus) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0)',
    undef, $wd_id, $us_id, $owner, $service_id, encode_json($policy), 'CNY', $start, $end,
    $start_epoch, $end_epoch, $ENV{TZ} || 'Asia/Shanghai', '30.00');
$period_id = $dbh->{mysql_insertid};
$dbh->do('INSERT INTO epay_orders (out_trade_no,user_id,profile,protocol,pid,key_version,gateway_id,config_fingerprint,profile_config,amount_cents,currency) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    undef, $order_id, $owner, 'unconfigured_api_fixture', 'v2_rsa', '1001', 'fixture',
    '0' x 32, '0' x 64, '{}', 12345, 'CNY');
$dbh->commit;

my $json = JSON::PP->new->utf8->canonical;
my $runner = <<'PERL';
use SHM;
use Core::Epay;
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
    *Core::Epay::_http = sub {
        open my $trap, '>>', $ENV{SHM_API_NETWORK_TRAP} or die $!;
        print $trap "gateway contacted\n";
        close $trap;
        die "Network is forbidden in backend_api.t\n";
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
    $ENV{SHM_API_NETWORK_TRAP} = $network_trap;
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
my ($status, $response) = request($owner, 'GET', '/user/service/consumption', \%binding);
is($status, 200, 'owner reads consumption through CGI');
is($response->{data}[0]{period_id}, $period_id, 'CGI dispatches requested period');
($status, $response) = request($other, 'GET', '/user/service/consumption', \%binding);
is($status, 403, 'CGI refuses another user consumption snapshot');
($status, $response) = request($actor, 'GET', '/admin/consumption', \%binding);
is($status, 200, 'administrator reads another user consumption');
($status, $response) = request($owner, 'POST', '/admin/consumption/generation', {});
is($status, 403, 'admin route denies client before controller validation');
($status, $response) = request($actor, 'POST', '/admin/user/service/withdraw',
    {%binding, user_id => $owner, cost => 1, total => 1});
is($status, 409, 'frozen withdrawal rejects generic admin edit through CGI');
($status, $response) = request($actor, 'DELETE', '/admin/user/service/withdraw',
    {withdraw_id => $wd_id, user_id => $owner});
is($status, 409, 'frozen withdrawal rejects generic admin deletion through CGI');
$dbh->commit;
is($dbh->selectrow_array('SELECT total FROM withdraw_history WHERE withdraw_id=?', undef, $wd_id),
    '30.00', 'frozen withdrawal survives generic mutation attempts');

my %meter = (%binding, meter => 'traffic', generation => 'fixture', observed_at => $cutoff);
my $baseline = '99999999999999999999999999.000000000001';
my $cumulative = '99999999999999999999999999.123456789013';
($status, $response) = request($actor, 'POST', '/admin/consumption/generation',
    {%meter, record_id => 'baseline', baseline => $baseline}, 'form');
is($status, 200, 'form generation route accepts full DECIMAL precision');
($status, $response) = request($actor, 'POST', '/admin/consumption/reading',
    {%meter, record_id => 'reading', cumulative => $cumulative});
is($status, 200, 'JSON reading route preserves decimal strings');
is($response->{data}[0]{totals}{traffic}, '0.123456789012', 'router never coerces reading through floating point');
$dbh->commit; # Refresh the parent READ COMMITTED connection before assertions.
is($dbh->selectrow_array('SELECT cumulative FROM consumption_readings WHERE period_id=? AND record_id=?',
    undef, $period_id, 'reading'), $cumulative, 'full precision persisted from CGI');
($status, $response) = request($actor, 'POST', '/admin/consumption/reading',
    {%meter, record_id => 'reading', cumulative => $cumulative});
is($status, 200, 'exact reading replay succeeds');
is($response->{data}[0]{duplicate}, 1, 'exact reading replay is identified');
($status, $response) = request($actor, 'POST', '/admin/consumption/reading',
    {%meter, record_id => 'reading', cumulative => $baseline});
is($status, 409, 'conflicting record replay stays HTTP 409');
($status, $response) = request($actor, 'POST', '/admin/consumption/generation',
    {%meter, record_id => 'duplicate-generation', baseline => $baseline});
is($status, 409, 'existing generation stays HTTP 409');
($status, $response) = request($actor, 'POST', '/admin/consumption/reading',
    {%meter, record_id => 'backwards', cumulative => $baseline});
is($status, 409, 'decreased counter stays HTTP 409');
($status, $response) = request($actor, 'POST', '/admin/consumption/finalize',
    {%binding, cutoff => utime_to_string(time - 30)});
is($status, 409, 'finalization refuses stale meter coverage');
($status, $response) = request($actor, 'POST', '/admin/consumption/finalize', {%binding, cutoff => $cutoff});
is($status, 200, 'trusted finalization dispatches through CGI');
is($response->{data}[0]{finalized}, 1, 'finalized state returned');
($status, $response) = request($actor, 'POST', '/admin/consumption/finalize', {%binding, cutoff => $cutoff});
is($status, 200, 'identical finalization is idempotent');
is($response->{data}[0]{duplicate}, 1, 'identical finalization replay identified');
($status, $response) = request($actor, 'POST', '/admin/consumption/finalize',
    {%binding, cutoff => utime_to_string(time - 90)});
is($status, 409, 'conflicting finalization stays HTTP 409');
($status, $response) = request($actor, 'POST', '/admin/consumption/reading',
    {%meter, record_id => 'after-finalize', cumulative => $cumulative});
is($status, 409, 'finalized period refuses later reading');

($status, $response) = request($owner, 'GET', '/user/epay/order', {out_trade_no => $order_id});
is($status, 200, 'owner reads local epay state without gateway');
is($response->{data}[0]{amount_cents}, 12345, 'epay state exposes integer cents');
($status, $response) = request($other, 'GET', '/user/epay/order', {out_trade_no => $order_id});
is($status, 400, 'epay controller refuses another user order');
($status, $response) = request($owner, 'GET', '/user/epay/order', {out_trade_no => $order_id . '_missing'});
is($status, 400, 'unknown epay order produces an error');
ok($response->{error}, 'unknown order includes error response');
for my $path ('/user/epay/order', '/user/epay/reconcile', '/admin/epay/reconcile') {
    my $user_id = $path =~ /^\/admin/ ? $actor : $owner;
    ($status, $response) = request($user_id, 'POST', $path,
        {dry_run => 1, amount => '1.00', out_trade_no => $order_id, ps => 'unconfigured_api_fixture'});
    is($status, 400, "$path refuses dry_run before gateway work");
    like($response->{error}, qr/dry_run/, 'dry_run has a specific refusal');
}
($status, $response) = request($owner, 'POST', '/admin/epay/reconcile', {out_trade_no => $order_id});
is($status, 403, 'client cannot reach admin reconciliation');
$dbh->commit;
is($dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id IN (?,?,?)', undef, @users),
    1, 'dry_run creates no order');
is(-s $network_trap || 0, 0, 'no request contacted an external gateway');

($status, $response) = request($actor, 'DELETE', '/admin/user', {user_id => $owner, force => 1});
is($status, 409, 'force-delete cannot orphan frozen orders and periods');
is($dbh->selectrow_array('SELECT COUNT(*) FROM user_services WHERE user_service_id=?', undef, $us_id),
    1, 'rejected user deletion leaves the existing service intact');
$dbh->do('INSERT INTO pays_history (user_id,money,pay_system_id) VALUES (?,123.45,?)', undef, $owner, 'epay');
my $payment_id = $dbh->{mysql_insertid};
$dbh->do("UPDATE epay_orders SET payment_id=?,state='PAID' WHERE out_trade_no=?", undef, $payment_id, $order_id);
$dbh->commit;
($status, $response) = request($actor, 'DELETE', '/admin/user/pay', {user_id => $owner, id => $payment_id});
is($status, 409, 'gateway credit records cannot be deleted through the generic API');
is($dbh->selectrow_array('SELECT COUNT(*) FROM pays_history WHERE id=?', undef, $payment_id),
    1, 'rejected payment deletion preserves the durable credit');

cleanup();
done_testing;
