use v5.14;
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../pay_systems/epay/lib";
use SHM ();
use Core::System::ServiceManager qw(get_service);
use SHM::Pay::Epay::Install;
use SHM::Pay::Epay::Vault qw(account_values);
use JSON::PP;

SHM::db_connect();
my $db = get_service('config')->local('dbh');
local $db->{RaiseError} = 1;
# Each temporary table shadows its real counterpart only inside this connection.
# The matching site key is a fixture and this test never opens the data volume.
$db->do('CREATE TEMPORARY TABLE config (`key` VARCHAR(64) PRIMARY KEY,value JSON NOT NULL)');
$db->do('CREATE TEMPORARY TABLE epay_accounts (profile VARCHAR(32) PRIMARY KEY,credential_box MEDIUMTEXT NOT NULL)');
no warnings 'redefine';
local *SHM::Pay::Epay::Vault::site_key = sub { 'x' x 32 };
my $json = JSON::PP->new->ascii->canonical;
my $config = {epay=>{name=>'Base'}, other=>{name=>'Other gateway'},
    old_copy=>{paysystem=>'epay',name=>'Existing channel',apiurl=>'https://gateway.example.test',pid=>'421',key=>'previous-secret'}};
my $legacy = {old_copy=>{apiurl=>'https://gateway.example.test',pid=>'421',key=>'different-secret'}};
sub insert_setting { $db->do('INSERT INTO config(`key`,value) VALUES(?,?)', undef, $_[0], $json->encode($_[1])) }
insert_setting('pay_systems',$config);
insert_setting('epay_merchants',$legacy);
$db->commit;
ok(!eval { SHM::Pay::Epay::Install::registration($db);1 }, 'ambiguous private and public merchant values abort the migration');
$db->rollback;
my ($before) = $db->selectrow_array(q{SELECT value FROM config WHERE config.key='pay_systems'});
is_deeply($json->decode($before),$config,'conflicting source configuration is preserved');
is($db->selectrow_array('SELECT COUNT(*) FROM epay_accounts'),0,'no partial migrated merchant');
$legacy->{old_copy}{key}='previous-secret';
$db->do(q{UPDATE config SET value=? WHERE config.key='epay_merchants'},undef,$json->encode($legacy));
SHM::Pay::Epay::Install::registration($db);
$db->commit;
my ($encoded) = $db->selectrow_array(q{SELECT credential_box FROM epay_accounts WHERE profile='old_copy'});
is_deeply(account_values($db,'old_copy',$encoded),$legacy->{old_copy},'legacy signing values moved to the correct private envelope');
my ($new) = $db->selectrow_array(q{SELECT value FROM config WHERE config.key='pay_systems'});
unlike($new,qr/previous-secret|gateway\.example\.test/,'native public catalogue exposes payment presentation only');
is($json->decode($new)->{old_copy}{name},'Existing channel','public name is preserved');
is_deeply($json->decode($new)->{other},$config->{other},'unrelated payment provider untouched');
is($db->selectrow_array(q{SELECT COUNT(*) FROM config WHERE config.key='epay_merchants'}),0,'retired private configuration no longer available');
SHM::Pay::Epay::Install::registration($db);
is($db->selectrow_array(q{SELECT credential_box FROM epay_accounts WHERE profile='old_copy'}),$encoded,'repeated install leaves existing ciphertext byte-for-byte intact');
done_testing;
