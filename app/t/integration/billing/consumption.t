use v5.14;
use strict;
use warnings;
use Test::More;
use Test::MockTime;
use POSIX qw(tzset);
use SHM;
use Core::Billing;
use Core::Billing::Consumption qw(epoch);
use Core::Const;
use Core::Utils qw(now switch_user utime_to_string);
use Core::System::ServiceManager qw(get_service);

$ENV{SHM_TEST} = 1;
$ENV{TZ} = 'UTC'; tzset();
my $admin = SHM->new(user_id => 1);
my $dbh = $admin->dbh;
$dbh->{RaiseError} = 1;

# DDL runs before transactional test data. Never reset the shared test database.
open my $schema, '<', '/app/sql/shm/shm_consumption.sql' or die $!;
my $ddl = do { local $/; <$schema> };
for my $statement ($ddl =~ /(CREATE TABLE.*?;)/sg) { $dbh->do($statement) }
END { eval { $dbh->rollback if $dbh } }

Test::MockTime::set_fixed_time('2026-01-01T00:00:00Z');
get_service('config', _id => 'billing')->set_value({type => 'Simpler', currency => 'CNY'});

sub new_user {
    $dbh->do('INSERT INTO users (login,balance,credit,bonus,settings) VALUES (?,0,0,0,?)', undef, 'consumption-' . $$ . '-' . rand(), '{}');
    my $id = $dbh->{mysql_insertid};
    switch_user($id);
    my $user = get_service('user', _id => $id);
    $user->payment(money => 200, uniq_key => 'consumption-' . $$ . '-' . $id);
    return $user;
}

my $user = new_user();
my $service = get_service('service')->add(name => 'Consumption integration', cost => '30.00', period => 1,
    category => 'con-' . $$, no_discount => 1,
    config => {consumption => {mode => 'PREPAID', quotas => {traffic => {limit => '100', unit => 'unit'}}}});
my $us = create_service(service_id => $service->id);
my $controller = get_service('Consumption');
my $withdraw = $us->get_withdraw_id;
my %binding = (user_service_id => $us->id, withdraw_id => $withdraw, meter => 'traffic', generation => 'first');
is($us->get_status, STATUS_ACTIVE, 'paid package active');
is($user->get_balance, 170, 'full prepaid price charged once');
my $snapshot = $controller->snapshot_for_api(user_service_id => $us->id);
ok($snapshot->{enabled}, 'paid withdrawal automatically creates frozen period');
is($snapshot->{paid_cash}, '30.00', 'price frozen from withdrawal');
is($snapshot->{currency}, 'CNY', 'currency frozen');
is($snapshot->{refundable_cash}, '30.00', 'initial prepaid value refundable');
is($snapshot->{refund_ready}, 0, 'missing meter baseline cannot authorize a refund');
my $original_expire = $us->get_expire;
is($us->finish, undef, 'finish refuses refund without trusted final readings');
is(get_service('report')->status, 409, 'missing meter refund reports conflict');
get_service('report')->errors;
is($us->get_expire, $original_expire, 'failed finish restores cached expiration');
is($dbh->selectrow_array('SELECT expire FROM user_services WHERE user_service_id=?', undef, $us->id), $original_expire, 'failed finish restores SQL expiration');
is($user->get_balance, 170, 'failed refund cannot alter wallet');

my $begin = $controller->admin_start_generation(%binding, record_id => 'begin', baseline => '1000');
ok($begin, 'explicit lifetime baseline accepted');
is($begin->{totals}{traffic}, '0', 'baseline is not counted as this period usage');
Test::MockTime::set_fixed_time('2026-01-11T00:00:00Z');
my $reading = $controller->admin_ingest(%binding, record_id => 'r1', cumulative => '1050');
is($reading->{consumed}, '15.00', '10 days / 50 units valued at 15');
is($user->get_balance, 170, 'metering does not charge prepaid wallet again');
my $repeat = $controller->admin_ingest(%binding, record_id => 'r1', cumulative => '1050');
is($repeat->{duplicate}, 1, 'exact replay is idempotent');
is($dbh->selectrow_array('SELECT COUNT(*) FROM consumption_readings WHERE period_id=?', undef, $snapshot->{period_id}), 2, 'only baseline and one reading persisted');

sub rejected {
    my ($status, $label, $code) = @_;
    is($code->(), undef, $label);
    is(get_service('report')->status, $status, 'error status');
    get_service('report')->errors;
}
rejected(409, 'counter rollback rejected', sub { $controller->admin_ingest(%binding, record_id => 'backwards', cumulative => '1049') });
rejected(409, 'conflicting replay rejected', sub { $controller->admin_ingest(%binding, record_id => 'r1', cumulative => '1060') });
rejected(400, 'negative reading rejected', sub { $controller->admin_ingest(%binding, record_id => 'negative', cumulative => '-1') });
is($controller->snapshot_for_api(user_service_id => $us->id)->{totals}{traffic}, '50', 'rejected readings cannot alter totals');

