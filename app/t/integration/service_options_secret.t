use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
BEGIN {
    plan skip_all => 'requires SHM_SQL_CONFIG_TEST=1 and an isolated *_test database'
        unless ($ENV{SHM_SQL_CONFIG_TEST} // '') eq '1' && ($ENV{DB_NAME} // '') =~ /_test\z/;
}
use SHM;
use Core::ServiceOptions;
use Core::Const;
use Core::System::ServiceManager qw(get_service);
use Core::Utils qw(switch_user);
use JSON::PP ();
use Encode qw(encode_utf8);
use IPC::Open3;
use Symbol qw(gensym);

# Fresh CGI processes use real sessions, router, ownership checks and AES-GCM.
# This file creates only isolated fixtures and never processes its spool task.
local @ENV{qw(SHM_TEST HTTP_TEST)};
delete @ENV{qw(SHM_TEST HTTP_TEST)};
local $ENV{REMOTE_ADDR} = '127.0.0.1';
local $ENV{HTTP_USER_AGENT} = 'service-options-secret-fixture';
my $app = SHM->new(user_id => 1);
my $dbh = $app->dbh;
$dbh->{RaiseError} = 1;
plan skip_all => 'actual database must end in _test'
    unless $dbh->selectrow_array('SELECT DATABASE()') =~ /_test\z/;
my $json = JSON::PP->new->utf8->canonical;
my $controller = get_service('ServiceOptions');
my $tag = 'options-secret-' . $$;
my (@users, @instances, @sessions, $group, $server, $service);
END {
    eval {
        $dbh->rollback;
        for my $id (@instances) {
            $dbh->do(q{DELETE FROM spool WHERE JSON_CONTAINS(settings,?,'$.user_service_ids')}, undef, "[$id]");
        }
        for my $user (@users) {
            $dbh->do("DELETE FROM $_ WHERE user_id=?", undef, $user)
                for qw(logs_api spool_history spool sessions user_services);
            $dbh->do('DELETE FROM users WHERE user_id=?', undef, $user);
        }
        $dbh->do('DELETE FROM services WHERE service_id=?', undef, $service) if $service;
        $dbh->do('DELETE FROM servers WHERE server_id=?', undef, $server) if $server;
        $dbh->do('DELETE FROM user_groups WHERE gid=?', undef, $group) if $group;
        $dbh->commit;
    } if $dbh;
}
$dbh->do('INSERT INTO user_groups(name,is_admin,default_policy,rules) VALUES (?,1,?,?)', undef, $tag, 'allow', '[]');
$group = $dbh->{mysql_insertid};
for my $gid (0, 0, $group) {
    $dbh->do('INSERT INTO users(login,balance,credit,bonus,gid,settings) VALUES (?,0,0,0,?,?)',
        undef, $tag . '-' . scalar(@users), $gid, '{}');
    push @users, $dbh->{mysql_insertid};
    push @sessions, get_service('sessions')->add(user_id => $users[-1]);
}
ok(!(grep {!defined($_) || !length($_)} @sessions), 'fixture sessions are real bearer credentials');
$dbh->do('INSERT INTO servers(name,host,transport,settings) VALUES (?,?,?,?)',
    undef, $tag, 'unused.invalid', 'http', $json->encode({remnawave => {}}));
$server = $dbh->{mysql_insertid};
$dbh->do('INSERT INTO services(name,cost,period,category,config) VALUES (?,0,1,?,?)', undef, $tag, 'optsecret', '{}');
$service = $dbh->{mysql_insertid};
for my $status (STATUS_ACTIVE, STATUS_ACTIVE, STATUS_REMOVED) {
    $dbh->do('INSERT INTO user_services(user_id,service_id,status,status_before,settings) VALUES (?,?,?,?,?)',
        undef, $users[0], $service, $status, STATUS_INIT, $json->encode({server_id => $server}));
    push @instances, $dbh->{mysql_insertid};
}
my $marker = 'RESTORE-PRIVATE-CREDENTIAL-' . $$;
my $secret = {arbitrary_key => $marker, nested => {text => '私密配置 😀'}};
my $target = {adapter => 'remnawave', server_id => $server};
my $cipher;
for my $id (@instances[0,2]) {
    my $us = get_service('us', _id => $id);
    my $box = $controller->_encrypt($us, $secret);
    $cipher = $box if $id == $instances[0];
    $dbh->do(q{UPDATE user_services SET settings=JSON_SET(settings,'$.options',CAST(? AS JSON)) WHERE user_service_id=?},
        undef, $json->encode({enabled => 1, data => {rules => ['example.test']}, secret => $box,
            feature => 'routing', target => $target, status => 'submitted'}), $id);
}
$dbh->commit;

sub request {
    my ($session, $method, $path, $input, $extra) = @_;
    my $body = ref($input) ? $json->encode($input) : ($input // '');
    local %ENV = %ENV;
    delete @ENV{qw(USER_ID HTTP_AUTHORIZATION HTTP_SESSION_ID HTTP_COOKIE HTTP_LOGIN HTTP_PASSWORD HTTP_TEST SHM_TEST HTTP_ORIGIN HTTP_SEC_FETCH_SITE HTTP_X_FORWARDED_HOST)};
    @ENV{qw(REQUEST_METHOD SCRIPT_NAME PATH_INFO QUERY_STRING CONTENT_TYPE CONTENT_LENGTH HTTP_HOST HTTP_X_FORWARDED_PROTO)} =
        ($method, '/shm/v1.cgi', $path, '', 'application/json', length($body), 'client.example', 'https');
    $ENV{HTTP_SESSION_ID} = $session if defined $session;
    $ENV{$_} = $extra->{$_} for keys %{$extra || {}};
    my ($stdin, $stdout, $stderr) = (undef, undef, gensym);
    my $pid = open3($stdin, $stdout, $stderr, $^X, '-I/app/lib', '/app/public_html/shm/v1.cgi');
    print {$stdin} $body; close $stdin;
    my $out = do {local $/; <$stdout>} // '';
    my $err = do {local $/; <$stderr>} // '';
    waitpid($pid, 0);
    my ($headers, $payload) = split(/\r?\n\r?\n/, $out, 2);
    my $response = eval {$json->decode($payload // '')};
    die 'isolated secret CGI returned invalid JSON' unless ref($response) eq 'HASH';
    my ($status) = ($headers // '') =~ /^Status:\s*(\d+)/mi;
    unlike($err, qr/\Q$marker\E|\"secret\"\s*:/, 'CGI diagnostics do not contain private configuration');
    return ($status // 200, $response, $headers, $out);
}
sub private_headers {
    my ($headers) = @_;
    like($headers, qr/^Cache-control: [^\r\n]*\bno-store\b/mi, 'response cannot be stored, including early errors');
    like($headers, qr/^Pragma: no-cache\r?$/mi, 'response disables legacy caches');
}
my $path = '/user/service/options/secret';
my %id = (user_service_id => $instances[0]);
my ($status, $response, $headers, $raw) = request($sessions[0], 'POST', $path, \%id,
    {HTTP_ORIGIN => 'https://client.example', HTTP_SEC_FETCH_SITE => 'same-origin'});
is($status, 200, 'owner retrieves a saved secret through the real authenticated CGI');
is_deeply($response->{data}[0], {secret => $secret}, 'response contains only the owner generic secret with Unicode intact');
unlike($raw, qr/\Q$cipher\E|\"target\"\s*:/, 'owner response contains no ciphertext or private storage metadata');
private_headers($headers);
($status, $response, $headers) = request($sessions[0], 'POST', $path, \%id,
    {HTTP_ORIGIN => 'https://client.example:19125', HTTP_SEC_FETCH_SITE => 'same-origin'});
is($status, 200, 'same-origin browser still works when the official proxy strips its non-default port');
is_deeply($response->{data}[0], {secret => $secret}, 'lost-port compatibility still returns only the authenticated owner secret');
private_headers($headers);
for my $case (
    [$sessions[1], {}, 403, 'another owner'],
    [$sessions[2], {}, 403, 'administrator without ownership'],
    [undef, {}, 401, 'anonymous caller'],
    [$sessions[0], {HTTP_ORIGIN => 'https://other.example'}, 403, 'cross-origin caller'],
    [$sessions[0], {HTTP_SEC_FETCH_SITE => 'cross-site'}, 403, 'cross-site browser caller'],
    [$sessions[0], {HTTP_SEC_FETCH_SITE => 'same-site'}, 403, 'same-site subdomain caller'],
    [$sessions[0], {HTTP_ORIGIN => 'null'}, 403, 'opaque browser origin'],
    [$sessions[0], {HTTP_ORIGIN => 'https://other.example', HTTP_X_FORWARDED_HOST => 'other.example'}, 403, 'forged forwarded-host caller'],
    [$sessions[0], {HTTP_ORIGIN => 'https://client.example:19125'}, 403, 'non-default origin port without browser metadata'],
) {
    ($status, $response, $headers, $raw) = request($case->[0], 'POST', $path, \%id, $case->[1]);
    is($status, $case->[2], "$case->[3] cannot retrieve the owner secret");
    unlike($raw, qr/\Q$marker\E|\"secret\"\s*:/, 'denied response contains no secret or ciphertext');
    private_headers($headers);
}
for my $input ({%id, user_id => $users[0]}, {%id, unexpected => $marker}, '{"private":"' . $marker) {
    ($status, $response, $headers, $raw) = request($sessions[0], 'POST', $path, $input);
    is($status, 400, 'strict or malformed secret read request is rejected');
    unlike($raw, qr/\Q$marker\E/, 'validation does not echo malformed or unknown private values');
    private_headers($headers);
}
($status, $response, $headers) = request($sessions[0], 'POST', $path, {user_service_id => $instances[1]});
is($status, 200, 'owner may read an instance with no saved secret');
is_deeply($response->{data}[0], {secret => {}}, 'no saved secret is represented by an empty object');
private_headers($headers);
($status, $response, $headers, $raw) = request($sessions[0], 'POST', $path, {user_service_id => $instances[2]});
is($status, 409, 'removed instance cannot disclose its former secret');
unlike($raw, qr/\Q$marker\E/, 'removed instance response has no former secret');
private_headers($headers);
($status, $response, $headers) = request($sessions[0], 'GET', $path, '');
is($status, 404, 'secret is not available through GET');
private_headers($headers);
($status) = request($sessions[2], 'POST', '/admin/user/service/options/secret', \%id);
is($status, 404, 'there is no administrator secret-read route');
($status, $response, $headers, $raw) = request($sessions[0], 'POST', $path . '/', \%id);
is($status, 404, 'the router does not expose an unprotected trailing-slash alias');
unlike($raw, qr/\Q$marker\E/, 'unmatched alias contains no private value');

for my $case (
    [$sessions[0], '/user/service/options', 'GET', 'user_service_id=' . $instances[0]],
    [$sessions[2], '/admin/user/service/options', 'GET', 'user_service_id=' . $instances[0]],
) {
    # The GET ID is a normal query, not a JSON body.
    ($status, $response, $headers, $raw) = request($case->[0], $case->[2], $case->[1], '', {QUERY_STRING => $case->[3]});
    is($status, 200, 'ordinary options read remains available');
    is($response->{status}, 200, 'outer SHM HTTP status remains numeric');
    is($response->{data}[0]{status}, 'submitted', 'real CGI returns a scalar synchronization status');
    is_deeply([sort keys %{$response->{data}[0]}], [qw(data enabled feature has_secret status supported)],
        'ordinary and administrator responses contain only the public whitelist');
    unlike($raw, qr/\Q$marker\E|"secret"\s*:/, 'ordinary and administrator reads remain redacted');
    unlike($headers, qr/^Cache-control:.*no-store/mi, 'ordinary route does not inherit secret response defaults');
}
for my $field (qw(policy secret_box target feature status error requires_secret)) {
    ($status, $response, $headers, $raw) = request($sessions[0], 'POST', '/user/service/options',
        {user_service_id => $instances[0], enabled => JSON::PP::false, $field => 'rejected-private-value'});
    is($status, 400, 'real CGI refuses an internal or outdated top-level input: ' . $field);
    unlike($raw, qr/rejected-private-value|\Q$marker\E|\Q$cipher\E/, 'invalid request is rejected without echoing input or credentials');
}
$dbh->rollback;
is($dbh->selectrow_array(q{SELECT JSON_UNQUOTE(JSON_EXTRACT(settings,'$.options.secret')) FROM user_services WHERE user_service_id=?}, undef, $instances[0]),
    $cipher, 'reading does not replace ciphertext or create additional stored representations');
is($dbh->selectrow_array(q{SELECT COUNT(*) FROM spool WHERE JSON_CONTAINS(settings,?,'$.user_service_ids')}, undef, "[$instances[0]]"),
    0, 'secret reads do not create queue tasks, including administrator-context tasks');
my $logs = $dbh->selectall_arrayref('SELECT args,response_error FROM logs_api WHERE user_id IN (?,?,?)', {Slice => {}}, @users);
ok(@$logs > 0, 'the real CGI produced auditable API entries');
unlike($json->encode($logs), qr/\Q$marker\E|\Q$cipher\E/, 'API logs never contain private values, raw bodies or ciphertext');
my ($sensitive) = $dbh->selectrow_array('SELECT args FROM logs_api WHERE url=? AND user_id=? LIMIT 1', undef, $path, $users[0]);
is_deeply($json->decode($sensitive), {redacted => 1}, 'new secret route logs only a full-body redaction marker');

subtest 'generic encrypted secret preserves original UTF-8 text within its byte limit' => sub {
    my $original = "  socks5://owner:$marker\@8.8.8.8:1080#原始备注 😀\r\n";
    $original .= ' ' x (16384 - length(encode_utf8($original)));
    my $normalized = {protocol => 'socks', settings => {servers => [{address => '8.8.8.8', port => 1080,
        users => [{user => 'owner', pass => $marker}]}]}};
    my $bounded = {outbound => $normalized, outbound_text => $original, private_padding => ''};
    $bounded->{private_padding} = 'x' x (65536 - length($json->encode($bounded)));
    is(length(encode_utf8($original)), 16384, 'fixture contains exactly 16KiB of untrimmed UTF-8 original text');
    is(length($json->encode($bounded)), 65536, 'generic secret fixture occupies exactly 64KiB serialized UTF-8 bytes');
    my $id = $instances[1];
    my $save = {user_service_id => $id, enabled => JSON::PP::true, data => {rules => ['example.test']}, secret => $bounded};
    my ($code, $reply, $head, $body) = request($sessions[0], 'POST', '/user/service/options', $save);
    is($code, 200, 'actual CGI accepts the inclusive 64KiB secret boundary');
    ok($reply->{data}[0]{has_secret}, 'normal save reports only credential presence');
    unlike($body, qr/\Q$marker\E|outbound_text|private_padding|"secret"\s*:/, 'save response discloses neither original text nor ciphertext');

    ($code, $reply, $head) = request($sessions[0], 'POST', $path, {user_service_id => $id});
    is($code, 200, 'the owner can reopen a large encrypted secret');
    ok($json->encode($reply->{data}[0]{secret}) eq $json->encode($bounded), 'all generic secret fields survive encryption and owner retrieval');
    ok(encode_utf8($reply->{data}[0]{secret}{outbound_text}) eq encode_utf8($original),
        'original format, Unicode, CRLF and surrounding whitespace round-trip byte-for-byte');
    private_headers($head);

    $dbh->rollback;
    my ($stored_json) = $dbh->selectrow_array(q{SELECT JSON_EXTRACT(settings,'$.options') FROM user_services WHERE user_service_id=?}, undef, $id);
    my $before = $json->decode($stored_json);
    ok($before->{secret} && !exists($before->{outbound_text}), 'original input shares the existing encrypted secret box');
    unlike($stored_json, qr/\Q$marker\E|outbound_text|private_padding/, 'the database stores original text only inside the encrypted box');
    my $task_count = $dbh->selectrow_array(q{SELECT COUNT(*) FROM spool WHERE JSON_CONTAINS(settings,?,'$.user_service_ids')}, undef, "[$id]");
    is($task_count, 1, 'the accepted save queues one ID-only synchronization task');
    my $too_large = {%$bounded, private_padding => $bounded->{private_padding} . 'x'};
    is(length($json->encode($too_large)), 65537, 'oversize fixture exceeds the encoded byte limit by exactly one');
    ($code, $reply, $head, $body) = request($sessions[0], 'POST', '/user/service/options', {%$save, secret => $too_large});
    is($code, 400, 'actual CGI rejects a 65537-byte secret');
    unlike($body, qr/\Q$marker\E|outbound_text|private_padding/, 'oversize error does not echo original text');
    $dbh->rollback;
    my ($after_json) = $dbh->selectrow_array(q{SELECT JSON_EXTRACT(settings,'$.options') FROM user_services WHERE user_service_id=?}, undef, $id);
    ok($after_json eq $stored_json, 'oversize failure preserves the previous encrypted configuration and status');
    is($dbh->selectrow_array(q{SELECT COUNT(*) FROM spool WHERE JSON_CONTAINS(settings,?,'$.user_service_ids')}, undef, "[$id]"),
        $task_count, 'oversize failure creates no additional task');

    for my $case ([$sessions[0], '/user/service/options'], [$sessions[2], '/admin/user/service/options']) {
        ($code, $reply, $head, $body) = request($case->[0], 'GET', $case->[1], '', {QUERY_STRING => 'user_service_id=' . $id});
        is($code, 200, 'ordinary options read remains available for the large-secret instance');
        unlike($body, qr/\Q$marker\E|outbound_text|private_padding|"secret"\s*:/, 'public and admin reads contain no original input');
    }
    $dbh->rollback;
    my $tasks = $dbh->selectall_arrayref(q{SELECT * FROM spool WHERE JSON_CONTAINS(settings,?,'$.user_service_ids')}, {Slice => {}}, "[$id]");
    my $logs = $dbh->selectall_arrayref('SELECT args,response_error FROM logs_api WHERE user_id=?', {Slice => {}}, $users[0]);
    unlike($json->encode([$tasks, $logs]), qr/\Q$marker\E|outbound_text|private_padding/, 'queue and API logs retain no original text or secret snapshot');

};

done_testing();
