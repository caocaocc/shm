use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use Core::ServiceOptions;

{
    package Core::Integrations::ExampleAdapter;
    our ($constructed, $value) = (0, {feature => 'example_feature', requires_secret => 1});
    BEGIN {$INC{'Core/Integrations/ExampleAdapter.pm'} = __FILE__}
    sub new {$constructed++; bless {}, shift}
    sub metadata {$value}
    sub apply {die 'capability lookup must not execute the adapter'}
    package Core::Integrations::OtherAdapter;
    BEGIN {$INC{'Core/Integrations/OtherAdapter.pm'} = __FILE__}
    sub new {bless {}, shift}
    sub metadata {{feature => 'other_feature', requires_secret => 0}}
    sub apply {die 'capability lookup must not execute the adapter'}
    package Core::Integrations::BrokenAdapter;
    BEGIN {$INC{'Core/Integrations/BrokenAdapter.pm'} = __FILE__}
    sub new {die 'private-constructor-error'}
    package OptionsTargetDatabase;
    sub selectrow_array {
        my ($self, $sql, $attributes, $id) = @_;
        push @{$self->{queries}}, [$sql, $id];
        return $self->{rows}{$id};
    }
    package OptionsTargetController;
    our @ISA = ('Core::ServiceOptions');
    sub dbh_auto_commit {$_[0]{database}}
    package OptionsTargetInstance;
    sub service {die 'capability inference must not consult a package enable switch'}
    sub res {$_[0]{res}}
}

my $database = bless {rows => {}, queries => []}, 'OptionsTargetDatabase';
my $instance = bless {res => {settings => undef}}, 'OptionsTargetInstance';
my $controller = bless {database => $database}, 'OptionsTargetController';
is($controller->target_for($instance), undef, 'a service without an assigned server has no inferred capability');
is_deeply($database->{queries}, [], 'an unassigned service does not search other servers or provisioning groups');
$instance->{res}{settings} = {server_id => 17};
$database->{rows}{18} = {example_adapter => {}};
is($controller->target_for($instance), undef, 'another configured server cannot become an implicit target');
$database->{rows}{17} = {example_adapter => {}, port => 22, not_installed_for_options_test => {}, 'invalid/path' => {}};
my $binding = $controller->target_for($instance);
is_deeply($binding, {target => {adapter => 'example_adapter', server_id => 17}, feature => 'example_feature'},
    'assigned private settings infer only feature and target without package configuration');
my $again = $controller->target_for($instance);
is($Core::Integrations::ExampleAdapter::constructed, 2, 'lookups construct fresh ordinary adapter objects without a global cache');
is_deeply($again, $binding, 'normalization remains stable across fresh adapter objects');
ok(!grep({$_->[0] ne 'SELECT settings FROM servers WHERE server_id=?' || $_->[1] != 17} @{$database->{queries}}),
    'all discovery queries are restricted to the one assigned server');
$database->{rows}{17} = {example_adapter => 'not-an-object'};
is($controller->target_for($instance), undef, 'a provider key must hold a private settings object');
$database->{rows}{17} = {not_installed_for_options_test => {}};
is($controller->target_for($instance), undef, 'genuinely uninstalled modules are ignored');
$database->{rows}{17} = {example_adapter => {}, other_adapter => {}};
ok(!eval {$controller->target_for($instance); 1}, 'multiple installed matching integrations fail closed');
is(ref($@) eq 'HASH' ? $@->{status} : undef, 503, 'ambiguous capability has a fixed service-unavailable status');
$database->{rows}{17} = {broken_adapter => {}};
ok(!eval {$controller->target_for($instance); 1}, 'an installed module with a broken constructor is never treated as absent');
unlike(ref($@) eq 'HASH' ? $@->{message} : "$@", qr/private-constructor-error/, 'constructor failures never expose arbitrary exception text');
{
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/Core/Integrations");
    open my $file, '>', "$root/Core/Integrations/MissingDependencyAdapter.pm" or die $!;
    print {$file} "package Core::Integrations::MissingDependencyAdapter; require NonexistentServiceOptionsFixtureDependency; 1;\n";
    close $file;
    local @INC = ($root, @INC);
    $database->{rows}{17} = {missing_dependency_adapter => {}};
    ok(!eval {$controller->target_for($instance); 1}, 'a missing dependency inside an installed module is a failure, not unsupported');
    is(ref($@) eq 'HASH' ? $@->{status} : undef, 503, 'broken installed dependencies have a fixed safe failure');
}
$database->{rows}{17} = {example_adapter => {}};
for my $metadata (undef, {}, {feature => 'Bad Feature', requires_secret => 1},
    {feature => 'example_feature', requires_secret => {}},
    {feature => 'example_feature', requires_secret => 2},
    {feature => 'example_feature', requires_secret => 1, extra => 'not-public'}) {
    local $Core::Integrations::ExampleAdapter::value = $metadata;
    ok(!eval {$controller->target_for($instance); 1}, 'malformed installed adapter metadata fails closed');
}
{
    local $Core::Integrations::ExampleAdapter::value = {feature => 'example_feature', requires_secret => JSON::PP::false};
    is(Core::ServiceOptions::_metadata(Core::ServiceOptions::_load_adapter('example_adapter'))->{requires_secret}, 0, 'a module can support non-secret options without an administrator switch');
    ok(!exists($controller->target_for($instance)->{requires_secret}), 'credential requirements are not frozen in the target binding');
}
$instance->{res}{settings}{options} = {feature => 'example_feature', enabled => 1, data => {label => 'public'},
    secret => 'opaque-ciphertext', target => $binding->{target}, status => 'queued'};
my $public = $controller->_public($instance, $binding);
is($public->{feature}, 'example_feature', 'capability response uses the inferred feature name');
ok($public->{supported} && $public->{has_secret}, 'capability and secret-presence flags remain real JSON booleans');
ok(!exists($public->{kind}) && !exists($public->{target}) && !exists($public->{secret}), 'response exposes no private target or ciphertext');
is($public->{status}, 'queued', 'public synchronization status is a scalar');
ok(!exists($public->{error}), 'non-error response has no stale error');
is(Core::ServiceOptions::_group($binding), sha256_hex(JSON::PP->new->canonical->utf8->encode(
    ['example_adapter', 17, 'example_feature'])), 'lock identity preserves the original adapter/server/feature tuple bytes');
{
    local $Core::Integrations::ExampleAdapter::value = {feature => 'changed_feature', requires_secret => 0};
    ok(!eval {$controller->_target($binding); 1}, 'changed module metadata cannot reinterpret an existing target');
    is(ref($@) eq 'HASH' ? $@->{message} : '', 'SERVICE_OPTIONS_TARGET_CHANGED', 'feature mismatch uses the safe target-change code');
    is($controller->_public($instance, $controller->target_for($instance))->{feature}, 'example_feature',
        'ordinary reading does not relabel saved data using changed metadata');
}

$database->{rows}{17} = {};
is($controller->target_for($instance), undef, 'the next lookup reads current server settings instead of a cached capability');

done_testing();