my %second = (%binding, generation => 'second');
ok($controller->admin_start_generation(%second, record_id => 'begin2', baseline => '2000'), 'reset has a new explicit baseline');
rejected(409, 'old generation cannot report after reset', sub { $controller->admin_ingest(%binding, record_id => 'oldgen', cumulative => '1070') });
Test::MockTime::set_fixed_time('2026-01-21T00:00:00Z');
$reading = $controller->admin_ingest(%second, record_id => 'r2', cumulative => '2010');
is($reading->{totals}{traffic}, '60', 'generation contributions accumulated');
is($reading->{consumed}, '20.00', '20 days / 60 units valued at 20');
is($user->get_balance, 170, 'still only charged the prepaid price');

$service->set(cost => 999, config => {consumption => {mode => 'PREPAID', quotas => {traffic => '1000'}}});
get_service('config', _id => 'billing')->set_value({currency => 'USD'});
$snapshot = $controller->snapshot_for_api(user_service_id => $us->id);
is($snapshot->{currency}, 'CNY', 'live currency change does not rewrite paid period');
is($snapshot->{quotas}{traffic}{limit}, '100', 'live quota change does not rewrite paid period');
is($snapshot->{consumed}, '20.00', 'live price change does not rewrite valuation');
rejected(409, 'currency mismatch refuses refund', sub { $us->finish });
is($user->get_balance, 170, 'currency mismatch cannot alter wallet');
is($us->withdraw->get_total, '30', 'currency mismatch cannot alter withdrawal');
get_service('config', _id => 'billing')->set_value({currency => 'CNY'});
my $cutoff = now;
ok($controller->admin_finalize(user_service_id => $us->id, withdraw_id => $withdraw, cutoff => $cutoff), 'trusted final readings fix cutoff');
is($controller->admin_finalize(user_service_id => $us->id, withdraw_id => $withdraw, cutoff => $cutoff)->{duplicate}, 1, 'finalization replay is idempotent');
rejected(409, 'different finalization cutoff rejected', sub { $controller->admin_finalize(user_service_id => $us->id, withdraw_id => $withdraw, cutoff => '2026-01-20 00:00:00') });
rejected(409, 'finalized period refuses later meter data', sub { $controller->admin_ingest(%second, record_id => 'after-final', cumulative => '2020') });
Test::MockTime::set_fixed_time('2026-01-21T00:00:05Z');
ok($us->finish, 'finish succeeds several seconds after finalization');
my $refunded_period = $controller->period_for($us);
my ($cash, $bonus) = @{$refunded_period}{qw(refunded_cash refunded_bonus)};
is($cash, '10.00', 'refund retains greater ratio of original prepaid price');
is($bonus, '0.00', 'no bonus refund for cash-only payment');
is($user->get_balance, 180, 'refund credited once');
is_deeply([money_back($us, now)], [0, 0], 'refund replay returns no new credit');
is($user->get_balance, 180, 'refund replay cannot increase wallet');
rejected(409, 'closed/refunded period rejects new reports', sub { $controller->admin_ingest(%second, record_id => 'late', cumulative => '2090') });
is($controller->snapshot_for_api(user_service_id => $us->id)->{refundable_cash}, '0.00', 'closed snapshot has no available refund');
is($us->get_expire, $cutoff, 'fixed finalization cutoff is retained on service');
rejected(409, 'frozen withdrawal API editing rejected', sub { $us->withdraw->api_set(user_service_id => $us->id, service_id => $service->id, cost => 1) });
rejected(409, 'frozen withdrawal deletion rejected', sub { $us->withdraw->delete });

# Restore tariff for another period; a late old-period binding cannot affect it.
$service->set(cost => 30, config => {consumption => {mode => 'PREPAID', quotas => {traffic => '100'}}});
Test::MockTime::set_fixed_time('2026-01-26T00:00:00Z');
$us->touch;
ok($us->get_withdraw_id != $withdraw, 'renewal uses a new paid withdrawal');
my $new_snapshot = $controller->snapshot_for_api(user_service_id => $us->id);
ok($new_snapshot->{period_id} != $snapshot->{period_id}, 'renewal freezes a new period');
is($new_snapshot->{starts_epoch}, epoch(now), 'delayed renewal begins at new payment time');
is($new_snapshot->{ends_epoch} - $new_snapshot->{starts_epoch}, 30 * 86400, 'delayed renewal grants the complete purchased term');
rejected(409, 'late report remains bound to closed old period', sub { $controller->admin_ingest(%second, record_id => 'late2', cumulative => '2100') });
is($controller->snapshot_for_api(user_service_id => $us->id)->{totals}{traffic}, '0', 'new period retains zero usage');

