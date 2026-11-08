use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
BEGIN {
    plan skip_all => 'requires SHM_SQL_CONFIG_TEST=1 and an isolated *_test database'
        unless ($ENV{SHM_SQL_CONFIG_TEST} // '') eq '1' && ($ENV{DB_NAME} // '') =~ /_test\z/;
}
use HTTP::Daemon;
use HTTP::Response;
use JSON::PP ();
use Compress::Zlib qw(memGzip);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use File::Temp qw(tempfile);
use MIME::Base64 qw(encode_base64);
use POSIX ();
use SHM;
use Core::ServiceOptions;
use Core::Const;
use Core::Utils qw(switch_user utime_to_string);
use Core::System::ServiceManager qw(get_service);

# This is an actual commit/worker boundary test. The container's general test
# bypass suppresses Core::Sql::Data::commit and must not be inherited here.
local @ENV{qw(SHM_TEST HTTP_TEST)};
delete @ENV{qw(SHM_TEST HTTP_TEST)};

my $JSON = JSON::PP->new->canonical->utf8;
my $token = 'NATIVE-E2E-PANEL-TOKEN';
my @private_markers = ($token, 'NATIVE-E2E-SECRET-ONE', 'NATIVE-E2E-SECRET-TWO', 'NATIVE-E2E-INVALID-SECRET', 'NATIVE-E2E-REMOTE-ERROR', 'NATIVE-E2E-ORIGINAL-TEXT');
my @preset_out = ('Out Direct', 'Out Block', 'Out Nodes', 'Out VPN', 'Out Users');
my @preset_routes = ('Routing Private', 'Routing Secure', 'Routing Direct', 'Routing Services', 'Routing Locator', 'Routing Users', 'Routing vlessRoute');
my %platform = (
    '平台说明' => [{note => '平台保留配置，包含中文与 emoji 😀；不由分流模块修改'}],
    'Out Direct' => [{protocol => 'freedom', tag => 'direct'}],
    'Out Block' => [{protocol => 'blackhole', tag => 'block'}],
    'Out Nodes' => [{protocol => 'freedom', tag => 'nodes'}],
    'Out VPN' => [{protocol => 'freedom', tag => 'vpn'}],
    'Routing Private' => [{type => 'field', ip => ['geoip:private'], outboundTag => 'block'}],
    'Routing Secure' => [{type => 'field', protocol => ['bittorrent'], outboundTag => 'block'}],
    'Routing Direct' => [{type => 'field', domain => ['domain:platform.example'], outboundTag => 'direct'}],
    'Routing Services' => [{type => 'field', port => '25', outboundTag => 'block'}],
    'Routing Locator' => [{type => 'field', domain => ['geosite:cn'], outboundTag => 'direct'}],
    'Routing vlessRoute' => [{type => 'field', inboundTag => ['vless-default'], outboundTag => 'nodes'}],
);
my $profile = {uuid => 'native-e2e-profile', config => {
    outbounds => [map {{snippet => $_}} @preset_out],
    routing => {rules => [map {{snippet => $_}} @preset_routes]},
}};
my $listener = HTTP::Daemon->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 10, ReuseAddr => 1)
    or plan skip_all => 'loopback HTTP listener unavailable';
