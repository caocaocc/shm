use v5.14;
use Test::More;
use JSON::PP qw(decode_json);
use SHM;
use Core::Const;
use Core::Billing;
use Core::Billing::Traffic ();
use Core::Transport::Local ();
use Core::System::ServiceManager qw(get_service);

$ENV{SHM_TEST} = 1;
my $user = SHM->new(user_id => 40092);
$user->set(balance => 200, bonus => 0, credit => 0);
my $category = 'traffic-create';
get_service('Events')->add(
    title => 'Provision traffic account', name => EVENT_CREATE,
    settings => { category => $category, transport => 'local', server_id => 1 },
);
my $tariff = get_service('service')->add(
    name => 'traffic with provisioning', category => $category,
    cost => 80, period => 1, no_discount => 1,
    config => {remnawave => {traffic_limit_bytes => 100}},
);
my $us = create_service(service_id => $tariff->id);
my $wd = $us->withdraw;
my ($queued) = grep { $_->{event}{name} eq EVENT_CREATE }
    $us->spool->list_by_settings(user_service_id => $us->id);
is($queued->{settings}{withdraw_id}, $wd->id, 'CREATE identifies the purchased billing period');
ok($wd->paid, 'full purchase completed before account creation');
is($us->get_status, STATUS_PROGRESS, 'awaiting provisioner');

# Substitute the remote provisioner and its read result; keep the native task,
# Spool payload, server assignment, service transitions and MySQL writes.
my ($sample, @panel_reads, $deliveries);
no warnings 'redefine';
local *Core::Transport::Local::send = sub {
    ++$deliveries;
    return SUCCESS, { server => { id => 1 } };
};
local *Core::Billing::Traffic::reading = sub {
    push @panel_reads, $_[0]->settings->{server_id};
    return $sample;
};
my $run = sub { (get_service('Task')->res($queued)->make_task)[0] };
my $saved = sub {
    return decode_json($wd->dbh->selectrow_array(
        'SELECT `usage` FROM withdraw_history WHERE withdraw_id=?', undef, $wd->id));
};

is($run->(), TASK_FAIL, 'missing initial read leaves a retryable task');
is($us->get_status, STATUS_PROGRESS, 'missing read does not activate service');
is_deeply($saved->(), {limit_bytes => 100}, 'a failed reading is not recorded as zero');

# A manually adopted account already consumed 40 bytes before this purchase.
$sample = {bytes => 40, reset_at => '2026-01-01T00:00:00.000Z'};
is($run->(), TASK_SUCCESS, 'retry completes with the adopted account reading');
is_deeply(\@panel_reads, [1, 1], 'both reads used the server assigned by the provisioner');
is($us->get_status, STATUS_ACTIVE, 'service activated after storing opening');
is_deeply($saved->(), {limit_bytes => 100, start_bytes => 40, start_reset_at => $sample->{reset_at}}, 'stored opening and panel window');
is($user->get_balance, 120, 'retry did not charge again');

$sample = undef;
my $duplicate = $run->();
ok($duplicate eq TASK_SUCCESS || $duplicate eq TASK_SKIPPED, 'duplicate acknowledgment needs no fresh reading');
is(scalar @panel_reads, 2, 'duplicate never rereads a later counter as opening');

$wd->set(usage => { %{$saved->()}, used_bytes => 15 });
$us->set(status => STATUS_BLOCK);
my $before_stale = $deliveries;
$run->();
is($us->get_status, STATUS_BLOCK, 'late CREATE cannot reopen closed period');
my $replacement_id = Core::Billing::add_withdraw($us, service_id => $tariff->id, cost => 80, months => 1);
$us->set(withdraw_id => $replacement_id);
$run->();
is($us->get_status, STATUS_BLOCK, 'late CREATE cannot activate replacement bill');
is($deliveries, $before_stale, 'closed and superseded tasks have no remote side effects');
is($saved->()->{used_bytes}, 15, 'old bill intact');
ok(!$us->withdraw->get_usage, 'no counter written against unpaid replacement');

# The transport completes after another operation has already closed a term.
# Write below the object cache to exercise the database recheck on delivery.
$us->set(withdraw_id => $wd->id, status => STATUS_PROGRESS);
$wd->set(usage => {limit_bytes => 100});
{
    local *Core::Transport::Local::send = sub {
        $wd->dbh->do(q{UPDATE withdraw_history SET `usage`=JSON_OBJECT('limit_bytes',100,'used_bytes',27) WHERE withdraw_id=?}, undef, $wd->id);
        $wd->dbh->do(q{UPDATE user_services SET status='BLOCK' WHERE user_service_id=?}, undef, $us->id);
        return SUCCESS, {server => {id => 1}};
    };
    is($run->(), TASK_SKIPPED, 'late provisioning receipt is discarded');
    is($saved->()->{used_bytes}, 27, 'receipt cannot overwrite the closed measurement');
    is($us->reload->{status}, STATUS_BLOCK, 'receipt cannot revive a stopped service');
}
done_testing;
