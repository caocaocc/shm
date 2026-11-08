use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use lib ($ENV{SHM_ROOT_DIR} || "/app") . "/pay_systems/lib";
use SHM::Pay::Epay;
use Core::User;
use Core::Cloud::Currency;
use Core::System::ServiceManager qw(get_service);
use lib ($ENV{SHM_ROOT_DIR} || "/app") . "/pay_systems/lib";
use SHM::Pay::Epay::Protocol qw(sign_request);
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
    use parent 'SHM::Pay::Epay';
    sub _actor { Core::System::ServiceManager::get_service('user', _id => $_[0]->{actor_id}, user_id => $_[0]->{actor_id}) }
    sub _billing_currency { 'CNY' }
    sub _profile { +{ %{ $_[0]->{test_profile} } } }
    sub _key { 'k' x 32 }
    sub _system_url { 'https://bill.example.test' }
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
    paysystem => 'epay', show_for_client => 1, pid => '1001', key => 'epay-integration-only',
    apiurl => 'https://epay.example.test', action => 'submit',
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
is($created->{checkout_request}->{url}, 'https://epay.example.test/submit.php', 'MD5 submit checkout correctly generated');
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
    is($url, 'https://epay.example.test/api.php', 'MD5 query uses authenticated api.php endpoint');
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
my $fixed=$controller->create_order(amount=>'2.00',ps=>'epay',type=>'alipay');
push @ids,$fixed->{out_trade_no};
my $fixed_row=$dbh->selectrow_hashref('SELECT * FROM epay_orders WHERE out_trade_no=?',undef,$fixed->{out_trade_no});
is($fixed_row->{payment_type},'alipay','allowed user payment choice is frozen');
is($fixed->{checkout_request}->{fields}->{type},'alipay','selected payment type is sent to gateway');
ok(!$controller->create_order(amount=>'2.00',ps=>'epay',type=>'arbitrary_type'),'unknown payment type is rejected');
get_service('report')->errors;

my $existing_order_secret = $controller->_frozen_profile($stored)->{md5_key};
{
    local $controller->{test_profile}->{key} = 'replacement-key-must-not-change-old-order';
    is($controller->_frozen_profile($stored)->{md5_key}, $existing_order_secret, 'old encrypted order keeps its credentials after a merchant edit');
}
{
    local $controller->{test_profile}->{action} = 'mapi';
    my $before_selection = $dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id);
    my $selection = $controller->create_order(amount => '2.00', ps => 'epay');
    ok($selection->{need_payment_type}, 'API mode requests a payment choice');
    is($selection->{action}, 'mapi', 'payment selection retains the configured native MD5 action');
    is($selection->{amount}, '2.00', 'choice keeps normalized amount');
    is($dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id), $before_selection, 'choosing a method does not create a premature order');
    for my $case ([payurl=>'https://epay.example.test/pay/fixture'], [qrcode=>'weixin://wxpay/bizpayurl?pr=fixture'], [urlscheme=>'weixin://dl/business/?ticket=fixture']) {
        $controller->{http_request} = sub { +{ code=>1,trade_no=>'fixture_'.unpack('H*',Core::Utils::random_bytes(4)),@$case } };
        my $created_api = $controller->create_order(amount=>'2.00',ps=>'epay',type=>'wxpay');
        ok($created_api, "API $case->[0] checkout is supported");
        push @ids,$created_api->{out_trade_no};
        my $field=$case->[0] eq 'payurl'?'checkout_url':$case->[0] eq 'qrcode'?'checkout_qrcode':'checkout_scheme';
        is($created_api->{$field},$case->[1],"$field returned without changing presentation");
    }
}

