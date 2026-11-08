use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Core::ServiceOptions;
use Core::ServiceOptions::State;

my $root = tempdir(CLEANUP => 1);
local $ENV{SHM_ROOT_DIR} = $root;
no warnings 'redefine';
local *Core::ServiceOptions::_has_encrypted_secrets = sub {0};
my $controller = bless {}, 'Core::ServiceOptions';
my $scope = 'example_adapter:https://api.example.test:snippet-a:snippet-b';
my $state = Core::ServiceOptions::State->new(controller => $controller, scope => $scope);
is($state->load, undef, 'a fresh resource has no pending state');
my $pending = {phase => 'first_patch', secret => 'private-state-value', label => '中文恢复记录'};
ok($state->save($pending), 'encrypted pending operation is durably saved');
is_deeply($state->load, $pending, 'state load authenticates and preserves complete JSON');
is((stat($state->{path}))[2] & 0777, 0600, 'journal has private permissions');
open my $in, '<', $state->{path} or die $!;
my $bytes = do {local $/; <$in>}; close $in;
unlike($bytes, qr/private-state-value|first_patch/, 'journal never contains plaintext credentials or operations');
ok(!eval {Core::ServiceOptions::State->new(controller => $controller, scope => $scope); 1},
    'the same remote scope cannot execute concurrently even in another server context');
like($@, qr/\ASERVICE_OPTIONS_BUSY/, 'scope lock conflict is a fixed retryable error');

my $other = Core::ServiceOptions::State->new(controller => $controller, scope => "$scope-other");
ok($other->save({pending => 1}), 'unrelated resource scopes can execute independently');
copy($state->{path}, $other->{path}) or die $!;
ok(!eval {$other->load; 1}, 'copying ciphertext to another scope fails authenticated decryption');
$other->clear;
$other->close;

my $key_path = "$root/data/service-options/key";
rename $key_path, "$root/original-key" or die $!;
ok(!eval {$controller->_key; 1}, 'an existing journal alone blocks lost-key regeneration');
like($@, qr/\ASERVICE_OPTIONS_KEY_MISSING/, 'journal key loss reports the fixed recovery error');
ok(!-e $key_path, 'missing-key protection does not publish a replacement key');
rename "$root/original-key", $key_path or die $!;
is_deeply($state->load, $pending, 'restoring the original key recovers the pending operation');

chmod 0644, $state->{path};
ok(!eval {$state->load; 1}, 'insecure journal modes are rejected on reads');
ok(!eval {$state->save({replacement => 1}); 1}, 'insecure journal modes are rejected on writes');
chmod 0600, $state->{path};
my $path = $state->{path};
rename $path, "$root/original-state" or die $!;
symlink "$root/original-state", $path or die $!;
ok(!eval {$state->load; 1}, 'journal symlinks are rejected');
ok(!eval {$state->clear; 1}, 'journal clear cannot follow a symlink');
unlink $path;
rename "$root/original-state", $path or die $!;
link $path, "$root/state-hardlink" or die $!;
ok(!eval {$state->load; 1}, 'journal hardlinks are rejected');
unlink "$root/state-hardlink";
ok($state->close, 'scope can be explicitly released');
ok($state->close, 'close is idempotent');
ok(!eval {$state->load; 1}, 'a released object cannot access state without its lock');
my $reopened = Core::ServiceOptions::State->new(controller => $controller, scope => $scope);
is_deeply($reopened->load, $pending, 'a later retry can resume the same encrypted operation');
$reopened->clear;
is($reopened->load, undef, 'clear removes only this scope pending state');
$reopened->close;
my $transient = Core::ServiceOptions::State->new(controller => $controller, scope => $scope);
undef $transient;
ok(eval {Core::ServiceOptions::State->new(controller => $controller, scope => $scope)->close; 1},
    'destruction releases a forgotten scope lock');

done_testing();
