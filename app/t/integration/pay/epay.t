use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use Core::Epay;
use Core::User;
use Core::Cloud::Currency;
use Core::System::ServiceManager qw(get_service);
use Core::Pay::Epay qw(sign_request);
use SHM ();
use POSIX ();

# Explicitly opt into the isolated DB: this test commits to exercise real ACK
# semantics. It never resets a database or modifies merchant/runtime config.
unless ($ENV{EPAY_INTEGRATION_TEST}) { plan skip_all => 'Set EPAY_INTEGRATION_TEST=1 on an isolated SHM database'; }
SHM->new(user_id => 1);
my $dbh = get_service('config')->local->{dbh};
my $user_id = 98081;
my $other_id = 98082;
my @ids;
my @owned_users;

{
    package EpayTestController;
    use parent 'Core::Epay';
    sub _actor { Core::System::ServiceManager::get_service('user', _id => $_[0]->{actor_id}, user_id => $_[0]->{actor_id}) }
    sub _billing_currency { 'CNY' }
    sub _profile { +{ %{ $_[0]->{test_profile} } } }
    sub _credentials { +{ %{ $_[2] }, md5_key => 'epay-integration-only' } }
    sub dbh { $_[0]->{test_dbh} || $_[0]->SUPER::dbh }
}
{
    package EpayCommitFailureDBH;
    our $AUTOLOAD;
    sub commit { die "测试提交失败\n" }
    sub rollback { $_[0]->{real}->rollback }
    sub DESTROY {}
    sub AUTOLOAD {
        my $self = shift;
        (my $method = $AUTOLOAD) =~ s/.*:://;
        return $self->{real}->$method(@_);
    }
}

sub cleanup {
    return unless $dbh;
    eval {
        $dbh->rollback;
        for my $id (@ids) { $dbh->do('DELETE FROM epay_orders WHERE out_trade_no = ?', undef, $id) }
        for my $uid (@owned_users) {
            $dbh->do('DELETE FROM epay_orders WHERE user_id = ?', undef, $uid);
            $dbh->do('DELETE FROM spool WHERE user_id = ?', undef, $uid);
            $dbh->do('DELETE FROM pays_history WHERE user_id = ?', undef, $uid);
            $dbh->do('DELETE FROM bonus_history WHERE user_id = ?', undef, $uid);
            $dbh->do('DELETE FROM users WHERE user_id = ?', undef, $uid);
        }
        $dbh->commit;
    };
}
END { cleanup() }

my $occupied = $dbh->selectrow_array('SELECT COUNT(*) FROM users WHERE user_id IN (?,?)', undef, $user_id, $other_id);
die 'Dedicated epay fixture user IDs already exist; refuse to delete other data' if $occupied;
for my $uid ($user_id, $other_id) {
    $dbh->do('INSERT INTO users (user_id,login,full_name,balance,credit,bonus,gid) VALUES (?,?,?,0,0,0,2)',
        undef, $uid, "epay-fixture-$uid", '易支付测试用户') or die $dbh->errstr;
    push @owned_users, $uid;
}
$dbh->commit;

my $controller = bless { actor_id => $user_id, test_profile => {
    paysystem => 'epay', show_for_client => 1, protocol => 'v1_md5', pid => '1001', key_version => 'test-v1',
    api_url => 'https://epay.example.test', notify_url => 'https://bill.example.test/notify',
    return_url => 'https://bill.example.test/return', payment_name => '账户充值', checkout => 'submit',
} }, 'EpayTestController';

# Current dev fixtures use RUB. Override only this process's generic payment
# currency lookup, without editing the shared billing config record.
no warnings 'redefine';
local *Core::User::cfg = sub {
    my ($key) = @_;
    return { currency => 'CNY' } if $key eq 'billing';
    return Core::Base::cfg($key);
};
local *Core::Cloud::Currency::system_currency = sub { 'CNY' };

