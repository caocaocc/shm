use v5.14;
use Test::More;
use Test::MockTime;
use Core::Billing;
use Core::Const;
use Core::System::ServiceManager qw(get_service);
use SHM;

$ENV{SHM_TEST} = 1;
my $user = SHM->new(user_id => 40092);
my $opening = {bytes => 40, reset_at => undef};
my $sample = $opening;
my $reads = 0;
no warnings 'redefine';
local *Core::Billing::reading = sub { ++$reads; return $sample };

sub buy_plan {
    my %args = @_;
    my $service = get_service('service')->add(
        name => 'traffic test', category => 'traffic-test', no_discount => 1,
        cost => 80, period => 1, config => {remnawave => {traffic_limit_bytes => 100}}, %args,
    );
    return create_service(service_id => $service->id);
}

for my $billing (qw(Honest Simpler)) {
    subtest "$billing: measured refund on original paid amount" => sub {
        local *Core::USObject::billing = sub { $billing };
        Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
        $user->set(balance => 60, bonus => 20, credit => 0, can_overdraft => 0);
        $sample = $opening;
        my $us = buy_plan();
        my $wd = $us->withdraw;
        ok($wd->paid, 'paid with cash and permitted bonus');
        is($wd->get_usage->{start_bytes}, 40, 'opening counter from same reset window');
        is($wd->get_usage->{limit_bytes}, 100, 'purchased quota');
        $us->service->set(config => {remnawave => {traffic_limit_bytes => 200}});
        Test::MockTime::set_fixed_time('2022-01-03T00:00:00Z');
        $sample = {bytes => 100, reset_at => undef};
        ok($us->finish, 'finish service');
        is($wd->get_usage->{used_bytes}, 60, 'previous bill readings excluded');
        is($wd->get_usage->{limit_bytes}, 100, 'price and quota frozen per paid bill');
        is($wd->get_total + $wd->get_bonus, 48, '60% of the original 80 retained');
        is($user->get_balance + $user->get_bonus, 32, 'refund stays within original payment');
        is($user->get_balance, 24, 'original cash share of the refund');
        is($user->get_bonus, 8, 'original bonus share of the refund');
        is($wd->get_end_date, $us->get_expire, 'real date of termination');
        $us->money_back;
        is($user->get_balance + $user->get_bonus, 32, 'closed withdraw cannot refund twice');
    };
}

subtest 'target plan determines credit and partial-period eligibility' => sub {
    $user->set(balance => 1, bonus => 2, credit => 500, can_overdraft => 1);
    my $us = buy_plan(pay_in_credit => 1, config => {
        remnawave => {traffic_limit_bytes => 100}, allow_partial_period => 1,
    });
    ok($us->withdraw->unpaid, 'positive quota forbids overdraft and credit');
    is($us->withdraw->get_months, 1, 'no fractional period');
    my $ordinary = get_service('service')->add(name => 'ordinary', cost => 80, category => 'traffic-test');
    ok(Core::Billing::calc_payment($us, 80, $ordinary), 'ordinary target still accepts credit');
    ok(!Core::Billing::calc_payment($us, 80, $us->service), 'traffic target requires full funds');
    my %wd = (total => 80, months => 1);
    Core::Billing::apply_partial_period($us, \%wd, 1, $us->service);
    is_deeply(\%wd, {total => 80, months => 1}, 'partial period override ignored for traffic plan');
};

subtest 'unavailable read preserves service, tariff, old bill and balance' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 100, bonus => 0);
    $sample = $opening;
    my $us = buy_plan();
    my $wd = $us->withdraw;
    my $expire = $us->get_expire;
    my $next = get_service('service')->add(name => 'next', category => 'traffic-test', cost => 10);
    $sample = undef;
    Test::MockTime::set_fixed_time('2022-01-05T00:00:00Z');
    ok(!$us->change(service_id => $next->id, skip_check_allow_to_order => 1), 'immediate change refused');
    ok(!$us->delete_force, 'removal refused');
    is(get_service('report')->status, 503, 'temporary reader failure exposes the retryable HTTP status');
    is($us->get_expire, $expire, 'expiry intact');
    is($us->get_next, 0, 'no pending switch');
    is($us->get_status, STATUS_ACTIVE, 'service stays active');
    is($us->get_withdraw_id, $wd->id, 'same bill');
    ok(!exists $wd->get_usage->{used_bytes}, 'closing can retry');
    is($user->get_balance, 20, 'nothing credited');
    get_service('report')->errors;
    get_service('report')->{status} = undef;
    $sample = {bytes => 8, reset_at => '2022-01-04T00:00:00.000Z'};
    ok($us->change(service_id => $next->id, skip_check_allow_to_order => 1), 'switch succeeds after recovery');
    is($wd->get_usage->{used_bytes}, 8, 'mid-period reset gifts preceding traffic');
    is($us->get_service_id, $next->id, 'target plan applied');
    ok(!$us->withdraw->get_usage, 'ordinary target did not inherit meter');
};

