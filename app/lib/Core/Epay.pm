package Core::Epay;

use v5.14;
use strict;
use warnings;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Pay::Epay qw(money_to_cents cents_to_money build_payment_request
    decode_response validate_notification validate_payment_evidence);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Encode qw(is_utf8);
use URI::Escape qw(uri_escape_utf8);
use Core::Utils qw(random_bytes get_user_ip);

sub table { return 'epay_orders' }
sub _actor { shift->user->authenticated }
sub _billing_currency { get_service('config')->data_by_name('billing')->{currency} // '' }

sub _json { JSON::PP->new->canonical->utf8->encode($_[0]) }
sub _decode { ref $_[0] eq 'HASH' ? $_[0] : JSON::PP->new->utf8(is_utf8($_[0]) ? 0 : 1)->decode($_[0]) }

sub _profile {
    my ($self, $name) = @_;
    die "易支付配置名称无效\n" unless defined $name && $name =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    my $profiles = get_service('config')->data_by_name('pay_systems');
    my $profile = $profiles->{$name};
    die "易支付未配置\n" unless ref $profile eq 'HASH'
        && ($name eq 'epay' || ($profile->{paysystem} // '') eq 'epay');
    return { %$profile };
}

sub _secret {
    my ($self, $path) = @_;
    die "易支付密钥文件未配置\n" unless defined $path && !ref $path && $path =~ m{\A/} && -f $path;
    open(my $file, '<:raw', $path) or die "无法读取易支付密钥文件\n";
    local $/;
    my $key = <$file>;
    close $file;
    die "易支付密钥文件无效\n" unless defined $key && length($key) > 0 && length($key) <= 131072;
    $key =~ s/\s+\z//;
    return $key;
}

sub _credentials {
    my ($self, $profile_name, $frozen) = @_;
    my $current = $self->_profile($profile_name);
    my $version = $frozen->{key_version};
    my $credentials = $current->{credential_versions}->{$version};
    $credentials //= $current if ($current->{key_version} // '') eq $version;
    die "订单使用的历史易支付密钥未配置\n" unless ref $credentials eq 'HASH';
    my %profile = %$frozen;
    if ($frozen->{protocol} eq 'v2_rsa') {
        $profile{merchant_private_key} = $self->_secret($credentials->{merchant_private_key_file});
        $profile{platform_public_key} = $self->_secret($credentials->{platform_public_key_file});
    } elsif ($frozen->{protocol} eq 'v1_md5') {
        $profile{md5_key} = $self->_secret($credentials->{md5_key_file});
    } else { die "不支持的易支付协议\n"; }
    return \%profile;
}

sub _frozen_profile {
    my ($self, $order) = @_;
    my $snapshot = _decode($order->{profile_config});
    die "易支付订单配置损坏\n" unless sha256_hex(_json($snapshot)) eq $order->{config_fingerprint}
        && $snapshot->{protocol} eq $order->{protocol} && $snapshot->{pid} eq $order->{pid}
        && $snapshot->{key_version} eq $order->{key_version};
    return $self->_credentials($order->{profile}, $snapshot);
}

sub _public_profile {
    my ($self, $name, $profile) = @_;
    die "易支付商户 ID 无效\n" unless defined $profile->{pid} && $profile->{pid} =~ /\A[1-9][0-9]{0,11}\z/;
    die "易支付密钥版本未配置\n" unless ($profile->{key_version} // '') =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
    my %frozen = map { $_ => $profile->{$_} }
        grep { defined $profile->{$_} }
        qw(api_url pid protocol key_version notify_url return_url payment_name type timeout timestamp_skew checkout);
    $frozen{pid} = "$frozen{pid}";
    $frozen{timeout} //= 10;
    $frozen{timestamp_skew} //= 300;
    $frozen{checkout} //= 'api';
    die "易支付下单方式无效\n" unless $frozen{checkout} eq 'api' || $frozen{checkout} eq 'submit';
    die "易支付支付方式无效，应为 1 至 32 位字母、数字或下划线\n" if defined $frozen{type}
        && (ref $frozen{type} || $frozen{type} !~ /\A[A-Za-z0-9_]{1,32}\z/);
    die "易支付 API 下单必须配置支付方式\n" if $frozen{checkout} eq 'api'
        && (!defined $frozen{type} || $frozen{type} eq '');
    die "易支付超时设置无效\n" unless $frozen{timeout} =~ /\A[0-9]+\z/ && $frozen{timeout} >= 1 && $frozen{timeout} <= 60;
    die "易支付通知时差设置无效\n" unless $frozen{timestamp_skew} =~ /\A[0-9]+\z/
        && $frozen{timestamp_skew} >= 1 && $frozen{timestamp_skew} <= 3600;
    for my $field (qw(api_url notify_url return_url)) {
        require URI;
        my $uri = URI->new($frozen{$field} // '');
        die "易支付地址必须使用 HTTPS\n" unless ($uri->scheme // '') eq 'https'
            && $uri->can('host') && $uri->host && !defined $uri->userinfo && !defined $uri->fragment;
        die "易支付 API 地址不能包含查询参数\n" if $field eq 'api_url' && defined $uri->query;
        if ($field eq 'api_url') {
            $frozen{$field} = $uri->canonical->as_string;
            $frozen{$field} =~ s{/+\z}{};
        }
    }
    return \%frozen;
}

sub _order {
    my ($self, $id, $lock) = @_;
    die "易支付订单号无效\n" unless defined $id && $id =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    my $row = $self->dbh->selectrow_hashref(
        'SELECT * FROM epay_orders WHERE out_trade_no = ?' . ($lock ? ' FOR UPDATE' : ''), undef, $id);
    die "易支付订单不存在\n" unless $row;
    return $row;
}

sub _authorized_order {
    my ($self, $id) = @_;
    my $row = $self->_order($id);
    my $actor = $self->_actor;
    die "无权操作此支付订单\n" unless $actor && ($actor->is_admin || $actor->id == $row->{user_id});
    return $row;
}

sub _display_order {
    my ($self, $row) = @_;
    return { map { $_ => $row->{$_} }
        qw(out_trade_no user_id profile currency amount_cents state trade_no payment_id created_at paid_at) };
}

sub _transaction {
    my ($self, $code) = @_;
    my $dbh = $self->dbh;
    die "易支付需要事务数据库连接\n" if $dbh->{AutoCommit};
    local $dbh->{RaiseError} = 1;
    local $dbh->{PrintError} = 0;
    my $result;
    my $ok = eval {
        $result = $code->();
        # Do not use the test-mode shortcut in Core::Sql::Data::commit: an ACK
        # must never mean a transaction that has not actually committed.
        $dbh->commit or die "易支付事务提交失败\n";
        1;
    };
    unless ($ok) {
        my $error = $@ || "易支付事务失败\n";
        eval { $dbh->rollback };
        delete get_service('config')->local->{_post_commit_callbacks};
        die $error;
    }
    my $callbacks = delete get_service('config')->local->{_post_commit_callbacks};
    for my $callback (@{ $callbacks || [] }) {
        eval { $callback->() };
        logger->warning('易支付提交后任务通知失败，持久化队列仍可重试') if $@;
    }
    return $result;
}

sub _assert_transactional {
    my ($self) = @_;
    my @tables = qw(epay_orders users pays_history bonus_history spool);
    my $rows = $self->dbh->selectall_arrayref(
        'SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()'
        . ' AND TABLE_NAME IN (' . join(',', ('?') x @tables) . ')', { Slice => {} }, @tables);
    my %engines = map { $_->{TABLE_NAME} => $_->{ENGINE} } @$rows;
    die "易支付资金与任务表必须全部使用 InnoDB\n"
        if grep { ($engines{$_} // '') ne 'InnoDB' } @tables;
}

sub _guard {
    my ($self, $code) = @_;
    my $result = eval { $code->() };
    if ($@) {
        my $message = $@;
        # Never include a URL, credentials, DB diagnostic, or HTTP response in
        # an error. Our validation errors are deliberately short Chinese text.
        $message =~ s/\s+at .*//s;
        $message = '易支付处理失败，请联系管理员' unless $message =~ /\A[\x{4e00}-\x{9fff}]/;
        report->add_error($message);
        return undef;
    }
    return $result;
}

sub create_order {
    my ($self, %args) = @_;
    return $self->_guard(sub {
        die "支付事务不支持 dry_run\n" if $args{dry_run};
        my $actor = $self->_actor;
        die "需要登录后发起支付\n" unless $actor && $actor->id && !$actor->is_blocked;
        die "易支付仅支持人民币账户\n" unless $self->_billing_currency eq 'CNY';
        my $name = $args{ps} // $args{profile} // 'epay';
        my $current = $self->_profile($name);
        die "易支付已停用\n" if exists $current->{enabled} && !$current->{enabled};
        die "此支付通道未向客户开放\n" unless $actor->is_admin || $current->{show_for_client};
        my $amount = money_to_cents($args{amount});
        die "支付金额超出允许范围\n" if $amount < ($current->{min_amount_cents} // 1)
            || $amount > ($current->{max_amount_cents} // 9_999_999_999);
        my $frozen = $self->_public_profile($name, $current);
        my $profile = $self->_credentials($name, $frozen);
        my $id = 'shm_' . unpack('H*', random_bytes(16));
        my $row = {
            out_trade_no => $id, user_id => $actor->id, profile => $name,
            protocol => $frozen->{protocol}, pid => $frozen->{pid}, key_version => $frozen->{key_version},
            amount_cents => $amount, currency => 'CNY', payment_type => $frozen->{type},
            gateway_id => substr(sha256_hex($frozen->{api_url}), 0, 32),
            profile_config => _json($frozen), config_fingerprint => sha256_hex(_json($frozen)),
        };
        # Only a generic account top-up: a browser cannot select arbitrary
        # user IDs or invent a package/entitlement through this payment API.
        $self->_transaction(sub {
            $self->_assert_transactional;
            $self->dbh->do(
                'INSERT INTO epay_orders (out_trade_no,user_id,profile,protocol,pid,key_version,'
                . 'amount_cents,currency,payment_type,gateway_id,profile_config,config_fingerprint)'
                . ' VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', undef,
                @$row{qw(out_trade_no user_id profile protocol pid key_version amount_cents currency
                    payment_type gateway_id profile_config config_fingerprint)});
            return 1;
        });
        my $checkout = $self->_checkout($row, $profile);
        return { %{ $self->_display_order($self->_order($id)) }, %$checkout };
    });
}

sub _http {
    my ($self, $url, $params, $profile) = @_;
    require URI;
    my $uri = URI->new($url);
    die "易支付服务请求必须使用 HTTPS\n" unless ($uri->scheme // '') eq 'https'
        && $uri->can('host') && $uri->host && !defined $uri->userinfo && !defined $uri->fragment;
    return $self->{http_request}->($url, $params, $profile) if $self->{http_request};
    require LWP::UserAgent;
    require HTTP::Request;
    my $ua = LWP::UserAgent->new(timeout => $profile->{timeout} // 10,
        max_redirect => 0, ssl_opts => { verify_hostname => 1 });
    my $body = join('&', map { uri_escape_utf8($_) . '=' . uri_escape_utf8($params->{$_}) } sort keys %$params);
    my $request = HTTP::Request->new('POST', $url);
    $request->header('Content-Type' => 'application/x-www-form-urlencoded; charset=utf-8');
    $request->content($body);
    my $response = $ua->request($request);
    die "易支付服务暂不可用，请查询订单后重试\n" unless $response->is_success;
    die "易支付响应过大\n" if length($response->content) > 131072;
    return $response->content;
}

sub _checkout {
    my ($self, $row, $profile) = @_;
    my $request = build_payment_request($row, $profile,
        flow => $profile->{checkout} eq 'submit' ? 'submit' : 'create', clientip => get_user_ip());
    if ($profile->{checkout} eq 'submit') {
        return { checkout_request => $request };
    }
    my $result = decode_response($self->_http($request->{url}, $request->{fields}, $profile), $profile);
    my $url = $profile->{protocol} eq 'v2_rsa' && ($result->{pay_type} // '') eq 'jump'
        ? $result->{pay_info} : $profile->{protocol} eq 'v1_md5' ? $result->{payurl} : undef;
    die "易支付未返回可用的支付跳转地址\n" unless defined $url && !ref $url && $url =~ m{\Ahttps://[^\s]+\z};
    die "易支付交易号无效\n" unless ($result->{trade_no} // '') =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    $self->_transaction(sub {
        my $locked = $self->_order($row->{out_trade_no}, 1);
        die "易支付交易号不匹配\n" if $locked->{trade_no} && $locked->{trade_no} ne $result->{trade_no};
        $self->dbh->do('UPDATE epay_orders SET trade_no = ? WHERE out_trade_no = ?', undef,
            $result->{trade_no}, $row->{out_trade_no});
        return 1;
    });
    return { checkout_url => $url };
}

sub status {
    my ($self, %args) = @_;
    return $self->_guard(sub { $self->_display_order($self->_authorized_order($args{out_trade_no})) });
}

sub return_status {
    my ($self, $id) = @_;
    my $row = $self->_order($id);
    # An unguessable order ID only exposes its payment state, not its owner or
    # secrets. The browser return is never evidence for a balance mutation.
    return { out_trade_no => $row->{out_trade_no}, state => $row->{state},
        amount_cents => $row->{amount_cents}, currency => $row->{currency} };
}

# Used by the public CGI callback after DB initialization. Any throw means the
# gateway must retry; no success response is returned before a durable commit.
sub process_notification {
    my ($self, $params) = @_;
    my $row = $self->_order($params->{out_trade_no});
    my $profile = $self->_frozen_profile($row);
    validate_notification($params, $row, $profile, allow_paid_replay => 1);
    return $self->_settle($row, $params, $profile, 'notify');
}

sub reconcile {
    my ($self, %args) = @_;
    return $self->_guard(sub {
        die "支付事务不支持 dry_run\n" if $args{dry_run};
        my $row = $self->_authorized_order($args{out_trade_no});
        return $self->_display_order($row) if $row->{state} eq 'PAID';
        my $profile = $self->_frozen_profile($row);
        my $base = $profile->{api_url};
        $base =~ s{/+\z}{};
        my ($url, $params);
        if ($profile->{protocol} eq 'v2_rsa') {
            $url = "$base/api/pay/query";
            $params = Core::Pay::Epay::sign_request({ pid => $row->{pid},
                out_trade_no => $row->{out_trade_no}, timestamp => '' . time }, $profile);
        } else {
            $url = "$base/api.php";
            $params = { act => 'order', pid => $row->{pid}, key => $profile->{md5_key}, out_trade_no => $row->{out_trade_no} };
        }
        my $result = decode_response($self->_http($url, $params, $profile), $profile);
        return $self->_display_order($row) unless defined $result->{status} && $result->{status} eq '1';
        validate_payment_evidence($result, $row, $profile, mode => 'query');
        return $self->_settle($row, $result, $profile, 'query');
    });
}

sub _settle {
    my ($self, $row, $params, $profile, $source) = @_;
    return $self->_transaction(sub {
        $self->_assert_transactional;
        # Use the same DB handle for both locks. Lock the user first to match
        # other balance operations; never call Base::lock's separate paths.
        my $user_row = $self->dbh->selectrow_hashref('SELECT * FROM users WHERE user_id = ? FOR UPDATE', undef, $row->{user_id});
        die "支付订单用户不存在\n" unless $user_row;
        my $locked = $self->_order($row->{out_trade_no}, 1);
        validate_payment_evidence($params, $locked, $profile, mode => $source, allow_paid_replay => 1);
        return $self->_display_order($locked) if $locked->{state} eq 'PAID';
        die "支付订单状态无效\n" unless $locked->{state} eq 'PENDING';
        my $local = get_service('config')->local;
        local $local->{user_id} = $locked->{user_id};
        my $user = get_service('user', _id => $locked->{user_id}, user_id => $locked->{user_id});
        $user->res($user_row);
        my $key = join(':', 'epay', $locked->{gateway_id}, $locked->{pid}, $params->{trade_no});
        my $payment = $user->payment(
            user_id => $locked->{user_id}, currency => 'CNY',
            money => cents_to_money($locked->{amount_cents}), pay_system_id => 'epay', uniq_key => $key,
            comment => { provider => 'epay', profile => $locked->{profile}, protocol => $locked->{protocol},
                out_trade_no => $locked->{out_trade_no}, trade_no => $params->{trade_no}, source => $source },
        );
        die "支付入账失败\n" unless $payment && $payment->{id} && report->is_success;
        die "支付流水绑定不匹配\n" unless $payment->{user_id} == $locked->{user_id}
            && money_to_cents($payment->{money}) == $locked->{amount_cents};
        $self->dbh->do('UPDATE epay_orders SET state = ?, trade_no = ?, payment_id = ?, paid_at = CURRENT_TIMESTAMP WHERE out_trade_no = ?',
            undef, 'PAID', $params->{trade_no}, $payment->{id}, $locked->{out_trade_no});
        # User.payment inserts the PAYMENT spool event. Never call the VPN API
        # here: payment delivery and entitlement delivery have separate retries.
        return $self->_display_order($self->_order($locked->{out_trade_no}));
    });
}

1;