my $created = $controller->create_order(amount => '12.30', ps => 'epay', user_id => $other_id);
ok($created, 'pending order created without calling a real gateway');
diag(join(' ', get_service('report')->errors)) unless $created;
die 'Cannot continue without pending order' unless $created;
push @ids, $created->{out_trade_no};
is($created->{user_id}, $user_id, 'customer cannot choose another user as order owner');
is($created->{state}, 'PENDING', 'pending persisted before checkout');
is($created->{checkout_request}->{url}, 'https://epay.example.test/submit.php', 'legacy checkout correctly generated');
my $stored = $dbh->selectrow_hashref('SELECT * FROM epay_orders WHERE out_trade_no=?', undef, $created->{out_trade_no});
unlike($stored->{profile_config}, qr/epay-integration-only/, 'order never stores signing secret');
is($controller->_frozen_profile($stored)->{payment_name}, '账户充值', 'Chinese frozen JSON round-trips correctly');

my $params = { pid => '1001', out_trade_no => $created->{out_trade_no}, trade_no => 'epay_fixture_trade_001',
    type => 'alipay', money => '12.30', trade_status => 'TRADE_SUCCESS' };
my $profile = $controller->_frozen_profile($stored);
my $notification = sign_request($params, $profile);
my $settled = eval { $controller->process_notification($notification) };
unless ($settled) {
    diag(join(' ', get_service('report')->errors));
    die $@ || 'Settlement failed';
}
is($settled->{state}, 'PAID', 'valid notification commits the payment');
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), '12.30', 'original User.payment credits balance');
is($dbh->selectrow_array('SELECT COUNT(*) FROM pays_history WHERE user_id=?', undef, $user_id), 1, 'one funds entry');
is($dbh->selectrow_array('SELECT COUNT(*) FROM spool WHERE user_id=?', undef, $user_id), 1, 'one durable PAYMENT event');

my $duplicate = $controller->process_notification($notification);
is($duplicate->{payment_id}, $settled->{payment_id}, 'duplicate returns the existing committed payment');
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), '12.30', 'duplicate does not credit twice');
is($dbh->selectrow_array('SELECT COUNT(*) FROM spool WHERE user_id=?', undef, $user_id), 1, 'duplicate does not add entitlement tasks');
my $before = $dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id);
is($controller->return_status($created->{out_trade_no})->{state}, 'PAID', 'browser return reads only local status');
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), $before, 'return does not mutate funds');

my $mismatch = sign_request({ %$params, money => '12.31' }, $profile);
ok(!eval { $controller->process_notification($mismatch); 1 }, 'even a valid signature cannot change the amount');
$controller->{actor_id} = $other_id;
ok(!$controller->status(out_trade_no => $created->{out_trade_no}), 'another user cannot inspect/reconcile an order');
get_service('report')->errors;
$controller->{actor_id} = $user_id;

my $queried = $controller->create_order(amount => '5.00', ps => 'epay');
push @ids, $queried->{out_trade_no};
$controller->{http_request} = sub {
    my ($url, $fields) = @_;
    is($url, 'https://epay.example.test/api.php', 'legacy query uses authenticated old API');
    is($fields->{out_trade_no}, $queried->{out_trade_no}, 'query bound to frozen local order');
    return { code => 1, status => 1, pid => '1001', out_trade_no => $queried->{out_trade_no},
        trade_no => 'epay_fixture_trade_002', type => 'alipay', money => '5.00' };
};
is($controller->reconcile(out_trade_no => $queried->{out_trade_no})->{state}, 'PAID', 'query and notify share settlement');
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), '17.30', 'query credits exactly one additional order');

