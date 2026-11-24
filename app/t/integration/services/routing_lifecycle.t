use v5.14;
use warnings;
use Test::More;
use DBI;
use Core::System::ServiceManager qw(get_service);
use Core::Const;
use SHM;

plan skip_all => 'requires the isolated routing_migration_qa database with the SHM schema'
    unless $ENV{ROUTING_MIGRATION_TEST};
$ENV{SHM_TEST} = 1;
my $dbh = DBI->connect('dbi:mysql:database=routing_migration_qa;host=' . ($ENV{DB_HOST} // '127.0.0.1'),
    $ENV{DB_USER} // 'root', $ENV{DB_PASS} // '', {RaiseError=>1,PrintError=>0,AutoCommit=>0,mysql_enable_utf8mb4=>1});
get_service('config')->local('dbh',$dbh);
SHM->new(user_id=>1);
my $owner = 742901;
my $usi = 742902;
my $other = $usi+1;
$dbh->do(q{INSERT INTO users (user_id,login,balance,bonus,credit,gid) VALUES (?,'route-lifecycle',100,0,0,2)}, undef,$owner);
$dbh->do(q{INSERT INTO services (service_id,name,cost,category) VALUES (?,'test',1,'test-routing')},undef,$usi);
for my $id ($usi,$other) {
    $dbh->do(q{INSERT INTO user_services (user_service_id,user_id,service_id,status_before,status,withdraw_id,expire)
               VALUES (?,?,?,'ACTIVE','ACTIVE',?,NOW()+INTERVAL 1 MONTH)}, undef,$id,$owner,$usi,$id);
    $dbh->do(q{INSERT INTO withdraw_history (withdraw_id,withdraw_date,user_id,service_id,user_service_id)
               VALUES (?,NOW(),?,?,?)},undef,$id,$owner,$usi,$id);
}
my $jobs = sub {
    return $dbh->selectcol_arrayref(q{SELECT settings->>'$.routing_service_id' FROM spool
        WHERE user_id=1 AND event->>'$.method'='lifecycle_task' AND settings->>'$.routing_user_id'=? ORDER BY id},undef,$owner);
};
my $us = get_service('us',_id=>$usi);
$us->set_status_manual(status=>STATUS_BLOCK);
is_deeply($jobs->(),[], 'status changes of an unconfigured service do not enqueue routing jobs');
$dbh->do(q{INSERT INTO storage (user_id,name,data) VALUES (0,?,'encrypted record')},undef,"routing:$usi");
$us->set_status_manual(status=>STATUS_ACTIVE);
is_deeply($jobs->(),[$usi], 'manual activation wakes a saved configuration without decrypting in the billing transaction');
$us->set_status_manual(status=>STATUS_ACTIVE);
is_deeply($jobs->(),[$usi], 'identical manual status produces no second job');
$us->status(STATUS_PROGRESS,event=>EVENT_PROLONGATE);
is_deeply($jobs->(),[$usi], 'renewal does not schedule a transient withdrawal');
$us->block_force;
is($us->get_status, STATUS_BLOCK, 'ordinary forced stop blocks the paid service');
$us->activate_force;
is($us->get_status, STATUS_ACTIVE, 'ordinary forced activation restores it');
is_deeply($jobs->(),[($usi)x3], 'both final lifecycle transitions queue a routing recheck');
subtest 'tariff reassignment rechecks routing without a status change or template' => sub {
    my $standard = $usi + 2;
    $dbh->do(q{INSERT INTO services (service_id,name,cost,category) VALUES (?,'Standard',1,'standard')},undef,$standard);
    $dbh->do(q{INSERT INTO servers (server_id,name,transport,host,settings) VALUES (?,'Fixture','local','localhost',
               '{"remnawave":{"api":"https://panel.example.com","token":"fixture"}}')},undef,$usi);
    $us->settings({server_id=>$usi})->settings_save();
    ok(Core::Routing->service_in_scope($dbh,$usi), 'service is bound to a configured panel');
    $us->change(service_id=>$standard,skip_check_allow_to_order=>1);
    is_deeply([$us->get_service_id,$us->get_status],[$standard,STATUS_ACTIVE],'active service moves to standard tariff');
    ok(Core::Routing->service_in_scope($dbh,$usi),'a change of tariff keeps the same panel eligible');
    is_deeply($jobs->(),[($usi)x4], 'worker rechecks the service after a tariff change');
    $us->change(service_id=>$usi,skip_check_allow_to_order=>1);
    is_deeply([$us->get_service_id,$us->get_status],[$usi,STATUS_ACTIVE],'active service moves back');
    ok(Core::Routing->service_in_scope($dbh,$usi),'both tariffs use the assigned panel');
    is_deeply($jobs->(),[($usi)x5], 'worker rechecks the saved intent');
    get_service('us',_id=>$other)->change(service_id=>$standard,skip_check_allow_to_order=>1);
    is_deeply($jobs->(),[($usi)x5], 'no task for a service without a saved record');
};
subtest 'admin editing the assigned server only wakes affected routes' => sub {
    ok($us->lock,'acquire the same row lock as POST /admin/user/service');
    $us->api_set(admin=>1,settings=>{server_id=>$usi,description=>'new display name'});
    is_deeply($jobs->(),[($usi)x5],'editing description keeps the same assignment');
    $us->api_set(admin=>1,settings=>{server_id=>$other});
    $us->api_set(admin=>1,settings=>{description=>'no assignment'});
    $us->api_set(admin=>1,settings=>{server_id=>$usi});
    is_deeply($jobs->(),[($usi)x8],'replacement, removal and re-assignment each wake the original receipt');
    get_service('us',_id=>$other)->api_set(admin=>1,settings=>{server_id=>$usi});
    is_deeply($jobs->(),[($usi)x8],'other services without saved routes remain untouched');
};
$us->status(STATUS_REMOVED,event=>EVENT_REMOVE);
is_deeply($jobs->(),[($usi)x9], 'removal queues a recheck before cleaning the service');
get_service('user',_id=>$owner)->delete(force=>1);
is($dbh->selectrow_array('SELECT COUNT(*) FROM users WHERE user_id=?',undef,$owner),0, 'forced account removal succeeds');
is_deeply($jobs->(),[($usi)x10], 'system queue survives account deletion and only includes the saved service');
is($dbh->selectrow_array(q{SELECT data FROM storage WHERE user_id=0 AND name=?}, undef,"routing:$usi"),'encrypted record',
    'account deletion leaves recovery data until the panel confirms');
$dbh->rollback;
done_testing;