subtest 'switching a manually blocked but paid service' => sub {
    for my $initial (80, 300) {
        Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
        $user->set(balance => $initial, bonus => 0, credit => 0, can_overdraft => 0);
        $sample = $opening;
        my $us = buy_plan();
        my $old = $us->withdraw;
        $us->block_force;
        is($us->get_status, STATUS_BLOCK, 'manually blocked during paid term');
        my $next = get_service('service')->add(name => 'next', category => 'traffic-test', cost => 100,
            config => {remnawave => {traffic_limit_bytes => 200}});
        Test::MockTime::set_fixed_time('2022-01-03T00:00:00Z');
        $sample = {bytes => 100, reset_at => undef};
        ok($us->change(service_id => $next->id, skip_check_allow_to_order => 1), 'request processed');
        is($old->get_usage->{used_bytes}, 60, 'old bill settled');
        is($us->withdraw->paid, $initial == 80 ? 0 : 1, 'funds checked immediately for target');
        is($us->get_status, $initial == 80 ? STATUS_BLOCK : STATUS_ACTIVE, 'only paid target activated');
    }
};

subtest 'natural expiry records usage, even on unpaid renewal' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 80, bonus => 0, credit => 0, can_overdraft => 0);
    $sample = $opening;
    my $us = buy_plan();
    my $old = $us->withdraw;
    Test::MockTime::set_fixed_time('2022-02-06T00:00:00Z');
    $sample = undef;
    $us->touch;
    is($us->get_status, STATUS_BLOCK, 'insufficient funds follows ordinary block');
    ok(exists $old->get_usage->{used_bytes} && !defined $old->get_usage->{used_bytes}, 'unknown final reading');
    isnt($us->get_withdraw_id, $old->id, 'new unpaid bill');
    ok(!$us->withdraw->get_usage, 'unpaid bill has no usage');
    is($old->get_total, 80, 'full period retained');
};

subtest 'a mixed composite checks its paid children before charging the ordinary root' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 1, bonus => 100, credit => 1000, can_overdraft => 1);
    $sample = $opening;
    my $child_plan = get_service('service')->add(name => 'child', category => 'traffic-test',
        pay_always => 1, cost => 80, no_discount => 1,
        config => {limit_bonus_percent => 0, remnawave => {traffic_limit_bytes => 100}});
    my $us = buy_plan(cost => 10, pay_in_credit => 1, is_composite => 1,
        config => {allow_partial_period => 1}, children => [{service_id => $child_plan->id}]);
    my ($child) = @{$us->children};
    ok($us->withdraw->unpaid && $child->withdraw->unpaid, 'both remain unpaid');
    is($user->get_balance, 1, 'cash unchanged');
    is($user->get_bonus, 100, 'ordinary root did not consume bonus');
    $user->set(balance => 80);
    $us->touch;
    ok($us->withdraw->paid && $child->withdraw->paid, 'both paid when child can be covered');
    is($user->get_balance, 0, 'cash used for child');
    is($user->get_bonus, 90, 'eligible bonus used for root');
};

subtest 'one read closes and opens contiguous periods' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 600, bonus => 0);
    $sample = $opening;
    my $us = buy_plan();
    my $old = $us->withdraw;
    Test::MockTime::set_fixed_time('2022-02-06T00:00:00Z');
    $reads = 0;
    $sample = {bytes => 65, reset_at => undef};
    $us->touch;
    is($reads, 1, 'single panel reading');
    is($old->get_usage->{used_bytes}, 25, 'old bill closed before replacement');
    is($us->withdraw->get_usage->{start_bytes}, 65, 'next bill opens from same measurement');
    ok(!exists $us->withdraw->get_usage->{used_bytes}, 'new period open');
};

