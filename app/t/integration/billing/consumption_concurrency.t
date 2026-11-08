use v5.14;
use strict;
use warnings;
use Test::More;
use Test::MockTime;
use POSIX qw(tzset _exit);
use SHM;
use Core::Billing;
use Core::Sql::Data;
use Core::Utils qw(now switch_user encode_json decode_json);
use Core::System::ServiceManager qw(get_service);

$ENV{SHM_TEST} = 1;
$ENV{TZ} = 'UTC'; tzset();
my $admin = SHM->new(user_id => 1);
my $dbh = $admin->dbh;
$dbh->{RaiseError} = 1;
my ($user_id, $service_id, $is_child);
my @outputs;

sub cleanup {
    return if $is_child || !$user_id;
    eval {
        $dbh->rollback;
        $dbh->do('DELETE r FROM consumption_readings r JOIN consumption_periods p ON p.id=r.period_id WHERE p.user_id=?', undef, $user_id);
        $dbh->do('DELETE g FROM consumption_generations g JOIN consumption_periods p ON p.id=g.period_id WHERE p.user_id=?', undef, $user_id);
        $dbh->do('DELETE FROM consumption_periods WHERE user_id=?', undef, $user_id);
        $dbh->do("DELETE FROM $_ WHERE user_id=?", undef, $user_id) for qw(spool spool_history withdraw_history pays_history bonus_history user_services);
        $dbh->do('DELETE FROM users WHERE user_id=?', undef, $user_id);
        $dbh->do('DELETE FROM services WHERE service_id=?', undef, $service_id) if $service_id;
        $dbh->commit;
    };
    unlink @outputs;
}
END { cleanup() }

Test::MockTime::set_fixed_time('2026-01-01T00:00:00Z');
$dbh->do('INSERT INTO users (login,balance,credit,bonus,settings) VALUES (?,0,0,0,?)', undef, 'consumption-concurrent-' . $$, '{}');
$user_id = $dbh->{mysql_insertid};
switch_user($user_id);
my $user = get_service('user', _id => $user_id);
$user->payment(money => 200, uniq_key => 'consumption-concurrent-' . $$);
my $service = get_service('service')->add(name => 'Consumption concurrency', cost => 30, period => 1, category => 'cc-' . $$,
    no_discount => 1, config => {consumption => {mode => 'PREPAID', quotas => {traffic => '100'}}});
$service_id = $service->id;
my $us = create_service(service_id => $service_id);
my $controller = get_service('Consumption');
my %binding = (user_service_id => $us->id, withdraw_id => $us->get_withdraw_id, meter => 'traffic', generation => 'first');
$controller->admin_start_generation(%binding, record_id => 'base', baseline => '0') or die 'baseline failed';
Test::MockTime::set_fixed_time('2026-01-11T00:00:00Z');
$controller->admin_ingest(%binding, record_id => 'first', cumulative => '50') or die 'reading failed';
$dbh->commit; # Only this test's isolated fixture becomes visible to child DB connections.

sub concurrent {
    my ($name, $operation) = @_;
    my @children;
    for my $number (1, 2) {
        my $output = "/tmp/shm-consumption-$$-$name-$number.json";
        push @outputs, $output;
        my $pid = fork();
        die 'fork failed' unless defined $pid;
        if (!$pid) {
            $is_child = 1;
            $dbh->{InactiveDestroy} = 1;
            my $child_dbh = Core::Sql::Data::db_connect(%{get_service('config')->file->{config}{database}});
            get_service('config')->local('dbh', $child_dbh);
            $child_dbh->{RaiseError} = 1;
            my $result;
            my $ok = eval { $result = $operation->(); $child_dbh->commit; 1 };
            $result = { error => "$@" } unless $ok;
            open my $file, '>', $output or _exit(2);
            print $file encode_json($result);
            close $file;
            _exit($ok ? 0 : 1);
        }
        push @children, [$pid, $output];
    }
    my @results;
    for my $child (@children) {
        waitpid($child->[0], 0);
        is($? >> 8, 0, "$name worker completed");
        open my $file, '<', $child->[1] or die $!;
        push @results, decode_json(do { local $/; <$file> });
        close $file;
    }
    return @results;
}

my @reads = concurrent('ingest', sub {
    return $controller->admin_ingest(%binding, record_id => 'shared', cumulative => '60');
});
is_deeply([sort map { $_->{duplicate} } @reads], [0, 1], 'concurrent same record inserted once');
is($dbh->selectrow_array('SELECT COUNT(*) FROM consumption_readings WHERE record_id=? AND period_id=(SELECT id FROM consumption_periods WHERE withdraw_id=?)', undef, 'shared', $us->get_withdraw_id), 1, 'database unique reading persisted once');
is($controller->snapshot_for_api(user_service_id => $us->id)->{totals}{traffic}, '60', 'concurrent reports do not duplicate usage');
$controller->admin_finalize(user_service_id => $us->id, withdraw_id => $us->get_withdraw_id, cutoff => now) or die 'finalization failed';
$dbh->commit;

my @refunds = concurrent('refund', sub {
    my ($cash, $bonus) = money_back($us, now);
    return {cash => "$cash", bonus => "$bonus"};
});
is_deeply([sort map { 0 + $_->{cash} } @refunds], [0, 12], 'concurrent refunds credit original unused value once');
$user->reload;
is($user->get_balance, 182, 'wallet has one 12-unit refund');
is($dbh->selectrow_array('SELECT refunded_cash FROM consumption_periods WHERE withdraw_id=?', undef, $us->get_withdraw_id), '12.00', 'durable refund guard agrees with wallet');

# Two independent sessions must not spend the same cached wallet balance.
$user->set(balance => 30, credit => 1000, can_overdraft => 1);
$service->set(pay_in_credit => 1);
$dbh->commit;
my @purchases = concurrent('purchase', sub {
    my $order = create_service(service_id => $service_id);
    return {status => $order->get_status, withdraw_id => $order->get_withdraw_id};
});
is_deeply([sort map { $_->{status} } @purchases], ['ACTIVE', 'NOT PAID'], 'only one of two prepaid purchases is paid');
$user->reload;
is($user->get_balance, 0, 'concurrent prepaid purchases cannot overdraw wallet');

$user->set(balance => 30);
my $pending = create_service(service_id => $service_id, auto_bill => 0);
$dbh->commit;
my @same_bill = concurrent('samebill', sub {
    my $paid = Core::Billing::is_pay($pending);
    Core::Billing::set_service_expire($pending) if $paid;
    return {paid => $paid ? 1 : 0};
});
is_deeply([map { $_->{paid} } @same_bill], [1, 1], 'same-bill payment retry recognizes prior success');
$user->reload;
is($user->get_balance, 0, 'same bill debited only once across independent sessions');
$pending->reload;
my $frozen_end = $controller->period_for($pending)->{ends_at};
Test::MockTime::set_fixed_time('2026-01-11T00:01:00Z');
Core::Billing::set_service_expire($pending);
is($pending->get_expire, $frozen_end, 'later payment replay cannot advance frozen expiration');
cleanup();
done_testing;
