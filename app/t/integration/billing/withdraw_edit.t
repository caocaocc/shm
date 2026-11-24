use v5.14;
use Test::More;
use SHM;
use Core::Billing;
use Core::System::ServiceManager qw(get_service);

$ENV{SHM_TEST} = 1;
my $owner = SHM->new(user_id => 40092);
$owner->set(balance => 0, bonus => 0, credit => 0, can_overdraft => 0);
my $plan = get_service('service')->add(name => 'edit pending', category => 'ledger',
    cost => 30, no_discount => 1, config => {remnawave => {traffic_limit_bytes => 100}});
my $us = create_service(service_id => $plan->id);
my $draft = $us->withdraw;
ok($draft->unpaid && !$draft->get_usage, 'administrative editor has an unpaid draft');
$draft->dbh->do(q{UPDATE withdraw_history SET withdraw_date=NOW(), `usage`=JSON_OBJECT('limit_bytes',100)
                  WHERE withdraw_id=?}, undef, $draft->id);
$draft->api_set(user_service_id => $us->id, service_id => $plan->id, cost => 1);
is(get_service('report')->status, 409, 'newly paid bill is protected');
is(0+$draft->reload->{cost}, 30, 'correction preserved the frozen price');
done_testing;