{
    local $controller->{test_profile}->{action}='mapi';
    my $calls=0;
    $controller->{http_request}=sub {$calls++;die 'network-detail-with-test-secret'};
    my $pending=$controller->create_order(amount=>'3.00',ps=>'epay',type=>'alipay');
    ok($pending && $pending->{out_trade_no},'checkout failure retains a visible original order number');
    push @ids,$pending->{out_trade_no};
    is($pending->{state},'PENDING','checkout failure remains pending');
    is($calls,1,'checkout error does not switch interfaces or create a second request');
    unlike(SHM::Pay::Epay::_json($pending),qr/network-detail|test-secret/,'checkout error never exposes raw transport detail');
    ok($pending->{checkout_error},'checkout failure has a safe explanatory result');
}

# Snapshots authenticate the local owner, amount and gateway as well as keys.
for my $field (qw(user_id amount_cents pid gateway_id payment_type)) {
    my %tampered = %$stored;
    $tampered{$field} = $field eq 'user_id' || $field eq 'amount_cents' ? $tampered{$field}+1 : 'different';
    ok(!eval {$controller->_frozen_profile(\%tampered);1},"encrypted credentials cannot be rebound by changing $field");
}

for my $change ([api_url=>'https://changed.example.test'],[notify_url=>'https://changed.example.test/notify'],[timeout=>59]) {
    my %tampered=%$stored;
    my $changed_snapshot=SHM::Pay::Epay::_decode($stored->{profile_config});
    $changed_snapshot->{$change->[0]}=$change->[1];
    $tampered{profile_config}=SHM::Pay::Epay::_json($changed_snapshot);
    $tampered{config_fingerprint}=Digest::SHA::sha256_hex($tampered{profile_config});
    ok(!eval{$controller->_frozen_profile(\%tampered);1},"authenticated snapshot rejects changed $change->[0] even with recomputed ordinary fingerprint");
}