subtest 'a confirmed reset recovers a missing opening counter' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 500, bonus => 0);
    $sample = $opening;
    my $us = buy_plan();
    Test::MockTime::set_fixed_time('2022-02-06T00:00:00Z');
    $sample = undef;
    $us->touch;
    my $wd = $us->withdraw;
    ok($wd->paid && !defined $wd->get_usage->{start_bytes}, 'next period opened without a counter');
    Test::MockTime::set_fixed_time('2022-02-09T00:00:00Z');
    $sample = {bytes => 21, reset_at => '2022-01-15T00:00:00.000Z'};
    ok(!$us->finish, 'older reset cannot recover this bill');
    $sample = {bytes => 21, reset_at => '2022-02-07T00:00:00.000Z'};
    ok($us->finish, 'reset after opening establishes billable usage');
    is($wd->get_usage->{used_bytes}, 21, 'only post-reset traffic billed');
};

subtest 'refund flags, time floor and paid amount cap' => sub {
    for my $case (
        ['time dominates', {}, {bytes => 40, reset_at => undef}, undef],
        ['usage above quota', {}, {bytes => 400, reset_at => undef}, 0],
        ['refund forbidden', {no_money_back => 1}, undef, 0],
        ['full return', {allow_return_full_wd => 1}, undef, 80],
    ) {
        my ($name, $options, $ending, $expected) = @$case;
        Test::MockTime::set_fixed_time('2022-04-01T00:00:00Z');
        $user->set(balance => 80, bonus => 0);
        $sample = $opening;
        my $us = buy_plan(config => {%$options, remnawave => {traffic_limit_bytes => 100}});
        my $wd = $us->withdraw;
        Test::MockTime::set_fixed_time('2022-04-16T00:00:00Z');
        $sample = $ending;
        ok($us->finish, "$name settles");
        if (defined $expected) {
            is($user->get_balance, $expected, "$name refund");
        } else {
            cmp_ok(abs($user->get_balance - 40), '<', 1, 'half period billed with no traffic');
        }
        ok(exists $wd->get_usage->{used_bytes}, "$name recorded");
    }
};

subtest 'partial monetary writes roll back on error' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 100, bonus => 0);
    $sample = $opening;
    my $us = buy_plan();
    my $wd = $us->withdraw;
    my $expire = $us->get_expire;
    Test::MockTime::set_fixed_time('2022-01-03T00:00:00Z');
    my $original = \&Core::User::set_balance;
    {
        local *Core::User::set_balance = sub { $original->(@_); die "injected after balance update" };
        ok(!eval { $us->finish; 1 }, 'settlement interrupted after balance update');
    }
    $us->reload;
    $wd->reload;
    $user->reload;
    is($us->get_expire, $expire, 'original expiry');
    is($user->get_balance, 20, 'no partial refund');
    is($wd->get_total, 80, 'original price retained');
    ok(!exists $wd->get_usage->{used_bytes}, 'usage can be settled on retry');
    ok($us->finish, 'fresh retry succeeds');
};

subtest 'an unavailable child prevents partial removal' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 600, bonus => 0);
    $sample = $opening;
    my $child_plan = get_service('service')->add(
        name => 'child', category => 'traffic-test', pay_always => 1, cost => 10,
        config => {remnawave => {traffic_limit_bytes => 100}},
    );
    my $us = buy_plan(children => [{service_id => $child_plan->id}]);
    my ($child) = @{$us->children};
    my $balance = $user->get_balance;
    my $expire = $us->get_expire;
    Test::MockTime::set_fixed_time('2022-01-03T00:00:00Z');
    local *Core::Billing::reading = sub { $_[0]->id == $child->id ? undef : $opening };
    ok(!$us->delete_force, 'tree removal can be retried');
    is($user->get_balance, $balance, 'no partial refund');
    is($us->get_expire, $expire, 'parent not shortened');
    is($us->get_status, STATUS_ACTIVE, 'parent active');
    is($child->get_status, STATUS_ACTIVE, 'child active');
};

subtest 'one cent of combined payment and original wallet shares' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 0.01, bonus => 0.01, credit => 0, can_overdraft => 0);
    $sample = $opening;
    my $us = buy_plan(cost => 0.02);
    my $bill = $us->withdraw;
    $sample = {bytes => 90, reset_at => undef};
    ok($us->finish, 'close half-consumed bill');
    is($bill->get_total + $bill->get_bonus, 0.01, 'round combined retained amount once');
    is($user->get_balance + $user->get_bonus, 0.01, 'one cent returned');
};