my $failure = $controller->create_order(amount => '7.00', ps => 'epay');
push @ids, $failure->{out_trade_no};
my $fail_notify = sign_request({ %$params, out_trade_no => $failure->{out_trade_no}, trade_no => 'epay_fixture_trade_003', money => '7.00' }, $profile);
my $original_payment = \&Core::User::payment;
{
    # Force a failure after User.payment inserted its funds/task, before order
    # status is updated/committed. Real DB rollback must remove all effects.
    local *Core::User::payment = sub {
        my $self = shift;
        my $result = $original_payment->($self, @_);
        die "测试注入：提交前失败\n";
    };
    ok(!eval { $controller->process_notification($fail_notify); 1 }, 'failure after funds/task insertion is not acknowledged');
}
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), '17.30', 'failure rolls back balance');
is($dbh->selectrow_array('SELECT COUNT(*) FROM pays_history WHERE user_id=?', undef, $user_id), 2, 'failure rolls back funds entry');
is($dbh->selectrow_array('SELECT COUNT(*) FROM spool WHERE user_id=?', undef, $user_id), 2, 'failure rolls back durable task');
is($controller->return_status($failure->{out_trade_no})->{state}, 'PENDING', 'failed transaction retains pending state');
{
    local $controller->{test_dbh} = bless { real => $dbh, AutoCommit => 0 }, 'EpayCommitFailureDBH';
    ok(!eval { $controller->process_notification($fail_notify); 1 }, 'commit failure is not acknowledged');
}
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), '17.30', 'commit failure also rolls back funds');
is($controller->return_status($failure->{out_trade_no})->{state}, 'PENDING', 'commit failure cannot mark order paid');
is($controller->process_notification($fail_notify)->{state}, 'PAID', 'later valid retry settles once after failure');
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), '24.30', 'retry credits the frozen amount once');

my $racing = $controller->create_order(amount => '1.10', ps => 'epay');
push @ids, $racing->{out_trade_no};
my $race_params = { %$params, out_trade_no => $racing->{out_trade_no}, trade_no => 'epay_fixture_trade_004', money => '1.10' };
my $race_notification = sign_request($race_params, $profile);
$controller->{http_request} = sub { +{ %$race_params, code => 1, status => 1 } };
my @children;
for my $mode ('notify', 'query') {
    my $pid = fork();
    die 'Cannot fork concurrency fixture' unless defined $pid;
    if (!$pid) {
        # A new server connection per process; never use a fork-inherited DBI
        # socket for the concurrent transaction. _exit skips fixture cleanup.
        my $connection = $dbh->clone({ RaiseError => 1, AutoCommit => 0, InactiveDestroy => 1 });
        get_service('config')->local->{dbh} = $connection;
        my $ok = eval {
            my $res = $mode eq 'notify' ? $controller->process_notification($race_notification)
                : $controller->reconcile(out_trade_no => $racing->{out_trade_no});
            die 'Race settlement failed' unless $res && $res->{state} eq 'PAID';
            1;
        };
        $connection->disconnect;
        POSIX::_exit($ok ? 0 : 1);
    }
    push @children, $pid;
}
for my $pid (@children) { waitpid($pid, 0); is($?, 0, 'concurrent notify/query both confirm durable settlement') }
is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), '25.40', 'race credits once');
is($dbh->selectrow_array('SELECT COUNT(*) FROM pays_history WHERE user_id=?', undef, $user_id), 4, 'race has one new funds entry');
is($dbh->selectrow_array('SELECT COUNT(*) FROM spool WHERE user_id=?', undef, $user_id), 4, 'race has one new entitlement task');

my $orders_before = $dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id);
ok(!$controller->create_order(amount => '3.00', ps => 'epay', dry_run => 1), 'dry_run cannot silently commit a real order');
get_service('report')->errors;
is($dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id), $orders_before, 'dry_run leaves no pending order');
ok(!$controller->reconcile(out_trade_no => $racing->{out_trade_no}, dry_run => 1), 'reconcile rejects dry_run too');
get_service('report')->errors;

{
    local $controller->{test_profile}->{show_for_client} = 0;
    ok(!$controller->create_order(amount => '3.00', ps => 'epay'), 'client cannot select a hidden profile');
    get_service('report')->errors;
}
my $fixed;
{
    local $controller->{test_profile}->{type} = 'alipay';
    $fixed = $controller->create_order(amount => '2.00', ps => 'epay', type => 'wxpay');
}
push @ids, $fixed->{out_trade_no};
my $fixed_row = $dbh->selectrow_hashref('SELECT * FROM epay_orders WHERE out_trade_no=?', undef, $fixed->{out_trade_no});
is($fixed_row->{payment_type}, 'alipay', 'configured profile type is frozen despite browser override');
is($fixed->{checkout_request}->{fields}->{type}, 'alipay', 'browser cannot redirect fixed profile to another payment type');

done_testing();
