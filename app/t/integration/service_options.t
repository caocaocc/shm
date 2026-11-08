use v5.14;
use strict;
use warnings;
no warnings 'once';
use Test::More;
BEGIN {
    plan skip_all => 'requires SHM_SQL_CONFIG_TEST=1 and an isolated *_test database'
        unless ($ENV{SHM_SQL_CONFIG_TEST} // '') eq '1' && ($ENV{DB_NAME} // '') =~ /_test\z/;
}
use SHM;
use Core::ServiceOptions;
use Core::Const;
use Core::Utils qw(encode_json decode_json switch_user utime_to_string);
use Core::System::ServiceManager qw(get_service);
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT);
{
    package ServiceOptionsKeyLossFixture;
    our @ISA = ('Core::ServiceOptions');
    our $directory;
    sub _directory {$directory}
}

my $admin = SHM->new(user_id => 1);
my $dbh = $admin->dbh;
$dbh->{RaiseError} = 1;
plan skip_all => 'actual database must end in _test' unless $dbh->selectrow_array('SELECT DATABASE()') =~ /_test\z/;
my $controller = get_service('ServiceOptions');
my $tag = 'uc-' . $$;
my (@users, @services, @instances, @servers);
END {
    eval {
        $dbh->rollback;
        for my $usi (@instances) {
            $dbh->do(q{DELETE FROM spool WHERE JSON_CONTAINS(settings,?, '$.user_service_ids')}, undef, "[$usi]");
            $dbh->do('DELETE FROM user_services WHERE user_service_id=?', undef, $usi);
        }
        $dbh->do('DELETE FROM services WHERE service_id=?', undef, $_) for @services;
        $dbh->do('DELETE FROM servers WHERE server_id=?', undef, $_) for @servers;
        $dbh->do('DELETE FROM users WHERE user_id=?', undef, $_) for @users;
        $dbh->commit;
    } if $dbh;
}
sub actor {
    my ($id) = @_;
    get_service('config')->local('authenticated_user_id', $id);
    switch_user($id);
}
sub failures {
    my ($status, $name, $code) = @_;
    is($code->(), undef, $name);
    is(get_service('report')->status, $status, 'failure has expected HTTP status');
    get_service('report')->errors;
}
for (1..2) {
    $dbh->do('INSERT INTO users(login,balance,credit,bonus,gid,settings) VALUES (?,0,0,0,0,?)', undef, "$tag-$_", '{}');
    push @users, $dbh->{mysql_insertid};
}
$dbh->do('INSERT INTO servers(name,host,transport,settings) VALUES (?,?,?,?)', undef, $tag, 'https://api.example.test', 'http', '{}');
push @servers, $dbh->{mysql_insertid};
$dbh->do('UPDATE servers SET settings=? WHERE server_id=?', undef, encode_json({fixture_server_id => $servers[-1], service_options_fixture => {}}), $servers[-1]);
$dbh->do('INSERT INTO servers(name,host,transport,settings) VALUES (?,?,?,?)', undef, "$tag-b", 'https://api-b.example.test', 'http', '{}');
push @servers, $dbh->{mysql_insertid};
$dbh->do('UPDATE servers SET settings=? WHERE server_id=?', undef, encode_json({fixture_server_id => $servers[-1], service_options_fixture => {}}), $servers[-1]);
$dbh->do('INSERT INTO services(name,cost,period,category,config) VALUES (?,30,1,?,?)', undef, $tag, $tag, '{}');
push @services, $dbh->{mysql_insertid};
for my $owner ($users[0], $users[1], $users[1]) {
    $dbh->do('INSERT INTO user_services(user_id,service_id,status,status_before,expire,settings) VALUES (?,?,?,?,?,?)',
        undef, $owner, $services[0], STATUS_ACTIVE, STATUS_INIT, utime_to_string(time+86400), encode_json({server_id => $servers[0], description => 'keep-note'}));
    push @instances, $dbh->{mysql_insertid};
}
$dbh->commit;
my (undef, $installed_adapter) = $controller->_target({feature => 'routing', target => {server_id => $servers[0], adapter => 'remnawave'}});
isa_ok($installed_adapter, 'Core::Integrations::Remnawave', 'the real installed adapter is loaded through the actual controller boundary');
ok(!$installed_adapter->can('register'), 'the real integration needs no ServiceManager register method');
my ($owner, $other) = @users;
my ($usi, $other_usi) = @instances;
$dbh->do('INSERT INTO user_services(user_id,service_id,status,status_before,settings) VALUES (?,?,?,?,NULL)',
    undef, $owner, $services[0], STATUS_INIT, STATUS_INIT);