# Changing tariffs several days after an early final cutoff also purchases a
# complete new term; it must not inherit the settled service's old expiry.
my $changing = create_service(service_id => $service->id);
my $changing_wd = $changing->get_withdraw_id;
$controller->admin_start_generation(user_service_id => $changing->id, withdraw_id => $changing_wd, meter => 'traffic', generation => 'change', record_id => 'base', baseline => '0');
Test::MockTime::set_fixed_time('2026-01-28T00:00:00Z');
$controller->admin_ingest(user_service_id => $changing->id, withdraw_id => $changing_wd, meter => 'traffic', generation => 'change', record_id => 'final', cumulative => '0');
$controller->admin_finalize(user_service_id => $changing->id, withdraw_id => $changing_wd, cutoff => now);
my $change_target = get_service('service')->add(name => 'Consumption change full period', cost => 12, period => 2,
    category => 'change-con-' . $$, no_discount => 1,
    config => {consumption => {mode => 'PREPAID', quotas => {traffic => '200'}}});
Test::MockTime::set_fixed_time('2026-02-02T00:00:00Z');
ok($changing->change(service_id => $change_target->id), 'delayed tariff change settles old period and buys new package');
my $changed_snapshot = $controller->snapshot_for_api(user_service_id => $changing->id);
is($changing->get_service_id, $change_target->id, 'new tariff activated');
is($changed_snapshot->{starts_epoch}, epoch(now), 'delayed tariff change begins at payment time');
is($changed_snapshot->{ends_epoch} - $changed_snapshot->{starts_epoch}, 60 * 86400, 'delayed tariff change grants complete new tariff period');

my $other = new_user();
get_service('config')->local('authenticated_user_id', $other->id);
rejected(403, 'snapshot refuses another user despite supplied admin flag', sub { $controller->snapshot_for_api(user_service_id => $us->id, admin => 1) });
rejected(403, 'user cannot write meter data', sub { $controller->admin_ingest(%second, record_id => 'forged', cumulative => '2100') });
get_service('config')->local('authenticated_user_id', 1);
switch_user($user->id);

get_service('Events')->add(name => 'CONSUMPTION_EXHAUSTED', title => 'Consumption exhaustion test', kind => 'UserService',
    settings => {category => 'con-' . $$});
my %current = (user_service_id => $us->id, withdraw_id => $us->get_withdraw_id, meter => 'traffic', generation => 'current');
ok($controller->admin_start_generation(%current, record_id => 'begin', baseline => '0'), 'current period baseline');
my $balance_before_meter = $user->get_balance;
is($controller->admin_ingest(%current, record_id => 'exhaust', cumulative => '100')->{exhausted}, 1, 'quota exhaustion exposed');
is($us->get_status, STATUS_ACTIVE, 'quota exhaustion does not break time-based billing status');
is($user->get_balance, $balance_before_meter, 'quota exhaustion does not debit again');
$controller->admin_ingest(%current, record_id => 'exhaust2', cumulative => '110');
my $queued = $dbh->selectrow_array(q{SELECT COUNT(*) FROM spool WHERE JSON_UNQUOTE(JSON_EXTRACT(event,'$.name'))='CONSUMPTION_EXHAUSTED' AND user_service_id=?}, undef, $us->id);
is($queued, 1, 'exhaustion event enqueued once');

my $legacy = get_service('service')->add(name => 'Legacy consumption compatibility', cost => 1, period => 1, category => 'legacy-con');
my $legacy_us = create_service(service_id => $legacy->id);
is($controller->snapshot_for_api(user_service_id => $legacy_us->id)->{enabled}, 0, 'legacy tariff is not opted in');
is($dbh->selectrow_array('SELECT COUNT(*) FROM consumption_periods WHERE user_service_id=?', undef, $legacy_us->id), 0, 'legacy order creates no consumption period');

# Credit and overdraft cannot grant a full consumption quota on partial cash.
$user->set(balance => 10, credit => 1000, can_overdraft => 1, bonus => 0);
$service->set(pay_in_credit => 1, config => {consumption => {mode => 'PREPAID', quotas => {traffic => '100'}}, allow_partial_period => 1});
my $unpaid = create_service(service_id => $service->id);
is($unpaid->get_status, STATUS_WAIT_FOR_PAY, 'PREPAID refuses credit/overdraft funding');
is($user->get_balance, 10, 'insufficient prepaid funds are not debited');
ok(!$unpaid->get_expire, 'unpaid quota has no active term');
is($controller->snapshot_for_api(user_service_id => $unpaid->id)->{enabled}, 0, 'unpaid order receives no consumption period');
my $manual_target = get_service('service')->add(name => 'Manual partial flag PREPAID target',
    cost => 40, period => 1, category => 'cmanual-' . $$, allow_to_order => 1,
    no_discount => 1, pay_in_credit => 1,
    config => {consumption => {mode => 'PREPAID', quotas => {traffic => '100'}}});
