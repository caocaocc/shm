package SHM::Pay::Epay;

use v5.14;
use strict;
use warnings;
use utf8;
use parent 'Core::Base';
use Core::Base;
use SHM::Pay::Epay::Protocol qw(money_to_cents cents_to_money build_payment_request
    decode_response validate_notification validate_payment_evidence payment_error);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Encode qw(is_utf8 encode);
use Fcntl qw(:DEFAULT :flock :mode);
use File::Path qw(make_path);
use IO::Handle ();
use URI::Escape qw(uri_escape_utf8);
use MIME::Base64 qw(encode_base64 decode_base64);
use Core::Utils qw(random_bytes get_user_ip encrypt_aes256_gcm_base64 decrypt_aes256_gcm_base64);

sub table { return 'epay_orders' }
sub _actor { shift->user->authenticated }
sub _billing_currency { get_service('config')->data_by_name('billing')->{currency} // '' }

sub _json { JSON::PP->new->canonical->utf8->encode($_[0]) }
sub _decode { ref $_[0] eq 'HASH' ? $_[0] : JSON::PP->new->utf8(is_utf8($_[0]) ? 0 : 1)->decode($_[0]) }

sub _profile {
    my ($self, $name) = @_;
    payment_error "易支付配置名称无效\n" unless defined $name && $name =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    my $profiles = get_service('config')->data_by_name('pay_systems');
    my $profile = $profiles->{$name};
    payment_error "易支付未配置\n" unless ref $profile eq 'HASH'
        && ($name eq 'epay' || ($profile->{paysystem} // '') eq 'epay');
    return { %$profile };
}

sub _credential_text {
    my ($value) = @_;
    payment_error "易支付密钥未填写或格式无效\n" unless defined $value && !ref $value
        && length($value) && length(encode('UTF-8', $value)) <= 131072 && $value !~ /\x00/;
    return "$value";
}

sub _configured_credentials {
    my ($self, $profile) = @_;
    my $has_md5 = exists $profile->{key};
    my $has_rsa = exists $profile->{merchant_private_key} || exists $profile->{platform_public_key};
    payment_error "易支付 MD5 与 RSA 密钥不能同时填写\n" if $has_md5 && $has_rsa;
    return { protocol => 'v1_md5', md5_key => _credential_text($profile->{key}) } if $has_md5;
    my $private = _rsa_key($profile->{merchant_private_key}, 1);
    my $public = _rsa_key($profile->{platform_public_key}, 0);
    return { protocol => 'v2_rsa', merchant_private_key => $private, platform_public_key => $public };
}

sub _rsa_key {
    my ($value, $want_private) = @_;
    my $raw = _credential_text($value);
    require Crypt::PK::RSA;
    my $key = eval { Crypt::PK::RSA->new(\$raw) };
    unless ($key) {
        my $encoded = $raw;
        $encoded =~ s/[ \t\r\n]//g;
        if ($encoded =~ /\A[A-Za-z0-9+\/]+={0,2}\z/ && length($encoded) % 4 == 0) {
            my $der = decode_base64($encoded);
            $key = eval { Crypt::PK::RSA->new(\$der) } if encode_base64($der, '') eq $encoded;
        }
    }
    payment_error "商户私钥或平台公钥不是有效的 RSA 密钥\n" unless $key
        && ($want_private ? $key->is_private : !$key->is_private);
    return $key->export_key_pem($want_private ? 'private' : 'public');
}

sub _system_url { get_service('config')->data_by_name('api')->{url} // '' }
sub _https_base {
    my ($value, $label) = @_;
    require URI;
    payment_error "$label 必须是有效的 HTTPS 地址\n" unless defined $value && !ref $value && $value !~ /[\s\x00-\x1f\x7f]/;
    my $uri = URI->new($value);
    payment_error "$label 必须是有效的 HTTPS 地址\n" unless ($uri->scheme // '') eq 'https'
        && $uri->can('host') && $uri->host && !defined $uri->userinfo && !defined $uri->fragment && !defined $uri->query;
    my $result = $uri->canonical->as_string;
    $result =~ s{/+\z}{};
    return $result;
}

sub _public_profile {
    my ($self, $name, $profile, %args) = @_;
    payment_error "易支付商户 ID 无效\n" unless defined $profile->{pid} && !ref $profile->{pid} && $profile->{pid} =~ /\A[1-9][0-9]{0,11}\z/;
    my @unsupported_fields = grep { exists $profile->{$_} } qw(api_url checkout protocol key_version credential_versions merchant_private_key_file platform_public_key_file md5_key_file notify_url return_url timeout timestamp_skew payment_name min_amount_cents max_amount_cents);
    payment_error "易支付配置包含不支持的字段，请使用服务商提供的商户信息\n" if @unsupported_fields;
    my $credentials = $self->_configured_credentials($profile);
    my $base = _https_base($profile->{apiurl}, '易支付网关');
    my $origin = _https_base($self->_system_url, 'SHM 公网地址');
    my $action = exists $profile->{action} ? $profile->{action} : 'submit';
    my $api_action = $credentials->{protocol} eq 'v1_md5' ? 'mapi' : 'create';
    payment_error "易支付通道 action 必须为 submit 或 $api_action\n" unless defined $action && !ref $action
        && ($action eq 'submit' || $action eq $api_action);
    my %frozen = (
        api_url => $base, pid => "$profile->{pid}", protocol => $credentials->{protocol},
        notify_url => "$origin/shm/pay_systems/epay.cgi?action=notify",
        return_url => "$origin/shm/pay_systems/epay.cgi?action=return",
        payment_name => '账户充值', timeout => 10, timestamp_skew => 300,
        checkout => $action eq 'submit' ? 'submit' : 'api',
    );
    if (exists $profile->{type}) {
        my $type = $profile->{type};
        payment_error "易支付支付方式代码无效\n" unless defined $type && !ref $type
            && $type =~ /\A[a-z][a-z0-9_]{0,31}\z/;
        payment_error "所选支付方式与此支付通道不匹配\n" if exists $args{type}
            && (!defined $args{type} || ref $args{type} || $args{type} ne $type);
        $frozen{type} = $type;
    } elsif (exists $args{type}) {
        my $type = $args{type};
        payment_error "请选择支付宝或微信支付\n" unless defined $type && !ref $type
            && ($type eq 'alipay' || $type eq 'wxpay');
        $frozen{type} = $type;
    }
    return \%frozen;
}

sub _storage_uid { my @pw = getpwnam('www-data'); return @pw ? $pw[2] : 33 }
sub _directory {
    my ($self) = @_;
    my $path = ($ENV{SHM_ROOT_DIR} || '/app') . '/data/epay';
    my $uid = _storage_uid();
    payment_error "易支付机密目录必须由服务账号访问\n" unless $> == 0 || $> == $uid;
    make_path($path, { mode => 0700 }) unless -e $path || -l $path;
    my @stat = lstat($path);
    payment_error "易支付机密目录权限无效\n" unless @stat && S_ISDIR($stat[2]) && !S_ISLNK($stat[2])
        && ($stat[4] == $uid || ($> == 0 && $stat[4] == 0)) && ($stat[2] & 0777) == 0700;
    chown($uid, -1, $path) == 1 or payment_error "无法初始化易支付机密目录\n" if $> == 0;
    return $path;
}
sub _secure_file {
    my ($fh) = @_;
    my @stat = stat($fh);
    my $uid = _storage_uid();
    payment_error "易支付机密文件权限无效\n" unless S_ISREG($stat[2]) && $stat[3] == 1
        && ($stat[2] & 0777) == 0600 && ($stat[4] == $uid || ($> == 0 && $stat[4] == 0));
    chown($uid, -1, $fh) == 1 or payment_error "无法初始化易支付机密文件\n" if $> == 0;
}
sub _has_encrypted_orders {
    my ($self) = @_;
    return $self->dbh->selectrow_array(q{SELECT COUNT(*) FROM epay_orders WHERE JSON_EXTRACT(profile_config,'$.credential_box') IS NOT NULL});
}
sub _key {
    my ($self) = @_;
    my $dir = $self->_directory;
    sysopen(my $lock, "$dir/key.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600) or payment_error "无法打开易支付密钥锁\n";
    _secure_file($lock);
    flock($lock, LOCK_EX) or payment_error "无法锁定易支付密钥\n";
    my $path = "$dir/key";
    unless (-e $path || -l $path) {
        payment_error "易支付订单加密密钥缺失，请恢复应用数据卷\n" if $self->_has_encrypted_orders;
        my $temp = "$path." . unpack('H*', random_bytes(12));
        sysopen(my $out, $temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or payment_error "无法创建易支付密钥\n";
        binmode $out;
        my $ok = eval {
            _secure_file($out);
            print {$out} random_bytes(32) or payment_error "无法写入易支付密钥\n";
            $out->sync or payment_error "无法同步易支付密钥\n";
            close($out) or payment_error "无法关闭易支付密钥\n";
            rename($temp, $path) or payment_error "无法发布易支付密钥\n";
            sysopen(my $directory, $dir, O_RDONLY | O_NOFOLLOW) or payment_error "无法打开易支付机密目录\n";
            $directory->sync or payment_error "无法同步易支付机密目录\n";
            close $directory;
            1;
        };
        unless ($ok) { close $out; unlink $temp; payment_error "无法初始化易支付密钥\n" }
    }
    sysopen(my $in, $path, O_RDONLY | O_NOFOLLOW) or payment_error "无法读取易支付密钥\n";
    _secure_file($in);
    binmode $in;
    my $key = do { local $/; <$in> };
    close $in;
    payment_error "易支付加密密钥无效\n" unless defined $key && length($key) == 32;
    return $key;
}
sub _aad {
    my ($row, $snapshot) = @_;
    my %public = map { $_ => $snapshot->{$_} } grep { $_ ne 'credential_box' } keys %$snapshot;
    my %identity = map { $_ => defined $row->{$_} ? "$row->{$_}" : '' }
        qw(out_trade_no user_id profile protocol pid key_version gateway_id amount_cents currency payment_type);
    return 'SHM:epay:credentials:1:' . _json({ identity => \%identity, profile => \%public });
}
sub _seal_profile {
    my ($self, $row, $snapshot, $credentials) = @_;
    my %secret = map { $_ => $credentials->{$_} } grep { defined $credentials->{$_} }
        qw(md5_key merchant_private_key platform_public_key);
    my $box = encrypt_aes256_gcm_base64(_json(\%secret), $self->_key, _aad($row, $snapshot));
    payment_error "无法加密易支付订单凭据\n" unless $box;
    return { %$snapshot, credential_box => $box };
}
sub _frozen_profile {
    my ($self, $order) = @_;
    my $snapshot = _decode($order->{profile_config});
    payment_error "易支付订单配置损坏\n" unless sha256_hex(_json($snapshot)) eq $order->{config_fingerprint}
        && $snapshot->{protocol} eq $order->{protocol} && $snapshot->{pid} eq $order->{pid}
        && $snapshot->{key_version} eq $order->{key_version};
    payment_error "易支付订单缺少加密凭据\n" unless exists $snapshot->{credential_box};
    my $secret = _decode(decrypt_aes256_gcm_base64($snapshot->{credential_box}, $self->_key, _aad($order, $snapshot)));
    payment_error "易支付订单凭据损坏\n" unless ref $secret eq 'HASH';
    return { %$snapshot, %$secret };
}

# Called only by the trusted local module installer before the API becomes
# healthy. Order tables and credentials are initialized for this module.
sub _install_schema {
    my ($self) = @_;
    my $path = ($ENV{SHM_ROOT_DIR} || '/app') . '/pay_systems/epay.sql';
    open(my $file, '<:raw', $path) or payment_error "无法读取易支付模块数据结构\n";
    my $sql = do { local $/; <$file> };
    close $file;
    payment_error "易支付模块数据结构无效\n" unless defined $sql && length($sql) && length($sql) <= 131072;
    my $dbh = $self->dbh;
    local $dbh->{RaiseError} = 1;
    local $dbh->{PrintError} = 0;
    my $installed = eval { $dbh->do($sql) };
    payment_error "无法初始化易支付模块数据结构，请检查数据库\n" unless defined $installed;
    return 1;
}
sub initialize {
    my ($self) = @_;
    $self->_install_schema;
    $self->_directory;
    $self->_key;
    return { ready => 1 };
}

sub _order {
    my ($self, $id, $lock) = @_;
    payment_error "易支付订单号无效\n" unless defined $id && $id =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    my $row = $self->dbh->selectrow_hashref(
        'SELECT * FROM epay_orders WHERE out_trade_no = ?' . ($lock ? ' FOR UPDATE' : ''), undef, $id);
    payment_error "易支付订单不存在\n" unless $row;
    return $row;
}

sub _authorized_order {
    my ($self, $id) = @_;
    my $row = $self->_order($id);
    my $actor = $self->_actor;
    payment_error "无权操作此支付订单\n" unless $actor && ($actor->is_admin || $actor->id == $row->{user_id});
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
    payment_error "易支付需要事务数据库连接\n" if $dbh->{AutoCommit};
    local $dbh->{RaiseError} = 1;
    local $dbh->{PrintError} = 0;
    my $result;
    my $ok = eval {
        $result = $code->();
        # Do not use the test-mode shortcut in Core::Sql::Data::commit: an ACK
        # must never mean a transaction that has not actually committed.
        $dbh->commit or payment_error "易支付事务提交失败\n";
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
    payment_error "易支付资金与任务表必须全部使用 InnoDB\n"
        if grep { ($engines{$_} // '') ne 'InnoDB' } @tables;
}

sub _safe_error {
    my ($error) = @_;
    return blessed($error) && $error->isa('SHM::Pay::Epay::Protocol::Error')
        ? $error->{message} : '易支付处理失败，请联系管理员';
}
sub _guard {
    my ($self, $code) = @_;
    my $result = eval { $code->() };
    if ($@) {
        report->add_error(_safe_error($@));
        return undef;
    }
    return $result;
}

sub create_order {
    my ($self, %args) = @_;
    return $self->_guard(sub {
        payment_error "支付事务不支持 dry_run\n" if $args{dry_run};
        my $actor = $self->_actor;
        payment_error "需要登录后发起支付\n" unless $actor && $actor->id && !$actor->is_blocked;
        payment_error "易支付仅支持人民币账户\n" unless $self->_billing_currency eq 'CNY';
        my $name = $args{ps} // 'epay';
        my $current = $self->_profile($name);
        payment_error "易支付已停用\n" if exists $current->{enabled} && !$current->{enabled};
        payment_error "此支付通道未向客户开放\n" if !$actor->is_admin && exists $current->{show_for_client} && !$current->{show_for_client};
        my $amount = money_to_cents($args{amount});
        my $frozen = $self->_public_profile($name, $current, exists $args{type} ? (type => $args{type}) : ());
        if ($frozen->{checkout} eq 'api' && !defined $frozen->{type}) {
            return { need_payment_type => 1, profile => $name, amount => cents_to_money($amount),
                action => $frozen->{protocol} eq 'v1_md5' ? 'mapi' : 'create' };
        }
        my $credentials = $self->_configured_credentials($current);
        $frozen->{key_version} = 'auto_' . unpack('H*', random_bytes(16));
        my $id = 'shm_' . unpack('H*', random_bytes(16));
        my $row = {
            out_trade_no => $id, user_id => $actor->id, profile => $name,
            protocol => $frozen->{protocol}, pid => $frozen->{pid}, key_version => $frozen->{key_version},
            amount_cents => $amount, currency => 'CNY', payment_type => $frozen->{type},
            gateway_id => substr(sha256_hex($frozen->{api_url}), 0, 32),
            profile_config => _json($frozen), config_fingerprint => sha256_hex(_json($frozen)),
        };
        $frozen = $self->_seal_profile($row, $frozen, $credentials);
        $row->{profile_config} = _json($frozen);
        $row->{config_fingerprint} = sha256_hex($row->{profile_config});
        my $profile = { %$frozen, %$credentials };
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
        my $checkout = eval { $self->_checkout($row, $profile) };
        if ($@) {
            my $error = _safe_error($@);
            return { %{ $self->_display_order($self->_order($id)) }, checkout_error => $error };
        }
        return { %{ $self->_display_order($self->_order($id)) }, %$checkout };
    });
}

sub _http {
    my ($self, $url, $params, $profile) = @_;
    require URI;
    my $uri = URI->new($url);
    payment_error "易支付服务请求必须使用 HTTPS\n" unless ($uri->scheme // '') eq 'https'
        && $uri->can('host') && $uri->host && !defined $uri->userinfo && !defined $uri->fragment;
    return $self->{http_request}->($url, $params, $profile) if $self->{http_request};
    require LWP::UserAgent;
    require HTTP::Request;
    my $ua = LWP::UserAgent->new(timeout => $profile->{timeout} // 10,
        max_size => 131072, max_redirect => 0, ssl_opts => { verify_hostname => 1 });
    my $body = join('&', map { uri_escape_utf8($_) . '=' . uri_escape_utf8($params->{$_}) } sort keys %$params);
    my $request = HTTP::Request->new('POST', $url);
    $request->header('Content-Type' => 'application/x-www-form-urlencoded; charset=utf-8');
    $request->content($body);
    my $response = $ua->request($request);
    payment_error "易支付服务暂不可用，请查询订单后重试\n" unless $response->is_success;
    payment_error "易支付响应过大\n" if length($response->content) > 131072;
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
    my $checkout = SHM::Pay::Epay::Protocol::checkout_result($result, $profile);
    payment_error "易支付交易号无效\n" unless ($result->{trade_no} // '') =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    $self->_transaction(sub {
        my $locked = $self->_order($row->{out_trade_no}, 1);
        payment_error "易支付交易号不匹配\n" if $locked->{trade_no} && $locked->{trade_no} ne $result->{trade_no};
        $self->dbh->do('UPDATE epay_orders SET trade_no = ? WHERE out_trade_no = ?', undef,
            $result->{trade_no}, $row->{out_trade_no});
        return 1;
    });
    return $checkout;
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
        payment_error "支付事务不支持 dry_run\n" if $args{dry_run};
        my $row = $self->_authorized_order($args{out_trade_no});
        return $self->_display_order($row) if $row->{state} eq 'PAID';
        my $profile = $self->_frozen_profile($row);
        my $base = $profile->{api_url};
        $base =~ s{/+\z}{};
        my ($url, $params);
        if ($profile->{protocol} eq 'v2_rsa') {
            $url = "$base/api/pay/query";
            $params = SHM::Pay::Epay::Protocol::sign_request({ pid => $row->{pid},
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
        payment_error "支付订单用户不存在\n" unless $user_row;
        my $locked = $self->_order($row->{out_trade_no}, 1);
        validate_payment_evidence($params, $locked, $profile, mode => $source, allow_paid_replay => 1);
        return $self->_display_order($locked) if $locked->{state} eq 'PAID';
        payment_error "支付订单状态无效\n" unless $locked->{state} eq 'PENDING';
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
        payment_error "支付入账失败\n" unless $payment && $payment->{id} && report->is_success;
        payment_error "支付流水绑定不匹配\n" unless $payment->{user_id} == $locked->{user_id}
            && money_to_cents($payment->{money}) == $locked->{amount_cents};
        $self->dbh->do('UPDATE epay_orders SET state = ?, trade_no = ?, payment_id = ?, paid_at = CURRENT_TIMESTAMP WHERE out_trade_no = ?',
            undef, 'PAID', $params->{trade_no}, $payment->{id}, $locked->{out_trade_no});
        # User.payment inserts the PAYMENT spool event. Never call the VPN API
        # here: payment delivery and entitlement delivery have separate retries.
        return $self->_display_order($self->_order($locked->{out_trade_no}));
    });
}

1;