subtest 'configured payment code is fixed before creating or sending an order' => sub {
    local $controller->{test_profile} = {%{ $controller->{test_profile} }, type => 'qqpay'};
    my $calls = 0;
    local $controller->{http_request} = sub { $calls++; die 'Unexpected gateway request' };
    my $before_conflict = $dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id);
    for my $choice ('alipay', 'wxpay', '', undef, [], {}) {
        ok(!$controller->create_order(amount => '2.00', ps => 'epay', type => $choice), 'browser cannot replace the configured provider code');
        get_service('report')->errors;
    }
    is($dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id), $before_conflict, 'conflicting requests leave no new order');
    is($calls, 0, 'conflicting requests do not contact the gateway');

    my $submit = $controller->create_order(amount => '2.01', ps => 'epay', type => 'qqpay');
    ok($submit, 'matching browser code is accepted for a configured channel');
    die 'Cannot continue fixed type fixture without submit order' unless $submit;
    push @ids, $submit->{out_trade_no};
    is($submit->{checkout_request}->{fields}->{type}, 'qqpay', 'submit sends the configured provider code');
    my $submit_row = $dbh->selectrow_hashref('SELECT * FROM epay_orders WHERE out_trade_no=?', undef, $submit->{out_trade_no});
    is($submit_row->{payment_type}, 'qqpay', 'configured submit type is frozen in the existing order field');
    my $submit_profile = $controller->_frozen_profile($submit_row);
    is($submit_profile->{type}, 'qqpay', 'configured submit type is authenticated in its snapshot');
    ok(SHM::Pay::Epay::Protocol::verify_signature($submit->{checkout_request}->{fields}, $submit_profile), 'configured submit type participates in the request signature');

    $controller->{test_profile}->{action} = 'mapi';
    $controller->{http_request} = sub {
        my ($url, $fields) = @_;
        $calls++;
        is($url, 'https://epay.example.test/mapi.php', 'configured API channel keeps the original endpoint');
        is($fields->{type}, 'qqpay', 'API sends the configured code without a browser choice');
        ok(SHM::Pay::Epay::Protocol::verify_signature($fields, $submit_profile), 'configured API type is signed');
        return {code => 1, trade_no => 'epay_fixture_fixed_type_api', payurl => 'https://epay.example.test/pay/fixed'};
    };
    my $api_order = $controller->create_order(amount => '2.02', ps => 'epay');
    ok($api_order && $api_order->{checkout_url}, 'configured API channel proceeds directly to payment');
    die 'Cannot continue fixed type fixture without API order' unless $api_order && $api_order->{out_trade_no};
    push @ids, $api_order->{out_trade_no};
    ok(!$api_order->{need_payment_type}, 'configured API channel needs no payment selection page');
    is($calls, 1, 'configured API channel sends one request');
    my $api_row = $dbh->selectrow_hashref('SELECT * FROM epay_orders WHERE out_trade_no=?', undef, $api_order->{out_trade_no});
    is($api_row->{payment_type}, 'qqpay', 'configured API type is frozen');
    my $submit_snapshot = $submit_row->{profile_config};
    my $api_snapshot = $api_row->{profile_config};

    # A merchant edit affects new orders only. Both settlement entry points
    # must continue validating already-created orders against their own type.
    $controller->{test_profile}->{type} = 'wxpay';
    my $before_credit = $dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id);
    my $notify = sign_request({pid => '1001', out_trade_no => $submit->{out_trade_no},
        trade_no => 'epay_fixture_fixed_type_notify', type => 'qqpay', money => '2.01',
        trade_status => 'TRADE_SUCCESS'}, $submit_profile);
    is($controller->process_notification($notify)->{state}, 'PAID', 'notification uses the original configured code after merchant edit');
    $controller->{http_request} = sub {
        my ($url, $fields) = @_;
        is($fields->{out_trade_no}, $api_order->{out_trade_no}, 'query still targets the original API order');
        return {code => 1, status => 1, pid => '1001', out_trade_no => $api_order->{out_trade_no},
            trade_no => 'epay_fixture_fixed_type_api', type => 'qqpay', money => '2.02'};
    };
    is($controller->reconcile(out_trade_no => $api_order->{out_trade_no})->{state}, 'PAID', 'query uses the original configured code after merchant edit');
    is($dbh->selectrow_array('SELECT balance FROM users WHERE user_id=?', undef, $user_id), sprintf('%.2f', $before_credit + 4.03), 'original orders credit their frozen amounts once');
    is($dbh->selectrow_array('SELECT profile_config FROM epay_orders WHERE out_trade_no=?', undef, $submit->{out_trade_no}), $submit_snapshot, 'merchant edit and notify do not rewrite the existing submit snapshot');
    is($dbh->selectrow_array('SELECT profile_config FROM epay_orders WHERE out_trade_no=?', undef, $api_order->{out_trade_no}), $api_snapshot, 'merchant edit and query do not rewrite the existing API snapshot');
};

subtest 'native payment aliases retain their own configured channels' => sub {
    my $base_profile = {%{ $controller->{test_profile} }};
    my $profiles = {
        epay_alipay => {%$base_profile, name => '支付宝', type => 'alipay'},
        epay_wechat => {%$base_profile, name => '微信支付', type => 'wxpay'},
    };
    my $original_config = \&Core::Config::data_by_name;
    local *Core::Config::data_by_name = sub {
        return $profiles if $_[1] eq 'pay_systems';
        return $original_config->(@_);
    };
    local *EpayTestController::_profile = \&SHM::Pay::Epay::_profile;
    for my $alias (qw(epay_alipay epay_wechat)) {
        my $order = $controller->create_order(amount => '1.00', ps => $alias);
        ok($order, "$alias uses the native module alias lookup");
        die 'Cannot continue native alias fixture without order' unless $order;
        push @ids, $order->{out_trade_no};
        is($order->{profile}, $alias, 'order records the selected alias');
        is($order->{checkout_request}->{fields}->{type}, $profiles->{$alias}->{type}, 'selected alias supplies its own fixed payment code');
    }
    my $before_override = $dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id);
    ok(!$controller->create_order(amount => '1.00', ps => 'epay_alipay', type => 'wxpay'), 'browser cannot turn the Alipay alias into the WeChat channel');
    get_service('report')->errors;
    is($dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id), $before_override, 'alias override leaves no extra order');
};