ok($unpaid->change(service_id => $manual_target->id, allow_partial_period => 1),
    'manual partial-period request reaches the prepaid tariff change');
is($unpaid->get_status, STATUS_WAIT_FOR_PAY, 'manual flag cannot activate an underfunded prepaid tariff');
is($unpaid->withdraw->get_total, 40, 'manual flag cannot reduce the full prepaid price');
is($unpaid->withdraw->get_months, 1, 'manual flag cannot shorten the prepaid term');
is($user->get_balance, 10, 'underfunded manual change does not debit the wallet');
is($controller->snapshot_for_api(user_service_id => $unpaid->id)->{enabled}, 0,
    'underfunded manual change does not grant a consumption quota');
$us->set(expire => now);
$us->touch;
is($us->get_status, STATUS_BLOCK, 'insufficient cash blocks full-period renewal despite credit');
is($us->withdraw->get_total, 30, 'partial-period option cannot discount a full consumption quota');
is($us->withdraw->get_months, 1, 'renewal keeps the full configured period');

$user->set(balance => 200, credit => 0, can_overdraft => 0);
my $nonrefundable = get_service('service')->add(name => 'Nonrefundable consumption', cost => 30, period => 1, category => 'cnr-' . $$,
    config => {no_money_back => 1, consumption => {mode => 'PREPAID', quotas => {traffic => '100'}}});
my $nr = create_service(service_id => $nonrefundable->id);
my $nr_wd = $nr->get_withdraw_id;
$controller->admin_start_generation(user_service_id => $nr->id, withdraw_id => $nr_wd, meter => 'traffic', generation => 'nr', record_id => 'base', baseline => '0');
$controller->admin_finalize(user_service_id => $nr->id, withdraw_id => $nr_wd, cutoff => now);
my $nr_balance = $user->get_balance;
ok($nr->finish, 'nonrefundable finalized service can finish');
ok(defined $controller->period_for($nr)->{closed_epoch}, 'nonrefundable period closes');
is($user->get_balance, $nr_balance, 'nonrefundable finish keeps full prepaid charge');
cmp_ok($nr->withdraw->get_total, '==', 30, 'nonrefundable withdrawal retains full price');
is($controller->snapshot_for_api(user_service_id => $nr->id)->{retained_cash}, '30.00', 'closed nonrefundable snapshot agrees with full retained withdrawal');
$nr->touch;
ok($nr->get_withdraw_id != $nr_wd, 'nonrefundable closed period can renew');

my $expired = create_service(service_id => $service->id);
my $expired_wd = $expired->get_withdraw_id;
my $expired_period = $controller->period_for($expired);
$controller->admin_start_generation(user_service_id => $expired->id, withdraw_id => $expired_wd, meter => 'traffic', generation => 'exp', record_id => 'base', baseline => '0');
my $boundary = utime_to_string($expired_period->{ends_epoch});
my $boundary_iso = $boundary; $boundary_iso =~ s/ /T/;
Test::MockTime::set_fixed_time($boundary_iso . 'Z');
$controller->admin_ingest(user_service_id => $expired->id, withdraw_id => $expired_wd, meter => 'traffic', generation => 'exp', record_id => 'final', cumulative => '0', observed_at => $boundary);
$controller->admin_finalize(user_service_id => $expired->id, withdraw_id => $expired_wd, cutoff => $boundary);
$expired->touch;
is($expired->get_withdraw_id, $expired_wd, 'pending finalization is not silently replaced by renewal');
my $later_iso = utime_to_string($expired_period->{ends_epoch} + 5); $later_iso =~ s/ /T/;
Test::MockTime::set_fixed_time($later_iso . 'Z');
my $expired_balance = $user->get_balance;
ok($expired->finish, 'already expired finalized period can finish');
ok(defined $controller->period_for($expired)->{closed_epoch}, 'expired finalized period closes');
is($user->get_balance, $expired_balance, 'natural full expiry has no refund');
$expired->touch;
ok($expired->get_withdraw_id != $expired_wd, 'closed natural-expiry period can renew');

my $callbacks_before = scalar @{ get_service('config')->local->{_post_commit_callbacks} || [] };
my $callback_ran = 0;
eval { $controller->atomic(sub { $controller->add_post_commit_callback(sub { $callback_ran++ }); die "rollback test\n" }) };
is(scalar @{get_service('config')->local->{_post_commit_callbacks} || []}, $callbacks_before, 'savepoint rollback removes only its own post-commit callbacks');
is($callback_ran, 0, 'rolled-back callback did not execute');

$dbh->rollback;
done_testing;
