use v5.14;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Core::ServiceOptions;

{
    package OptionsShapeInstance;
    sub res {$_[0]{res}}
    package OptionsShapeActor;
    sub is_admin {1}
    package OptionsShapeTask;
    sub settings {$_[0]{settings}}
}
my $json = JSON::PP->new->canonical;
sub copy {$json->decode($json->encode($_[0]))}
my $valid = {feature => 'example', enabled => 1, target => {adapter => 'example', server_id => 17},
    data => {label => 'public'}, secret => 'opaque-encrypted-value', status => 'queued'};
my $instance = bless {res => {settings => {options => copy($valid)}}}, 'OptionsShapeInstance';
my $original_json = $json->encode($instance->{res});
my $loaded = Core::ServiceOptions::_config($instance);
is_deeply($loaded, $valid, 'only the current persisted shape is read');
is($json->encode($instance->{res}), $original_json, 'validating storage never changes the original resource or its numeric JSON types');
is($json->encode($loaded), $json->encode($valid), 'returned CAS snapshot retains numeric target and enabled types');
my $binding = Core::ServiceOptions::_binding($loaded);
my $binding_json = $json->encode($binding);
my $lock_hash = Core::ServiceOptions::_group($binding);
ok(Core::ServiceOptions::_valid_binding($binding), 'detached binding validates');
is($json->encode($binding), $binding_json, 'target validation preserves numeric scalar flags');
is(Core::ServiceOptions::_group($binding), $lock_hash, 'validation cannot change the synchronization lock identity');
for my $options ({}, undef, [],
    {%$valid, policy => {adapter => 'example', server_id => 17}},
    {%$valid, secret_box => 'old-ciphertext'},
    {%$valid, requires_secret => 1},
    {%$valid, status => {state => 'queued'}},
    {%$valid, target => {%{$valid->{target}}, feature => 'example'}},
    {%$valid, target => {%{$valid->{target}}, requires_secret => 1}},
    {%$valid, secret => {outbound => 'not-ciphertext'}},
    {%$valid, status => 'submitted', error => 'STALE_ERROR'},
    {%$valid, status => 'error', error => 'raw private exception'}) {
    $instance->{res}{settings}{options} = copy($options);
    my $before = $json->encode($instance->{res});
    if (ref($options) eq 'HASH' && !keys(%$options)) {
        is_deeply(Core::ServiceOptions::_config($instance), {}, 'empty options means not configured');
    } else {
        ok(!eval {Core::ServiceOptions::_config($instance); 1}, 'old or malformed storage is refused without conversion');
        is(ref($@) eq 'HASH' ? $@->{message} : '', 'SERVICE_OPTIONS_CONFIG_INVALID', 'storage failure uses a fixed code');
    }
    is($json->encode($instance->{res}), $before, 'refused reads never rewrite or clear stored data');
}
for my $enabled (0, 1, JSON::PP::true, JSON::PP::false) {
    $instance->{res}{settings}{options} = {%$valid, enabled => $enabled};
    ok(eval {Core::ServiceOptions::_config($instance); 1}, 'valid persisted enabled values remain supported');
}
my $status = {%$valid};
Core::ServiceOptions::_set_status($status, 'error', 'REMOTE_HTTP');
is_deeply([@{$status}{qw(status error)}], ['error', 'REMOTE_HTTP'], 'failure stores status and error at the same level');
Core::ServiceOptions::_set_status($status, 'queued');
is($status->{status}, 'queued', 'requeue stores the scalar status');
ok(!exists($status->{error}), 'requeue clears obsolete error information');
Core::ServiceOptions::_set_status($status, 'error', 'private exception');
is($status->{error}, 'SERVICE_OPTIONS_ERROR', 'raw exception text never enters stored error');

{
    no warnings 'redefine';
    local *Core::ServiceOptions::_actor = sub {bless {}, 'OptionsShapeActor'};
    my $controller = bless {}, 'Core::ServiceOptions';
    my $task = {feature => 'example', target => $valid->{target}, user_service_ids => [12]};
    for my $settings ({policy => {adapter => 'example', server_id => 17, feature => 'example'}, user_service_ids => [12]},
        {%$task, requires_secret => 1}, {%$task, unknown => 'private-value'}) {
        my (undef, $result) = $controller->sync_task(bless {settings => $settings}, 'OptionsShapeTask');
        is_deeply($result, {error => 'SERVICE_OPTIONS_TASK_INVALID'}, 'old or extra task fields are refused without fallback');
    }
    for my $target ({adapter => '../example', server_id => 17}, {adapter => 'example', server_id => 0},
        {%{$valid->{target}}, feature => 'example'}, {%{$valid->{target}}, requires_secret => 1}) {
        my (undef, $result) = $controller->sync_task(bless {settings => {%$task, target => $target}}, 'OptionsShapeTask');
        is_deeply($result, {error => 'SERVICE_OPTIONS_TARGET_INVALID'}, 'invalid or redundant target fields are refused');
    }
}
done_testing();