my $ordinary_id = $dbh->{mysql_insertid};
push @instances, $ordinary_id;
my $ordinary = get_service('us', _id => $ordinary_id);
is($ordinary->res->{settings}, undef, 'ordinary new instance starts with NULL settings');
$ordinary->status(STATUS_ACTIVE);
is($ordinary->res->{settings}, undef, 'lifecycle observer does not materialize empty settings');
ok($dbh->selectrow_array('SELECT settings IS NULL FROM user_services WHERE user_service_id=?', undef, $ordinary_id),
    'ordinary lifecycle leaves SQL NULL settings unchanged');
my $us = get_service('us', _id => $usi);
sub fresh_us { $us->reload; return $us }
my $report = get_service('report');
sub stored {
    return decode_json($dbh->selectrow_array(q{SELECT JSON_EXTRACT(settings,'$.options') FROM user_services WHERE user_service_id=?}, undef, $_[0] // $usi));
}
sub queued {
    my ($id) = $dbh->selectrow_array(q{SELECT id FROM spool WHERE event->>'$.name'='SERVICE_OPTIONS' AND JSON_CONTAINS(settings,?, '$.user_service_ids') ORDER BY id DESC LIMIT 1}, undef, "[$usi]");
    return get_service('spool', _id => $id);
}

actor($owner);
my $unassigned = $controller->get_for_api(user_service_id => $ordinary_id);
ok(!$unassigned->{supported}, 'without a provisioned server the API does not guess an available integration');
failures(403, 'an unassigned instance cannot save or enqueue configuration for another server', sub {
    $controller->save_for_api(user_service_id => $ordinary_id, enabled => 1, secret => {value => 'never-persist'})});
my $initial = $controller->get_for_api(user_service_id => $usi);
is_deeply($controller->secret_for_api(user_service_id => $usi), {secret => {}}, 'an owner with no stored secret receives an empty object');
ok($initial->{supported}, 'owned instance advertises its administrator-enabled capability');
is($initial->{feature}, 'test_configuration', 'feature comes from adapter metadata without a provider-specific core branch');
failures(403, 'another owner cannot read the instance', sub {$controller->get_for_api(user_service_id => $other_usi)});
failures(403, 'another owner cannot write the instance', sub {$controller->save_for_api(user_service_id => $other_usi, enabled => 1)});
failures(403, 'client cannot call administrator retry', sub {$controller->admin_retry_for_api(user_service_id => $usi)});
failures(400, 'enabled config requires a secret', sub {$controller->save_for_api(user_service_id => $usi, enabled => 1, data => {})});

my $saved = $controller->save_for_api(user_service_id => $usi, enabled => 1,
    data => {rules => ['example.test'], summary => 'public'}, secret => {arbitrary_key => 'unit-private-secret'});
is($saved->{status}, 'queued', 'active instance saves and queues asynchronously');
ok($saved->{has_secret}, 'response exposes only the presence of a secret');
unlike(encode_json($saved), qr/unit-private-secret|\"secret\"\s*:/, 'API response contains neither plaintext nor ciphertext');
my $before = stored();
ok($before->{secret}, 'encrypted secret is persisted');
is_deeply($before->{target}, {adapter => 'service_options_fixture', server_id => $servers[0]}, 'only the original adapter and server are persisted as target');
ok(!exists($before->{requires_secret}) && !exists($before->{target}{feature}) && !exists($before->{target}{requires_secret}),
    'saved capability and credential policy have no redundant fields');
unlike(encode_json($before), qr/unit-private-secret/, 'SQL configuration does not contain plaintext');
is_deeply($controller->secret_for_api(user_service_id => $usi), {secret => {arbitrary_key => 'unit-private-secret'}},
    'only the explicit owner read decrypts the saved generic secret');
{
    no warnings 'redefine';
    local *Core::ServiceOptions::_decrypt = sub {die 'decryption must not precede ownership validation'};
    failures(403, 'a different owner cannot retrieve a secret', sub {$controller->secret_for_api(user_service_id => $other_usi)});
    actor(1);
    failures(403, 'an administrator has no owner-read bypass', sub {$controller->secret_for_api(user_service_id => $usi)});
    actor($owner);
}
$dbh->commit;
{
    local $ServiceOptionsKeyLossFixture::directory = tempdir(CLEANUP => 1);
    my $lost_key_controller = bless {}, 'ServiceOptionsKeyLossFixture';
    ok(!eval {$lost_key_controller->_key; 1}, 'real database encrypted records block lost-key regeneration');
    like($@, qr/\ASERVICE_OPTIONS_KEY_MISSING/, 'real database guard reports the fixed key-loss code');
    ok(!-e "$ServiceOptionsKeyLossFixture::directory/key", 'key-loss failure leaves the missing file absent');
    failures(503, 'owner read fails safely if its encryption key is missing', sub {$lost_key_controller->secret_for_api(user_service_id => $usi)});
    is(stored()->{secret}, $before->{secret}, 'key-loss check does not rewrite existing ciphertext');
    sysopen(my $restored, "$ServiceOptionsKeyLossFixture::directory/key", O_WRONLY | O_CREAT | O_EXCL, 0600) or die $!;
    print {$restored} $controller->_key; close $restored;
    is_deeply($lost_key_controller->_decrypt($us, $before->{secret}), {arbitrary_key => 'unit-private-secret'},
        'restoring the original key makes the existing database ciphertext readable again');
}
{
    my $unsupported = decode_json(encode_json($before));
    $unsupported->{secret_box} = delete $unsupported->{secret};
    $unsupported->{status} = {state => 'submitted'};
    $dbh->do(q{UPDATE user_services SET settings=JSON_SET(settings,'$.options',CAST(? AS JSON)) WHERE user_service_id=?},
        undef, encode_json($unsupported), $usi);
    $dbh->commit;
    local $ServiceOptionsKeyLossFixture::directory = tempdir(CLEANUP => 1);
    my $guard = bless {}, 'ServiceOptionsKeyLossFixture';
    my $new_instance = get_service('us', _id => $other_usi);
    ok(!eval {$guard->_encrypt($new_instance, {arbitrary_key => 'new-private-value'}); 1},
        'another instance cannot create a replacement key while unrecognized protected storage exists');
    is(ref($@) eq 'HASH' ? $@->{message} : '', 'SERVICE_OPTIONS_CONFIG_INVALID', 'unexpected storage blocks key initialization with its own safe code');
    ok(!-e "$ServiceOptionsKeyLossFixture::directory/key", 'unexpected storage does not publish any replacement key');
    is(encode_json(stored()), encode_json($unsupported), 'refusal neither reads old secrets nor converts or clears the record');

    my $no_secret = {%$before, enabled => 0, status => 'disabled'};
    delete $no_secret->{secret};
    $dbh->do(q{UPDATE user_services SET settings=JSON_SET(settings,'$.options',CAST(? AS JSON)) WHERE user_service_id=?},
        undef, encode_json($no_secret), $usi);
    $dbh->commit;
    is(length($guard->_key), 32, 'legitimate current options without secrets still permit first key initialization');
    $dbh->do(q{UPDATE user_services SET settings=JSON_SET(settings,'$.options',CAST(? AS JSON)) WHERE user_service_id=?},
        undef, encode_json($before), $usi);
    $dbh->commit;
}
my $task = queued();
unlike(encode_json($task->get), qr/unit-private-secret|\"secret\"\s*:|example\.test/, 'queue contains only identifiers and fixed target, never config snapshots');
is_deeply($task->settings->{user_service_ids}, [$usi], 'queued instance identity is explicit');
is_deeply([sort keys %{$task->settings}], [qw(feature target user_service_ids)], 'queue stores only feature, target and instance identities');
is($task->get_user_id, 1, 'background task has the trusted administrator context');
is(fresh_us()->settings->{server_id}, $servers[0], 'save cannot reassign the provisioned server');
is($us->settings->{description}, 'keep-note', 'save preserves other settings');

# Stale note/transport objects must not overwrite the independently saved data.
my $stale = {description => 'old', server_id => $servers[0]};
$us->res->{settings} = $stale;
ok($us->settings_save, 'legacy transport settings save succeeds');
is(stored()->{secret}, $before->{secret}, 'legacy stale settings preserve the latest encrypted user subtree');
$us->api_add_description(description => 'new-note');
is(stored()->{secret}, $before->{secret}, 'note update cannot discard service options');
is(fresh_us()->settings->{description}, 'new-note', 'note behavior is preserved');

$saved = $controller->save_for_api(user_service_id => $usi, enabled => 1, data => {rules => ['new.test']});
is(stored()->{secret}, $before->{secret}, 'omitted secret preserves existing ciphertext');
is_deeply($saved->{data}, {rules => ['new.test']}, 'provided data replaces only the public data object');
failures(400, 'recognized secrets cannot be stored in public data', sub {$controller->save_for_api(user_service_id => $usi, enabled => 1, data => {pass => 'secret'})});

my $stable = encode_json(stored());
{
    no warnings 'redefine';
    local *Core::Spool::add = sub {die "injected enqueue failure\n"};
    failures(500, 'enqueue failure rolls configuration back in the same transaction', sub {
        $controller->save_for_api(user_service_id => $usi, enabled => 0, data => {rules => ['must-not-persist']})});
}
is(encode_json(stored()), $stable, 'failed save cannot leave a partial SQL configuration');

my (@payloads, @targets, $send_hook, $transport_fail, $cleaned, $disable_ack, $throw_adapter, $timeout_adapter, $result_state, $omit_receipt, $receipt_errors, $accepted_override);
{
    package Core::Integrations::ServiceOptionsFixture;
    sub new {bless {}, shift}
    our $hook;
    sub metadata {return {feature => 'test_configuration', requires_secret => 1}}
    sub apply {shift; return $hook->(@_)}
    BEGIN {$INC{'Core/Integrations/ServiceOptionsFixture.pm'} = __FILE__}
}
{
    no warnings 'redefine';
    local $Core::Integrations::ServiceOptionsFixture::hook = sub {
        my %args = @_;
        die "SERVICE_OPTIONS_KEY_MISSING\n" if ($throw_adapter // '') eq 'key_missing';
        die "must-not-log-private-adapter-failure\n" if $throw_adapter;
        select undef, undef, undef, 2 if $timeout_adapter;
        my $payload = decode_json(encode_json($args{payload}));
        push @payloads, $payload;
        push @targets, $args{settings}{fixture_server_id};
        ok(ref($args{state_factory}) eq 'CODE' && ref($args{current_items}) eq 'CODE',
            'adapter receives only payload, trusted settings and controlled state callbacks');
        $send_hook->(\%args) if $send_hook;
        my %results = map {
            my $id = $_->{user_service_id};
            my $state = $result_state || ($cleaned ? 'cleaned' : $transport_fail ? 'error' : $disable_ack ? 'disabled' : 'submitted');
            ($id => {state => $state, $state eq 'error' ? (error => $receipt_errors && exists($receipt_errors->{$id})
                ? $receipt_errors->{$id} : 'REMOTE_HTTP') : ()});
        } @{$payload->{items}};
        %results = () if $omit_receipt;
        my $accepted = defined($accepted_override) ? $accepted_override : !$transport_fail;
        return ($accepted ? 1 : 0, {items => \%results});
    };
    actor(1);
    $dbh->commit;
    $task = queued();
    my $original = encode_json($task->settings);
    my $binding = {feature => $task->settings->{feature}, target => decode_json(encode_json($task->settings->{target}))};
    my $lock_hash = Core::ServiceOptions::_group($binding);
    my ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'trusted native adapter acknowledgment completes the task');
    is($payloads[-1]{items}[0]{secret}{arbitrary_key}, 'unit-private-secret', 'secret is decrypted only into the in-memory adapter payload');
    is(encode_json($task->settings), $original, 'native execution never modifies task settings');
    is(Core::ServiceOptions::_group({feature => $task->settings->{feature}, target => $task->settings->{target}}),
        $lock_hash, 'real worker execution preserves the numeric target lock identity');
    ok(!exists $task->{answer}, 'adapter receives no task object that could retain decrypted input');
    is(stored()->{status}, 'submitted', 'status records accepted synchronization without claiming node application');
    is(fresh_us()->get_status, STATUS_ACTIVE, 'configuration task does not change service lifecycle');
    is($us->settings->{server_id}, $servers[0], 'configuration task does not change assigned server');

    $dbh->commit; # Each real spool attempt commits before another begins.
    my (undef, $plain_adapter) = $controller->_target({feature => 'test_configuration', target => {adapter => 'service_options_fixture', server_id => $servers[0]}});
    ok(!$plain_adapter->can('register'), 'an installed plain Perl adapter loads without ServiceManager registration');
    $result_state = 'waiting_service';
    ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'an active SHM service may wait for its external resource');
    is(stored()->{status}, 'waiting_service', 'waiting acknowledgment does not claim external activation');
    undef $result_state;
    $dbh->commit;

    my $state_scope = "$tag-remote-resource";
    $send_hook = sub {
        my ($args) = @_;
        my $current = $args->{current_items}->([$usi, $other_usi]);
        is_deeply([map {$_->{user_service_id}} @$current], [$usi], 'recovery reads only existing configurations authorized by this target');
        is($current->[0]{secret}{arbitrary_key}, 'unit-private-secret', 'fresh recovery plaintext exists only in callback memory');
        my $state = $args->{state_factory}->($state_scope);
        $state->save({pending => $args->{payload}});
        die "raw-adapter-failure-unit-private-secret\n";
    };
    ($result, my $failure) = $controller->sync_task($task);
    is($result, FAIL, 'adapter failure remains retryable after persisting pending work');
    is_deeply($failure, {error => 'SERVICE_OPTIONS_SYNC_FAILED'}, 'arbitrary adapter exception is never returned to queue history');
    is(stored()->{error}, 'SERVICE_OPTIONS_SYNC_FAILED', 'public status contains only a fixed safe failure code');
    is(encode_json($task->settings), $original, 'even failed native execution never stores plaintext in queue settings');
    $dbh->commit;
    $send_hook = sub {
        my ($args) = @_;
        my $state = $args->{state_factory}->($state_scope);
        is($state->load->{pending}{items}[0]{secret}{arbitrary_key}, 'unit-private-secret', 'a retry reacquires the released scope lock and recovers its encrypted pending operation');
        $state->clear;
    };
    ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'successful recovery completes the original task');
    undef $send_hook;
    $dbh->commit;

    {
        # Exercise the real total-alarm control flow with an accelerated timer.
        # The production contract must request 90s, never a per-target override.
        my $real_alarm = \&Time::HiRes::alarm;
        my @durations;
        local *Time::HiRes::alarm = sub {
            my ($seconds) = @_;
            push @durations, $seconds;
            return $real_alarm->($seconds == 90 ? 0.05 : $seconds);
        };
        $timeout_adapter = 1;
        my $started = Time::HiRes::time();
        ($result, $failure) = $controller->sync_task($task);
        is($result, FAIL, 'the entire adapter invocation has a bounded timeout');
        is_deeply($failure, {error => 'SERVICE_OPTIONS_TIMEOUT'}, 'total timeout has a fixed recoverable error');
        ok(scalar(grep {$_ == 90} @durations), 'the controller always requests its fixed 90-second total budget');
        cmp_ok(Time::HiRes::time() - $started, '<', 2, 'total deadline interrupts adapter work before its longer internal delay');
    }
    undef $timeout_adapter;
    $dbh->commit;
    $omit_receipt = 1;
    ($result) = $controller->sync_task($task);
    is($result, FAIL, 'an adapter cannot acknowledge a batch with missing identities');
    ok(stored()->{secret}, 'invalid adapter acknowledgment never erases the user secret');
    undef $omit_receipt;
    $dbh->commit;
    ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'a valid retry remains possible after timeout and invalid receipt');

    $dbh->commit;
    $throw_adapter = 'key_missing';
    ($result, $failure) = $controller->sync_task($task);
    is($result, FAIL, 'a missing-key exception remains retryable');
    is_deeply($failure, {error => 'SERVICE_OPTIONS_KEY_MISSING'}, 'missing-key semantics override provider diagnostics');
    undef $throw_adapter;
    $dbh->commit;

    actor($other);
    ok($controller->save_for_api(user_service_id => $other_usi, enabled => 0), 'another owner stores an independent batch item');
    $dbh->commit;
    actor(1);
    my $batch_task = bless {res => {settings => {feature => $task->settings->{feature}, target => $task->settings->{target}, user_service_ids => [$usi, $other_usi]}}}, 'Core::Spool';
    $transport_fail = 1;
    ($result, $failure) = $controller->sync_task($batch_task);
    is($result, FAIL, 'an agreeing failed batch remains a failed task');
    is_deeply($failure, {error => 'REMOTE_HTTP'}, 'actual common provider code reaches the task result');
    $dbh->commit;
    $receipt_errors = {$usi => 'REMOTE_HTTP', $other_usi => 'STATE_UNSAFE'};
    ($result, $failure) = $controller->sync_task($batch_task);
    is($result, FAIL, 'mixed provider errors retain retry behavior');
    is_deeply($failure, {error => 'SERVICE_OPTIONS_SYNC_FAILED', errors => {$usi => 'REMOTE_HTTP', $other_usi => 'STATE_UNSAFE'}},
        'mixed failures retain fixed per-service diagnostics without config snapshots');
    $dbh->commit;
    $receipt_errors->{$other_usi} = 'raw-provider-error-private-secret';
    ($result, $failure) = $controller->sync_task($batch_task);
    is($failure->{errors}{$other_usi}, 'SERVICE_OPTIONS_ERROR', 'untrusted provider text becomes a safe fixed code');
    unlike(encode_json($failure), qr/raw-provider|private-secret|\"secret\"\s*:/, 'mixed task diagnostics contain no arbitrary provider text or ciphertext');
    $dbh->commit;
    $receipt_errors = {$usi => 'INVALID_RULES', $other_usi => 'INVALID_RULES'};
    $accepted_override = 1;
    ($result, $failure) = $controller->sync_task($batch_task);
    is($result, SUCCESS, 'per-item validation errors do not turn an accepted batch into a retry');
    is_deeply($failure, {message => 'SERVICE_OPTIONS_SYNC_ACCEPTED', errors => {$usi => 'INVALID_RULES', $other_usi => 'INVALID_RULES'}},
        'successful validation batches retain safe item diagnostics and their existing success semantics');
    is(stored()->{error}, 'INVALID_RULES', 'individual public error status remains unchanged');
    undef $receipt_errors; undef $accepted_override; $transport_fail = 0;
    $dbh->commit;

    # A worker may already have a repeatable-read snapshot before waiting for
    # the target file lock. Its later current read must see a committed save.
    $dbh->commit;
    my $worker = $dbh->clone({RaiseError => 1, AutoCommit => 0, InactiveDestroy => 1});
    my $api_dbh = $dbh->clone({RaiseError => 1, AutoCommit => 0, InactiveDestroy => 1});
    $worker->do(q{SET SESSION transaction_isolation='REPEATABLE-READ'});
    $worker->selectrow_array('SELECT settings FROM user_services WHERE user_service_id=?', undef, $usi);
    get_service('config')->local('dbh', $api_dbh);
    actor($owner);
    ok($controller->save_for_api(user_service_id => $usi, enabled => 1,
        data => {rules => ['fresh-after-worker-snapshot.test']}), 'second connection saves after worker snapshot creation');
    $api_dbh->commit;
    get_service('config')->local('dbh', $worker);
    actor(1);
    ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'worker can synchronize despite its older transaction snapshot');
    is($payloads[-1]{items}[0]{data}{rules}[0], 'fresh-after-worker-snapshot.test',
        'target lock is followed by a locking current read, not stale repeatable-read data');
    $worker->rollback;
    get_service('config')->local('dbh', $dbh);
    $api_dbh->disconnect; $worker->disconnect;

    # A concurrent, newer save must win over the old adapter result.
    $send_hook = sub {
        my $api_connection = $dbh->clone({RaiseError => 1, AutoCommit => 0, InactiveDestroy => 1});
        $api_connection->do('SET SESSION innodb_lock_wait_timeout=1');
        get_service('config')->local('dbh', $api_connection);
        actor($owner);
        ok($controller->save_for_api(user_service_id => $usi, enabled => 0),
            'independent API connection updates the instance while the adapter is in progress');
        $api_connection->commit;
        get_service('config')->local('dbh', $dbh);
        $api_connection->disconnect;
        actor(1);
    };
    ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'transport may finish while another save occurs');
    is(stored()->{enabled}, 0, 'new save remains authoritative');
    is(stored()->{status}, 'queued', 'old receipt cannot overwrite the newer saved status');
    undef $send_hook;

    $dbh->do('UPDATE user_services SET status=? WHERE user_service_id=?', undef, STATUS_BLOCK, $usi);
    actor($owner);
    $saved = $controller->save_for_api(user_service_id => $usi, enabled => 1);
    is($saved->{status}, 'waiting_service', 'blocked instance retains preference without remote activation');
    $saved = $controller->save_for_api(user_service_id => $usi, enabled => 0);
    is($saved->{status}, 'queued', 'explicit disable is queued even while the service is blocked');
    ok($saved->{has_secret}, 'disabled config retains encrypted credentials');

    # A changed administrator target must not orphan the previously published
    # target. Disable confirms retirement at A before enable can use B.
    $dbh->do(q{UPDATE user_services SET settings=JSON_SET(settings,'$.server_id',?) WHERE user_service_id=?}, undef, $servers[1], $usi);
    failures(409, 'unconfirmed old target prevents following a new provisioned server', sub {
        $controller->save_for_api(user_service_id => $usi, enabled => 1)});
    my $ambiguous = {fixture_server_id => $servers[1], service_options_fixture => {}, remnawave => {}};
    $dbh->do('UPDATE servers SET settings=? WHERE server_id=?', undef, encode_json($ambiguous), $servers[1]);
    $dbh->commit;
    $saved = $controller->save_for_api(user_service_id => $usi, enabled => 0);
    ok($saved, 'ambiguous current server capability cannot prevent disabling the stored valid target');
    is(stored()->{target}{server_id}, $servers[0], 'disable remains bound to the old target A');
    $dbh->commit;
    actor(1); $disable_ack = 1;
    $task = queued();
    ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'old target disable is confirmed successfully');
    is($targets[-1], $servers[0], 'only the old server A receives the disable request');
    is(stored()->{status}, 'disabled', 'explicit remote disable acknowledgment permits migration');
    $dbh->commit;
    actor($owner); $disable_ack = 0;
    $dbh->do('UPDATE servers SET settings=? WHERE server_id=?', undef, encode_json({fixture_server_id => $servers[1], service_options_fixture => {}}), $servers[1]);
    $dbh->commit;
    $dbh->do('UPDATE user_services SET status=? WHERE user_service_id=?', undef, STATUS_ACTIVE, $usi);
    {
        local *Core::Integrations::ServiceOptionsFixture::metadata = sub {{feature => 'another_feature', requires_secret => 1}};
        my $previous = encode_json(stored());
        failures(409, 'a changed module feature cannot reinterpret retained data after disable', sub {
            $controller->save_for_api(user_service_id => $usi, enabled => 1)});
        is(encode_json(stored()), $previous, 'feature mismatch preserves the old target, ciphertext and data');
    }
    ok($controller->save_for_api(user_service_id => $usi, enabled => 1), 'enable may use target B after A has been disabled');
    is(stored()->{target}{server_id}, $servers[1], 'new configuration is now bound to B');
    $dbh->commit;
    actor(1);
    $task = queued();
    ($result) = $controller->sync_task($task);
    is($targets[-1], $servers[1], 'new active configuration is delivered only to server B');
    $dbh->do('UPDATE servers SET settings=? WHERE server_id=?', undef, encode_json($ambiguous), $servers[1]);
    $dbh->commit;

    actor(1);
    $dbh->do(q{UPDATE user_services SET status=?,settings=JSON_SET(settings,'$.server_id',NULL) WHERE user_service_id=?}, undef, STATUS_REMOVED, $usi);
    $controller->lifecycle_changed(fresh_us(), STATUS_REMOVED);
    $task = queued();
    $dbh->commit;
    $transport_fail = 1;
    ($result) = $controller->sync_task($task);
    is($result, FAIL, 'retryable helper failure remains a failed task');
    is($targets[-1], $servers[1], 'REMOVE still retires stored target B after the service binding is cleared and current server metadata is ambiguous');
    ok(stored()->{secret}, 'failed remote cleanup cannot erase secrets prematurely');
    is_deeply($payloads[-1]{items}[0]{secret}, {}, 'remote cleanup does not need or receive plaintext secret');
    $dbh->commit; # spool.pl commits each failed attempt before a later retry.
    $transport_fail = 0; $cleaned = 1;
    ($result) = $controller->sync_task($task);
    is($result, SUCCESS, 'explicit cleaned receipt completes removal');
    ok(!stored()->{secret}, 'confirmed cleanup erases the encrypted secret');
    is_deeply(stored()->{data}, {}, 'confirmed cleanup erases public configuration');
    is(stored()->{status}, 'cleaned', 'small tombstone prevents repeated cleanup');
}

# The daily cleanup coalesces removed instances by the fixed target target.
for my $id (@instances[1,2]) {
    actor($other);
    ok($controller->save_for_api(user_service_id => $id, enabled => 0, data => {test => $id}),
        'second owner saves an independent disabled configuration');
    actor(1);
    my $instance = get_service('us', _id => $id);
    local $controller->{_defer_cleanup} = 1;
    $instance->status(STATUS_REMOVED);
}
actor(1);
is($controller->cleanup, 2, 'periodic cleanup selects only the two unconfirmed removed instances');
my ($batch) = $dbh->selectrow_array(q{SELECT settings FROM spool WHERE event->>'$.name'='SERVICE_OPTIONS' AND JSON_CONTAINS(settings,?,'$.user_service_ids') ORDER BY id DESC LIMIT 1},
    undef, encode_json([@instances[1,2]]));
is_deeply(decode_json($batch)->{user_service_ids}, [@instances[1,2]], 'removed instances sharing a target are queued together');

actor($owner);
failures(409, 'removed instance cannot save new preferences', sub {$controller->save_for_api(user_service_id => $usi, enabled => 0)});
failures(409, 'removed instance cannot retrieve its former secret', sub {$controller->secret_for_api(user_service_id => $usi)});


done_testing();