subtest 'fully discounted measured bill can close offline' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 10, bonus => 0, discount => 100);
    $sample = $opening;
    my $us = buy_plan(cost => 80, no_discount => 0);
    my $bill = $us->withdraw;
    ok($bill->paid && $bill->get_total + $bill->get_bonus == 0, '100 percent discount paid the whole bill');
    $sample = undef;
    $reads = 0;
    ok($us->finish, 'no paid money needs a traffic-based refund');
    is($reads, 0, 'zero paid amount can close without contacting panel');
    $user->set(discount => 0);
};

subtest 'payment retries lock and refresh their already cached withdraw' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 0, bonus => 0, credit => 0, can_overdraft => 0);
    $sample = $opening;
    my $us = buy_plan();
    my $bill = $us->withdraw;
    ok($bill->unpaid, 'the retry worker cached an unpaid record');
    $user->set(balance => 100);
    # Simulate another worker having paid this same withdrawal before our lock was acquired.
    $us->dbh->do(q{UPDATE withdraw_history SET withdraw_date=NOW(),
        `usage`=JSON_OBJECT('limit_bytes',100,'start_bytes',40) WHERE withdraw_id=?}, undef, $bill->id);
    ok(Core::Billing::is_pay($us), 'worker recognizes payment already posted');
    is($user->get_balance, 100, 'stale worker never charges the same bill twice');
};

subtest 'mixed package renewal includes the expired paid child and each individual bonus cap' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 10, bonus => 80, credit => 0, can_overdraft => 0);
    $sample = $opening;
    my $child_plan = get_service('service')->add(
        name => 'charged child', category => 'traffic-test', cost => 80, no_discount => 1, pay_always => 1,
        config => {remnawave => {traffic_limit_bytes => 100}},
    );
    my $us = buy_plan(cost => 10, is_composite => 1, config => {limit_bonus_percent => 0},
        children => [{service_id => $child_plan->id}]);
    my ($child) = @{$us->children};
    ok($us->withdraw->paid && $child->withdraw->paid, 'cash for root, all bonus for eligible child');
    $user->set(balance => 10, bonus => 0, credit => 500, can_overdraft => 1);
    Test::MockTime::set_fixed_time('2022-02-06T00:00:00Z');
    $us->touch;
    is($user->get_balance, 10, 'insufficient funds for paid-but-expired child preserve root cash');
    ok($us->withdraw->unpaid, 'root stays unpaid until whole renewal is funded');
};

subtest 'ordinary sibling in a measured package cannot use overdraft' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 10, bonus => 0, credit => 100, can_overdraft => 1);
    my $child_plan = get_service('service')->add(
        name => 'ordinary paid child', category => 'traffic-test', cost => 80, no_discount => 1, pay_always => 1,
    );
    my $us = buy_plan(cost => 10, is_composite => 1, children => [{service_id => $child_plan->id}]);
    ok($us->withdraw->unpaid, 'ordinary charge included after metered root');
    is($user->get_balance, 10, 'no partial root or child debit');
};

subtest 'partial package debit rolls back including cached parent bill' => sub {
    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');
    $user->set(balance => 0, bonus => 0, credit => 0, can_overdraft => 0);
    my $child_plan = get_service('service')->add(
        name => 'metered paid child', category => 'traffic-test', pay_always => 1, no_discount => 1,
        cost => 80, config => {remnawave => {traffic_limit_bytes => 100}},
    );
    my $us = buy_plan(cost => 10, is_composite => 1, config => {}, children => [{service_id => $child_plan->id}]);
    my $old = $us->withdraw;
    $user->set(balance => 100);
    {
        my $set_balance = \&Core::User::set_balance;
        local *Core::User::set_balance = sub {
            my ($account, %args) = @_;
            $set_balance->(@_);
            die "injected child write failure" if $args{balance} == -80;
        };
        ok(!eval { $us->touch; 1 }, 'exception after charging child');
    }
    ok($old->unpaid, 'same cached parent bill is unpaid after rollback');
    is($user->get_balance, 100, 'both debits rolled back');
    ok($us->touch, 'retry succeeds');
    is($user->get_balance, 10, 'one successful payment for all items');
};

done_testing;
