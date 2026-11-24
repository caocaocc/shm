use v5.14;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use DBI;
use JSON::PP;
use Core::Routing::Install ();
use Core::Routing::Legacy ();

plan skip_all => 'set ROUTING_MIGRATION_TEST to run against the isolated routing_migration_qa database'
    unless $ENV{ROUTING_MIGRATION_TEST};
my $dbh = DBI->connect('dbi:mysql:database=routing_migration_qa;host=' . ($ENV{DB_HOST} // '127.0.0.1'),
    $ENV{DB_USER} // 'root', $ENV{DB_PASS} // '', {RaiseError=>1, PrintError=>0, mysql_enable_utf8mb4=>1});
my $root = tempdir(CLEANUP => 1);
my $json = JSON::PP->new->canonical;
for (
    'storage (user_id INT, name CHAR(32), data MEDIUMBLOB, PRIMARY KEY (user_id,name))',
    'templates (id CHAR(32) PRIMARY KEY,data MEDIUMTEXT,settings JSON)',
    'config (`key` CHAR(32) PRIMARY KEY,value JSON)',
    'events (id INT PRIMARY KEY, kind CHAR(32),name CHAR(32),server_gid INT,settings JSON)',
    'spool (id INT PRIMARY KEY,user_id INT,user_service_id INT,settings JSON,event JSON,status CHAR(8),executed DATETIME,`delayed` INT,prio INT)',
) {
    $dbh->do("CREATE TEMPORARY TABLE $_ ENGINE=InnoDB");
}
sub config { $json->decode($dbh->selectrow_array(q{SELECT value FROM config WHERE `key`='routing'})) }
sub install { Core::Routing::Install::install($dbh) }

SKIP: {
    skip 'exercise the official root entrypoint and www-data ownership', 4 unless $> == 0;
    mkdir "$root/data", 0755 or die $!;
    Core::Routing::Install::prepare_volume($root);
    my $dir = "$root/data/routing-templates";
    my ($uid,$gid) = (getpwnam('www-data'))[2,3];
    my @private = lstat $dir;
    is_deeply([$private[4],$private[2] & 0777],[$uid,0700],'fresh root-owned volume gains a private worker directory');
    ok(!-e "$dir/key",'initialization leaves key generation to the first save');
    open my $fh,'>:raw',"$dir/key" or die $!;
    print {$fh} 'a' x 32;
    close $fh;
    chown($uid, $gid, "$dir/key") or die $!;
    chmod(0400, "$dir/key") or die $!;
    Core::Routing::Install::prepare_volume($root);
    is((stat "$dir/key")[2] & 0777,0400,'restore preserves a private read-only key');
    chmod(0644, "$dir/key") or die $!;
    eval { Core::Routing::Install::prepare_volume($root) };
    like($@,qr/Invalid routing key or permissions/,'an exposed key is reported without replacement');
}

$dbh->begin_work;
install();
is_deeply(config(), {batch_window_seconds=>3,min_publish_interval_seconds=>3600}, 'native defaults on a fresh database');
is($dbh->selectrow_array('SELECT COUNT(*) FROM storage'),0,'no installation marker or new key required');
$dbh->do(q{UPDATE config SET value='{"min_publish_interval_seconds":1733,"extra":"keep"}' WHERE `key`='routing'});
$dbh->do(q{INSERT INTO templates VALUES ('routing','edited form','{}'),('remnawave_routing','edited worker','{}'),
                                         ('account','unchanged','{}')});
my $binding = {category=>'vpn',template_id=>'remnawave_routing'};
$dbh->do(q{INSERT INTO events VALUES (9,'UserService','changed',1,?)},undef,$json->encode($binding));
my $scope = 'a' x 64;
my $control = $json->encode({scope=>$scope,job=>40,pending=>{9=>[6,2]},due=>9001,last_sync=>8500,uncertain=>1,cursor=>3});
$dbh->do('INSERT INTO storage VALUES (0,?,?),(0,?,?)',undef,'routingp:'.substr($scope,0,23),$control,'routing:9','ciphertext');
$dbh->do(q{INSERT INTO spool VALUES (40,1,NULL,?,?,'DELAYED','2026-01-02 03:04:05',55,100),
                                    (41,6,9,?,?,'NEW',NULL,0,12),(42,6,9,?,?,'NEW',NULL,0,12),
                                    (43,6,9,?,?,'NEW',NULL,0,12)},undef,
    $json->encode({template_id=>'remnawave_routing',transport=>'local',routing_panel=>$scope}),
    '{"name":"CHANGED","title":"同步面板分流配置"}',
    '{"server_id":3,"user_service_id":9}', $json->encode({name=>'changed',kind=>'UserService',server_gid=>1,settings=>$binding}),
    '{}', $json->encode({name=>'BLOCK',settings=>$binding}),
    $json->encode({user_service_id=>9,template_id=>'account'}), $json->encode({name=>'changed',settings=>$binding}));
install();
install();
is_deeply(config(),{batch_window_seconds=>3,min_publish_interval_seconds=>1733,extra=>'keep'},'keep native timing and fill missing defaults');
is($dbh->selectrow_array(q{SELECT COUNT(*) FROM templates}),3,'installed manuscripts preserved');
is_deeply($dbh->selectrow_arrayref(q{SELECT server_gid,name,settings->>'$.category' FROM events WHERE id=9}),
    [1,'changed','vpn'],'event 9 keeps its original binding');
is($dbh->selectrow_array(q{SELECT data FROM storage WHERE name='routing:9'}),'ciphertext','existing owner ciphertext is untouched');
is($dbh->selectrow_array(q{SELECT data FROM storage WHERE name LIKE 'routingp:%'}),$control,'outstanding receipt is unchanged');
is($dbh->selectrow_array(q{SELECT COUNT(*) FROM spool WHERE event->>'$.kind'='Routing'}),0,
    'boot does not scan or change queued jobs');
for my $id (40..43) {
    my $row = $dbh->selectrow_hashref('SELECT * FROM spool WHERE id=? FOR UPDATE',undef,$id);
    $row->{event} = $json->decode($row->{event});
    $row->{settings} = $json->decode($row->{settings});
    is(Core::Routing::Legacy::adopt($dbh,$row),$id < 42 ? 1 : undef,"job $id checked under its original lock");
}
my $panel = $dbh->selectrow_hashref('SELECT * FROM spool WHERE id=40');
is_deeply([@$panel{qw(status executed delayed prio)}],['DELAYED','2026-01-02 03:04:05',55,100],'panel job retains its schedule');
is($json->decode($panel->{event})->{method},'publish_task','same job ID dispatches to native panel worker');
is_deeply($json->decode($panel->{settings}),{routing_panel=>$scope},'original panel scope carried forward');
my $life = $dbh->selectrow_hashref('SELECT * FROM spool WHERE id=41');
is($life->{user_id},1,'cleanup task survives deletion of the owner');
is($json->decode($life->{event})->{method},'lifecycle_task','queued change requests a native state recheck');
is_deeply($json->decode($life->{settings}),{routing_service_id=>9,routing_user_id=>6},'native recheck uses original owner and service');
is($dbh->selectrow_array(q{SELECT COUNT(*) FROM spool WHERE id IN (42,43) AND user_id=6 AND event->>'$.method' IS NULL}),2,
    'nonstandard and conflicting jobs never acquire system authority');
is($dbh->selectrow_array('SELECT COUNT(*) FROM spool'),4,'restart does not duplicate queued work');
$dbh->rollback;
done_testing;