my $api = 'http://127.0.0.1:' . $listener->sockport;
my $panel_pid = fork(); die 'cannot fork loopback panel' unless defined $panel_pid;
unless ($panel_pid) {
    # Fork before SHM opens any database connections. This process implements
    # only the provider's HTTP contract and never loads/patches the adapter.
    my $panel = {rows => {%platform, 'Out Users' => [], 'Routing Users' => []}, profiles => [$profile], requests => [], syncs => 0, responseEncodings => {gzip => 0, empty202 => 0}};
    local $SIG{TERM} = sub {POSIX::_exit(0)};
    local $SIG{ALRM} = sub {POSIX::_exit(3)};
    alarm 90;
    while (my $connection = $listener->accept) {
        while (my $request = $connection->get_request) {
            my ($method, $path) = ($request->method, $request->uri->path);
            my $body = length($request->content) ? eval {$JSON->decode($request->content)} : {};
            my ($code, $data) = (200, {response => {}});
            if ($path eq '/__qa/state') {$data = $panel}
            elsif ($path eq '/__qa/seed') {$panel->{rows} = {%platform, %{$body->{rows}}}}
            elsif ($path eq '/__qa/fail-next') {$panel->{fail} = $body}
            elsif (($request->header('Authorization') // '') ne "Bearer $token") {($code, $data) = (401, {error => 'synthetic auth rejected'})}
            else {
                push @{$panel->{requests}}, {method => $method, path => $path, name => $body->{name}};
                if ($panel->{fail} && $method eq $panel->{fail}{method} && ($body->{name} // '') eq $panel->{fail}{name}) {
                    delete $panel->{fail};
                    ($code, $data) = (503, {error => 'NATIVE-E2E-REMOTE-ERROR'});
                } elsif ($method eq 'GET' && $path eq '/api/snippets') {
                    $data = {response => {snippets => [map {{name => $_, snippet => $panel->{rows}{$_}}} sort keys %{$panel->{rows}}]}};
                } elsif ($path =~ m{\A/api/config-profiles(?:/|\z)}) {
                    # Profiles belong to the panel administrator. Any provider
                    # request here must fail, never silently satisfy this test.
                    ($code, $data) = (500, {error => 'Profile API is forbidden in the snippet publisher'});
                } elsif ($method eq 'GET' && $path =~ m{\A/api/users/by-username/us_([0-9]+)\z}) {
                    $data = {response => {id => 100000 + $1, username => "us_$1", description => '隔离用户中文说明 😀', displayName => '测试用户中文显示名 😀'}};
                } elsif ($method eq 'PATCH' && $path eq '/api/snippets' && exists $panel->{rows}{$body->{name}}) {
                    $panel->{rows}{$body->{name}} = $body->{snippet};
                } elsif ($method eq 'POST' && $path eq '/api/snippets/actions/sync') {
                    $panel->{syncs}++;
                    ($code, $data) = (202, undef);
                } else {($code, $data) = (404, {error => 'unexpected synthetic endpoint'})}
            }
            my $response = HTTP::Response->new($code);
            $response->header('Content-Type' => 'application/json; charset=utf-8', Connection => 'close');
            my $content = defined($data) ? $JSON->encode($data) : '';
            if ($path =~ m{\A/api/} && length($content) && $code >= 200 && $code < 300) {
                # Real compressed UTF-8 DTOs exercise CoreHttp and the native
                # parser together; only public counters enter test diagnostics.
                $content = memGzip($content);
                POSIX::_exit(5) unless defined $content;
                $response->header('Content-Encoding' => 'gzip');
                $panel->{responseEncodings}{gzip}++;
            }
            $panel->{responseEncodings}{empty202}++ if $code == 202 && !length($content);
            $response->content($content);
            $connection->send_response($response);
            last;
        }
        $connection->close;
    }
    POSIX::_exit(0);
}
close $listener;

my ($admin, $dbh, $controller);
my (@users, @services, @instances, @servers, @tasks, @worker_logs, @journals);
END {
    if ($panel_pid) {kill 'TERM', $panel_pid; waitpid($panel_pid, 0)}
    eval {
        $dbh->rollback;
        for my $id (@tasks) {
            $dbh->do('DELETE FROM spool_history WHERE spool_id=?', undef, $id);
            $dbh->do('DELETE FROM spool WHERE id=?', undef, $id);
        }
        $dbh->do('DELETE FROM user_services WHERE user_service_id=?', undef, $_) for @instances;
        $dbh->do('DELETE FROM services WHERE service_id=?', undef, $_) for @services;
        $dbh->do('DELETE FROM servers WHERE server_id=?', undef, $_) for @servers;
        $dbh->do('DELETE FROM users WHERE user_id=?', undef, $_) for @users;
        $dbh->commit;
    } if $dbh;
    unlink $_ for @journals; # Only this test's newly observed, unique scope.
}

$admin = SHM->new(user_id => 1);
$dbh = $admin->dbh;
$dbh->{RaiseError} = 1;
plan skip_all => 'actual database must end in _test' unless $dbh->selectrow_array('SELECT DATABASE()') =~ /_test\z/;
$controller = get_service('ServiceOptions');
my $tag = 'native-uc-' . $$;
for (1..2) {
    $dbh->do('INSERT INTO users(login,balance,credit,bonus,gid,settings) VALUES (?,0,0,0,0,?)', undef, "$tag-$_", '{}');
    push @users, $dbh->{mysql_insertid};
}
my $settings = {remnawave => {api => $api, token => $token}};
$dbh->do('INSERT INTO servers(name,host,transport,settings) VALUES (?,?,?,?)', undef, $tag, $api, 'http', $JSON->encode($settings));
push @servers, $dbh->{mysql_insertid};
$dbh->do('INSERT INTO services(name,cost,period,category,config) VALUES (?,30,1,?,?)', undef, $tag, $tag, '{}');
push @services, $dbh->{mysql_insertid};
for my $owner (@users) {
    $dbh->do('INSERT INTO user_services(user_id,service_id,status,status_before,expire,settings) VALUES (?,?,?,?,?,?)',
        undef, $owner, $services[0], STATUS_ACTIVE, STATUS_INIT, utime_to_string(time + 86400), $JSON->encode({server_id => $servers[0], description => 'unchanged'}));
    push @instances, $dbh->{mysql_insertid};
}
$admin->commit;
my ($usi, $other) = @instances;
my $scope = substr(sha256_hex($JSON->encode([$api, 'Out Users', 'Routing Users'])), 0, 20);
my $prefix = 'SHM_ROUTING_' . $scope . '_';
my $foreign = wireguard(['10.65.0.1', 'fd00:65::53']);
$foreign->{tag} = $prefix . "us_${other}_out";
my $foreign_rule = {type => 'field', ruleTag => $prefix . "us_${other}_domain", user => ["other-numeric-user"],
    domain => ['domain:other.example'], outboundTag => $foreign->{tag}};

sub actor {
    my ($id) = @_;
    get_service('config')->local('authenticated_user_id', $id);
    switch_user($id);
}
sub panel {
    my ($path, $body) = @_;
    my $response = get_service('Transport::Http')->http(url => "$api/__qa/$path", method => defined($body) ? 'POST' : 'GET',
        content => $body || '', sensitive => 1, timeout => 3, no_proxy => 1, no_redirect => 1);
    die 'loopback panel fixture unavailable' unless $response->is_success;
    my $body = $response->content;
    $body = encode('UTF-8', $body) if utf8::is_utf8($body);
    return $JSON->decode($body);
}
sub stored {
    $dbh->rollback; # Workers commit independently; never reuse an old RR snapshot.
    return $JSON->decode($dbh->selectrow_array(q{SELECT JSON_EXTRACT(settings,'$.options') FROM user_services WHERE user_service_id=?}, undef, $usi));
}
sub outbound {
    my ($password) = @_;
    return {protocol => 'shadowsocks', settings => {servers => [{address => '8.8.8.8', port => 443,
        method => 'aes-256-gcm', password => $password}]}};
}
sub wireguard {
    my ($dns) = @_;
    my $key = encode_base64('K' x 32, '');
    return {protocol => 'wireguard', settings => {secretKey => $key, address => ['10.64.0.2/32', 'fd00::2/128'],
        peers => [{publicKey => $key, endpoint => '8.8.4.4:51820', allowedIPs => ['0.0.0.0/0', '::/0']}],
        defined($dns) ? (remoteDNS => $dns) : ()}};
}
sub save {
    my (%args) = @_;
    actor($users[0]);
    my $result = $controller->save_for_api(user_service_id => $usi, %args);
    unless ($result) {
        my $report = get_service('report');
        diag('fixture save status=' . $report->status . ' errors=' . $JSON->encode([$report->errors]));
        die 'native fixture save failed';
    }
    $admin->commit;
    return $result;
}
sub latest_task {
    my ($id) = $dbh->selectrow_array(q{SELECT id FROM spool WHERE event->>'$.name'='SERVICE_OPTIONS' AND JSON_CONTAINS(settings,?,'$.user_service_ids') ORDER BY id DESC LIMIT 1}, undef, "[$usi]");
    die 'native fixture task missing' unless $id;
    push @tasks, $id unless grep {$_ == $id} @tasks;
    $dbh->rollback;
    return $id;
}
my $worker = q{
    use SHM;
    use Core::System::ServiceManager qw(get_service);
    my $app = SHM->new(user_id => 1);
    my $task = get_service('spool', _id => shift) or die "native fixture task missing\n";
    get_service('spool')->process_one(scalar $task->get);
    $app->commit;
};
sub run_worker {
    my ($id) = @_;
    my ($capture, $path) = tempfile(UNLINK => 1);
    my $pid = fork(); die 'cannot fork native worker' unless defined $pid;
    unless ($pid) {
        open STDOUT, '>&', $capture or POSIX::_exit(2);
        open STDERR, '>&', $capture or POSIX::_exit(2);
        exec($^X, '-I/app/lib', '-e', $worker, $id) or POSIX::_exit(3);
    }
    waitpid($pid, 0);
    my $exit = $? >> 8;
    seek $capture, 0, 0;
    my $log = do {local $/; <$capture>}; close $capture;
    push @worker_logs, $log;
    is($exit, 0, 'a fresh native worker processes and commits the task');
    diag($log) if $exit;
    return $exit;
}
sub owned {
    my ($snapshot, $name) = @_;
    my $key = $name eq 'Out Users' ? 'tag' : 'ruleTag';
    return [grep {index($_->{$key} // '', $prefix . "us_${usi}_") == 0} @{$snapshot->{rows}{$name}}];
}
sub others_preserved {
    my ($snapshot) = @_;
    is_deeply([grep {($_->{tag} // '') eq $foreign->{tag}} @{$snapshot->{rows}{'Out Users'}}], [$foreign], 'another user outbound is preserved exactly');
    is_deeply([grep {($_->{ruleTag} // '') eq $foreign_rule->{ruleTag}} @{$snapshot->{rows}{'Routing Users'}}], [$foreign_rule], 'another user rule is preserved exactly');
    is_deeply({map {$_ => $snapshot->{rows}{$_}} keys %platform}, \%platform, 'all platform snippets remain byte-equivalent through the real worker flow');
    is_deeply($snapshot->{profiles}, [$profile], 'administrator Profile bytes remain unchanged');
    is(scalar(grep {$_->{path} =~ m{\A/api/config-profiles(?:/|\z)}} @{$snapshot->{requests}}), 0, 'real workers never request Profile endpoints');
    ok(!scalar(grep {$_->{method} ne 'GET' && !(($_->{method} eq 'PATCH' && $_->{path} eq '/api/snippets' && ($_->{name} // '') =~ /\A(?:Out Users|Routing Users)\z/) || ($_->{method} eq 'POST' && $_->{path} eq '/api/snippets/actions/sync'))} @{$snapshot->{requests}}), 'real workers write only the two fixed snippets and sync');
}

panel('seed', {rows => {'Out Users' => [$foreign], 'Routing Users' => [$foreign_rule]}});
my $response = save(enabled => 1, data => {rules => ['first.example', '1.1.1.7/24']},
    secret => {outbound => outbound($private_markers[1]), outbound_text => "ss://original-format#$private_markers[-1] 原始备注 😀\r\n"});
is($response->{status}, 'queued', 'owner save enters the existing asynchronous path');
my $task = latest_task();
run_worker($task);
is(stored()->{status}, 'submitted', 'Core, installed adapter, real LWP and State complete publication');
my $snapshot = panel('state');
unlike($JSON->encode($snapshot->{rows}), qr/\Q$private_markers[-1]\E|outbound_text/, 'original source text is not published in remote snippets');
is($snapshot->{syncs}, 1, 'a complete pair triggers one accepted sync');
is(owned($snapshot, 'Out Users')->[0]{settings}{servers}[0]{password}, $private_markers[1], 'actual HTTP carries the decrypted secret only to the intended panel');
is_deeply(owned($snapshot, 'Routing Users')->[0]{user}, ['' . (100000 + $usi)], 'routing uses actual panel numeric identity');
others_preserved($snapshot);

my %existing_journals = map {$_ => 1} glob($controller->_directory . '/state-*.json');
panel('fail-next', {method => 'PATCH', name => 'Routing Users'});
save(enabled => 1, data => {rules => ['second.example']}, secret => {outbound => outbound($private_markers[2])});
$task = latest_task();
run_worker($task);
is(stored()->{status}, 'error', 'second PATCH failure remains an error rather than false success');
is(stored()->{error}, 'REMOTE_HTTP', 'provider failure exposes only its fixed code');
my $queued_failure = $JSON->decode($dbh->selectrow_array('SELECT response FROM spool WHERE id=?', undef, $task));
is($queued_failure->{error}, 'REMOTE_HTTP', 'real Spool retry stores the actual sanitized provider failure');
my $history_failure = $JSON->decode($dbh->selectrow_array('SELECT response FROM spool_history WHERE spool_id=? ORDER BY id DESC LIMIT 1', undef, $task));
is($history_failure->{error}, 'REMOTE_HTTP', 'real task history preserves the actionable provider code');
$snapshot = panel('state');
is($snapshot->{syncs}, 1, 'inconsistent partial pair is never synchronized');
is(owned($snapshot, 'Out Users')->[0]{settings}{servers}[0]{password}, $private_markers[2], 'first PATCH really reached the panel before the fault');
is_deeply(owned($snapshot, 'Routing Users')->[0]{domain}, ['domain:first.example'], 'failed second PATCH leaves the old rule until recovery');
my @pending = grep {!$existing_journals{$_}} glob($controller->_directory . '/state-*.json');
is(scalar @pending, 1, 'the real encrypted State retains exactly one pending operation');
push @journals, @pending;
if (@pending == 1) {
    open my $in, '<', $pending[0] or die $!;
    my $cipher = do {local $/; <$in>}; close $in;
    unlike($cipher, qr/\Q$private_markers[2]\E|second\.example/, 'durable pending file contains no plaintext secret or rule');
    is((stat($pending[0]))[2] & 0777, 0600, 'real pending file has private permissions');
}
run_worker($task); # An independent Perl interpreter, with no old object cache.
is(stored()->{status}, 'submitted', 'a new worker reconstructs and completes the interrupted pair');
ok(!@pending || !-e $pending[0], 'confirmed sync clears the encrypted pending file');
$snapshot = panel('state');
is($snapshot->{syncs}, 2, 'recovery triggers only the final consistent sync');
is_deeply(owned($snapshot, 'Routing Users')->[0]{domain}, ['domain:second.example'], 'recovery publishes the current rule');
others_preserved($snapshot);

panel('fail-next', {method => 'PATCH', name => 'Routing Users'});
save(enabled => 1, data => {rules => ['wireguard.example']},
    secret => {outbound => wireguard(['10.64.0.1', 'FD00:0:0:0:0:0:0:53', '10.64.0.1'])});
$task = latest_task();
run_worker($task);
is(stored()->{error}, 'REMOTE_HTTP', 'a partial WireGuard publication remains retryable');
$snapshot = panel('state');
is_deeply(owned($snapshot, 'Out Users')->[0]{settings}{remoteDNS}, ['10.64.0.1', 'fd00::53', '10.64.0.1'],
    'actual HTTP publishes normalized private DNS in provider order');
others_preserved($snapshot);
run_worker($task);
is(stored()->{status}, 'submitted', 'an independent worker recovers the WireGuard DNS publication');
$snapshot = panel('state');
is_deeply(owned($snapshot, 'Out Users')->[0]{settings}{remoteDNS}, ['10.64.0.1', 'fd00::53', '10.64.0.1'],
    'encrypted pending recovery retains the DNS list');
ok(owned($snapshot, 'Out Users')->[0]{settings}{noKernelTun}, 'real worker keeps WireGuard in userspace');
others_preserved($snapshot);
save(enabled => 1, data => {rules => ['wireguard.example']}, secret => {outbound => wireguard()});
run_worker(latest_task());
$snapshot = panel('state');
ok(!exists(owned($snapshot, 'Out Users')->[0]{settings}{remoteDNS}), 'real publication leaves an omitted DNS field absent');
others_preserved($snapshot);

my $valid_pair = $JSON->encode($snapshot->{rows});
my $writes_before = scalar grep {$_->{method} eq 'PATCH' || $_->{method} eq 'POST'} @{$snapshot->{requests}};
my $invalid = outbound($private_markers[3]);
$invalid->{tag} = 'injected-tag';
save(enabled => 1, data => {rules => ['invalid.example']}, secret => {outbound => $invalid});
run_worker(latest_task());
is(stored()->{status}, 'error', 'invalid new draft is a per-user validation error');
is(stored()->{error}, 'INVALID_OUTBOUND', 'invalid draft uses a fixed business code');
$snapshot = panel('state');
is($JSON->encode($snapshot->{rows}), $valid_pair, 'invalid draft cannot overwrite the last valid published pair');
is(scalar(grep {$_->{method} eq 'PATCH' || $_->{method} eq 'POST'} @{$snapshot->{requests}}), $writes_before, 'invalid draft produces no provider writes');

my $box_before_disable = stored()->{secret};
$response = save(enabled => 0);
ok($response->{has_secret}, 'disable preserves the stored secret without submitting the invalid draft');
run_worker(latest_task());
is(stored()->{status}, 'disabled', 'explicit disable is acknowledged by the real adapter');
is(stored()->{secret}, $box_before_disable, 'disable preserves original encrypted secret bytes');
$snapshot = panel('state');
is_deeply(owned($snapshot, 'Out Users'), [], 'disable removes only this user outbound');
is_deeply(owned($snapshot, 'Routing Users'), [], 'disable removes only this user rules');
others_preserved($snapshot);

save(enabled => 1, data => {rules => ['cleanup.example']}, secret => {outbound => outbound($private_markers[1])});
run_worker(latest_task());
is(stored()->{status}, 'submitted', 'valid re-enable publishes again');
actor(1);
$dbh->do('UPDATE user_services SET status=? WHERE user_service_id=?', undef, STATUS_REMOVED, $usi);
my $removed = get_service('us', _id => $usi);
$removed->reload;
$controller->lifecycle_changed($removed, STATUS_REMOVED);
$admin->commit;
panel('fail-next', {method => 'PATCH', name => 'Routing Users'});
$task = latest_task();
run_worker($task);
is(stored()->{status}, 'error', 'failed REMOVE publication remains retryable');
ok(stored()->{secret}, 'REMOVE cannot erase its secret before explicit remote cleanup confirmation');
run_worker($task);
my $cleaned = stored();
is($cleaned->{status}, 'cleaned', 'successful real cleanup produces the expected tombstone');
ok(!exists($cleaned->{secret}), 'only confirmed REMOVE erases the encrypted secret');
is_deeply($cleaned->{data}, {}, 'only confirmed REMOVE erases public configuration');
$snapshot = panel('state');
is_deeply(owned($snapshot, 'Out Users'), [], 'REMOVE clears this user outbound');
is_deeply(owned($snapshot, 'Routing Users'), [], 'REMOVE clears this user rules');
others_preserved($snapshot);

my $placeholders = join ',', ('?') x @tasks;
my $encoding_snapshot = panel('state');
cmp_ok($encoding_snapshot->{responseEncodings}{gzip}, '>', 0, 'real HTTP worker parsed compressed UTF-8 provider DTOs');
cmp_ok($encoding_snapshot->{responseEncodings}{empty202}, '>', 0, 'real HTTP worker accepted official empty 202 sync responses');
my $history = $dbh->selectall_arrayref("SELECT * FROM spool_history WHERE spool_id IN ($placeholders)", {Slice => {}}, @tasks);
ok(@$history >= @tasks, 'real Spool execution writes history for successful and failed attempts');
my $remaining = $dbh->selectall_arrayref("SELECT * FROM spool WHERE id IN ($placeholders)", {Slice => {}}, @tasks);
my $persistent = $JSON->encode([$history, $remaining]) . join('', @worker_logs);
for my $marker (@private_markers) {unlike($persistent, qr/\Q$marker\E/, 'task/history/worker diagnostics never contain a synthetic private marker')}
unlike($persistent, qr/"secret"\s*:|second\.example|wireguard\.example|cleanup\.example/, 'task history contains IDs and safe result metadata, never configuration snapshots');

done_testing();