subtest 'invalid channel settings cannot create or send an order' => sub {
    my $calls = 0;
    local $controller->{http_request} = sub { $calls++; die 'Unexpected gateway request' };
    my $before_invalid = $dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id);
    for my $setting ([api_url => 'https://old.example.test'], [checkout => 'api'],
            [action => 'create'], [action => 'api'], [action => undef], [action => []]) {
        local $controller->{test_profile} = {%{ $controller->{test_profile} }, @$setting};
        ok(!$controller->create_order(amount => '1.00', ps => 'epay'), 'invalid native or old custom setting is rejected');
        get_service('report')->errors;
    }
    is($dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id), $before_invalid, 'invalid channel settings leave no order');
    is($calls, 0, 'invalid channel settings never call the gateway');
};

subtest 'RSA native submit and create actions use their matching endpoints' => sub {
    unless (eval { require Crypt::PK::RSA; 1 }) { plan skip_all => 'Cryptx unavailable; official runtime runs RSA integration' }
    my $merchant = Crypt::PK::RSA->new; $merchant->generate_key(256, 65537);
    my $platform = Crypt::PK::RSA->new; $platform->generate_key(256, 65537);
    local $controller->{test_profile} = {
        paysystem => 'epay', show_for_client => 1, pid => '1001', apiurl => 'https://rsa.example.test',
        merchant_private_key => $merchant->export_key_pem('private'),
        platform_public_key => $platform->export_key_pem('public'), type => 'wxpay',
    };
    my $submit = $controller->create_order(amount => '1.30', ps => 'epay');
    ok($submit, 'RSA defaults to a signed submit request');
    die 'Cannot continue RSA fixture without submit order' unless $submit;
    push @ids, $submit->{out_trade_no};
    is($submit->{checkout_request}->{url}, 'https://rsa.example.test/api/pay/submit', 'RSA default uses native submit endpoint');
    is($submit->{checkout_request}->{fields}->{sign_type}, 'RSA', 'RSA request keeps the native signing parameter');

    $controller->{test_profile}->{action} = 'create';
    delete $controller->{test_profile}->{type};
    my $before_choice = $dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id);
    my $choice = $controller->create_order(amount => '1.31', ps => 'epay');
    ok($choice->{need_payment_type}, 'RSA create without type requests the existing selection page');
    is($choice->{action}, 'create', 'selection page retains native RSA create action');
    is($dbh->selectrow_array('SELECT COUNT(*) FROM epay_orders WHERE user_id=?', undef, $user_id), $before_choice, 'RSA choice does not create an order prematurely');
    local $controller->{http_request} = sub {
        my ($url, $fields) = @_;
        is($url, 'https://rsa.example.test/api/pay/create', 'RSA create uses native API endpoint');
        is($fields->{method}, 'jump', 'native method remains the payment presentation parameter');
        is($fields->{type}, 'wxpay', 'RSA create sends the selected scalar payment code');
        return sign_request({code => 0, trade_no => 'epay_fixture_rsa_native_create',
            pay_type => 'jump', pay_info => 'https://rsa.example.test/pay/fixture', timestamp => ''.time},
            {protocol => 'v2_rsa', merchant_private_key => $platform->export_key_pem('private')});
    };
    my $created_rsa = $controller->create_order(amount => '1.31', ps => 'epay', type => 'wxpay');
    ok($created_rsa && $created_rsa->{checkout_url}, 'signed RSA API response is accepted');
    die 'Cannot continue RSA fixture without create order' unless $created_rsa && $created_rsa->{out_trade_no};
    push @ids, $created_rsa->{out_trade_no};
};

done_testing();
