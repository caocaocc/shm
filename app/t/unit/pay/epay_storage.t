use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use lib ($ENV{SHM_ROOT_DIR} || '/app') . '/pay_systems/lib';
use SHM::Pay::Epay;
{
    package EpayStorage;
    use parent 'SHM::Pay::Epay';
    sub _has_encrypted_orders { $_[0]->{encrypted} // 0 }
}
my $source_root=$ENV{SHM_ROOT_DIR} || '/app';
my $root=tempdir(CLEANUP=>1);
local $ENV{SHM_ROOT_DIR}=$root;
no warnings 'redefine';
local *SHM::Pay::Epay::_storage_uid=sub{$>};
my $module=bless {},'EpayStorage';
my $key=$module->_key;
is(length($key),32,'module manages a random AES key without merchant config');
is($module->_key,$key,'module reuses the same key');
is((stat("$root/data/epay"))[2]&0777,0700,'private directory mode');
is((stat("$root/data/epay/key"))[2]&0777,0600,'private key mode');
rename("$root/data/epay/key","$root/data/epay/saved-key") or die $!;
$module->{encrypted}=1;
ok(!eval{$module->_key;1},'missing key with encrypted orders fails closed');
ok(!-e "$root/data/epay/key",'missing protected key is never silently replaced');
rename("$root/data/epay/saved-key","$root/data/epay/key") or die $!;
chmod 0644,"$root/data/epay/key";
ok(!eval{$module->_key;1},'world-readable key is rejected');
chmod 0600,"$root/data/epay/key";
rename("$root/data/epay/key","$root/data/epay/saved-key") or die $!;
symlink("$root/data/epay/saved-key","$root/data/epay/key") or die $!;
ok(!eval{$module->_key;1},'symbolic key is rejected');
unlink "$root/data/epay/key";
rename("$root/data/epay/saved-key","$root/data/epay/key") or die $!;
link("$root/data/epay/key","$root/data/epay/linked-key") or die $!;
ok(!eval{$module->_key;1},'hard-linked key is rejected');
unlink "$root/data/epay/linked-key";
is($module->_key,$key,'restoring the original protected file restores access');

done_testing();
