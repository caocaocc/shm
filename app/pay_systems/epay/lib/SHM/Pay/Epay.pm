package SHM::Pay::Epay;
use v5.14;
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use URI;
use HTTP::Request::Common qw(POST GET);
use LWP::UserAgent;
use SHM::Pay::Epay::Channels qw(merchant);
use SHM::Pay::Epay::Protocol qw(gateway_url money_to_cents cents_to_money build_payment_request sign_request
    verify_notification match_payment decode_response checkout_result);
use SHM::Pay::Epay::Vault qw(account_values seal_order read_order unpack_json);
sub new { bless {}, shift }
sub service { require Core::System::ServiceManager; Core::System::ServiceManager::get_service(@_) }
sub dbh { service('config')->local('dbh') }
sub token { require Crypt::PRNG; return unpack 'H*', Crypt::PRNG::random_bytes($_[0]) }

sub transaction {
    my ($self, $work) = @_;
    my $db = $self->dbh;
    local $db->{RaiseError} = 1;
    local $db->{PrintError} = 0;
    my $state = service('config')->local;
    local $state->{_post_commit_callbacks} = [];
    my $result = eval {
        $db->begin_work if $db->{AutoCommit};
        my $value = $work->($db);
        $db->commit or die "Payment commit failed\n";
        $value;
    };
    if (my $error = $@) {
        eval { $db->rollback unless $db->{AutoCommit} };
        die $error;
    }
    for my $callback (@{$state->{_post_commit_callbacks}}) { eval { $callback->() } }
    return $result;
}
sub _read_account {
    my ($self, $id) = @_;
    my $db = $self->dbh;
    my ($box) = $db->selectrow_array('SELECT credential_box FROM epay_accounts WHERE profile=?', undef, $id);
    return account_values($db, $id, $box);
}
sub currency {
    my ($db, $lock) = @_;
    my ($json) = $db->selectrow_array(q{SELECT value FROM config WHERE config.key='billing'}.($lock ? ' FOR UPDATE' : ''));
    my $current = unpack_json($json);
    die "This wallet does not use CNY\n" unless ($current->{currency} // '') eq 'CNY';
}
sub public_order {
    my ($row) = @_;
    return {map { ($_ => $row->{$_}) } qw(out_trade_no state currency user_id profile amount_cents payment_id)};
}
sub order {
    my ($db, $number, $lock) = @_;
    die "Invalid order\n" unless defined($number) && $number =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
    return $db->selectrow_hashref('SELECT * FROM epay_orders WHERE out_trade_no=?'.($lock ? ' FOR UPDATE' : ''), undef, $number)
        || die "Unknown order\n";
}

sub request_gateway {
    my ($url, $fields, $get) = @_;
    my $ua = LWP::UserAgent->new(timeout => 15, max_redirect => 0, max_size => 1024*1024, protocols_allowed => ['https']);
    $ua->ssl_opts(verify_hostname => 1);
    my $uri = URI->new($url);
    if ($get) { $uri->query_form(%$fields) }
    my $request = $get ? GET($uri) : POST($uri, [map { $_ => encode('UTF-8', "$fields->{$_}") } sort keys %$fields]);
    my $res = $ua->request($request);
    die "Gateway unavailable\n" unless $res->is_success && !$res->header('Client-Aborted');
    return unpack_json($res->content);
}

sub checkout {
    my ($self, $actor, $params) = @_;
    my $id = $params->{ps} // 'epay';
    die "Invalid channel\n" unless $id =~ /\A[a-z][a-z0-9_-]{0,31}\z/;
    die "Invalid payment owner\n" if defined($params->{user_id}) && "$params->{user_id}" ne "".$actor->id;
    my $cents = money_to_cents($params->{amount});
    my $plan = $self->transaction(sub {
        my $db = shift;
        currency($db, 0);
        my ($public) = $db->selectrow_array(q{SELECT value FROM config WHERE config.key='pay_systems' FOR SHARE});
        my $row = unpack_json($public)->{$id};
        die "Channel unavailable\n" unless ref($row) eq 'HASH' && ($row->{paysystem} // $id) eq 'epay'
            && ($row->{enabled} // 1) && $row->{show_for_client};
        my %accounts;
        for my $name ($id eq 'epay' ? ('epay') : ('epay', $id)) {
            $accounts{$name} = $self->_read_account($name);
        }
        my $account = merchant(\%accounts, $id);
        SHM::Pay::Epay::Channels::validate($account);
        my $gateway = gateway_url($account->{apiurl});
        my $rsa = !exists $account->{key};
        my $action = $row->{action} // 'submit';
        my $expected = $rsa ? 'create' : 'mapi';
        die "Invalid checkout mode\n" if $action ne 'submit' && $action ne $expected;
        die "Channel action changed\n" if defined($params->{action}) && $action ne $params->{action};
        my $type = $row->{type};
        if (exists $params->{type}) {
            die "Invalid payment choice\n" unless ($type ? ($params->{type} // '') eq $type :
                ($params->{type} // '') =~ /\A(?:alipay|wxpay)\z/);
            $type = $params->{type};
        }
        if (!$type && $action ne 'submit') { return {choose => 1, ps => $id, amount => cents_to_money($cents), action => $action} }
        my $system = gateway_url(service('config')->data_by_name('api')->{url}).'/shm/pay_systems/epay_';
        my $meta = {api_url => $gateway, pid => $account->{pid}, protocol => $rsa ? 'v2_rsa' : 'v1_md5',
            checkout => $action eq 'submit' ? 'submit' : 'api', notify_url => $system.'notify.cgi',
            return_url => $system.'return.cgi', key_version => 'auto_'.token(16)};
        $meta->{type} = $type if length($type // '');
        my $keys = $rsa ? {map { $_ => $account->{$_} } qw(merchant_private_key platform_public_key)} : {md5_key => $account->{key}};
        my $new = {out_trade_no => 'shm_'.token(20), user_id => $actor->id, profile => $id, pid => $meta->{pid},
            key_version => $meta->{key_version}, protocol => $meta->{protocol}, payment_type => $meta->{type},
            gateway_id => substr(sha256_hex($gateway), 0, 32), amount_cents => $cents, currency => 'CNY', state => 'PENDING'};
        @{$new}{qw(profile_config config_fingerprint)} = seal_order($db, $new, $meta, $keys);
        my @cols = sort keys %$new;
        $db->do('INSERT INTO epay_orders ('.join(',', @cols).') VALUES ('.join(',', ('?') x @cols).')', undef, @{$new}{@cols});
        my $profile = {%$meta, %$keys};
        return {profile => $profile, row => $new, request => build_payment_request($new, $profile, flow => $action,
            clientip => Core::Utils::get_user_ip() || '127.0.0.1')};
    });
    return $plan if $plan->{choose};
    my $view = public_order($plan->{row});
    return {%$view, form => $plan->{request}} if $plan->{profile}{checkout} eq 'submit';
    # Once a pending order exists, even an ambiguous gateway timeout must return this order number.
    my $presentation = eval {
        my $request = $plan->{request};
        my $reply = decode_response(request_gateway($request->{url}, $request->{fields}), $plan->{profile});
        my $show = checkout_result($reply, $plan->{profile});
        if (defined(my $trade = $reply->{trade_no})) {
            die "Invalid gateway trade\n" unless $trade =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
            $self->transaction(sub {
                my $db = shift;
                my $row = order($db, $view->{out_trade_no}, 1);
                die "Trade changed\n" if defined($row->{trade_no}) && $row->{trade_no} ne $trade;
                $db->do('UPDATE epay_orders SET trade_no=? WHERE out_trade_no=?', undef, $trade, $row->{out_trade_no});
            });
        }
        $show;
    };
    return {%$view, %{$presentation || {}}};
}

sub settle {
    my ($self, $number, $evidence, $notice) = @_;
    return $self->transaction(sub {
        my $db = shift;
        my $row = order($db, $number, 1);
        my $snapshot = read_order($db, $row);
        if ($notice) { verify_notification($evidence, $row, $snapshot, allow_paid_replay => 1) }
        else {
            decode_response($evidence, $snapshot);
            die "Payment incomplete\n" unless ($evidence->{status} // '') eq '1';
        }
        my $trade = match_payment($evidence, $row, $snapshot);
        return public_order($row) if $row->{state} eq 'PAID';
        die "Unexpected order state\n" unless $row->{state} eq 'PENDING';
        currency($db, 1);
        $db->selectrow_array('SELECT user_id FROM users WHERE user_id=? FOR UPDATE', undef, $row->{user_id});
        # Reserve the gateway trade in this transaction before invoking SHM balance and event processing.
        $db->do('UPDATE epay_orders SET trade_no=? WHERE out_trade_no=?', undef, $trade, $number);
        Core::Utils::switch_user($row->{user_id});
        my $receipt = service('user', _id => $row->{user_id})->payment(
            money => cents_to_money($row->{amount_cents}), currency => 'CNY', pay_system_id => $row->{profile},
            uniq_key => 'epay:'.$number, comment => {trade_no => $trade, out_trade_no => $number});
        die "Missing payment receipt\n" unless $receipt && $receipt->{id};
        $row->{state} = 'PAID';
        $row->{payment_id} = $receipt->{id};
        $db->do(q{UPDATE epay_orders SET state='PAID',payment_id=?,paid_at=NOW() WHERE out_trade_no=?}, undef, $receipt->{id}, $number);
        return public_order($row);
    });
}
sub status {
    my ($self, $actor, $number, $query) = @_;
    my $db = $self->dbh;
    my $row = order($db, $number, 0);
    die "Access denied\n" unless $actor && ($actor->id == $row->{user_id} ||
        ($actor->is_admin && $actor->can_access(uri => '/admin/user/pay', method => 'GET')));
    return public_order($row) if !$query || $row->{state} eq 'PAID';
    my $snap = read_order($db, $row);
    $db->commit unless $db->{AutoCommit};
    my $v1 = $snap->{protocol} eq 'v1_md5';
    my $url = gateway_url($snap->{api_url}).($v1 ? '/api.php' : '/api/pay/query');
    my $form = {pid => $row->{pid}, out_trade_no => $number};
    my $fields = $v1 ? {%$form, act => 'order', key => $snap->{md5_key}} : sign_request({%$form, timestamp => time}, $snap);
    my $reply = decode_response(request_gateway($url, $fields, $v1), $snap);
    return public_order(order($db, $number, 0)) if ($reply->{status} // '') eq '0';
    return $self->settle($number, $reply, 0);
}
1;
