package Core::Pay::Epay;

use v5.14;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use Encode qw(encode is_utf8);
use JSON::PP ();

our @EXPORT_OK = qw(canonical_string money_to_cents cents_to_money
    sign_request verify_signature validate_notification validate_payment_evidence
    build_payment_request decode_response protocol_sign_type);

sub protocol_sign_type {
    my ($protocol) = @_;
    return 'RSA' if defined $protocol && $protocol eq 'v2_rsa';
    return 'MD5' if defined $protocol && $protocol eq 'v1_md5';
    die "不支持的易支付协议\n";
}

# Sign the original values, before form encoding; zero is not an empty value.
sub canonical_string {
    my ($params) = @_;
    die "易支付参数必须为对象\n" unless ref $params eq 'HASH';
    my @parts;
    for my $key (sort keys %$params) {
        next if $key eq 'sign' || $key eq 'sign_type';
        my $value = $params->{$key};
        next if !defined $value || ref $value || $value eq '';
        die "易支付参数名称无效\n" unless $key =~ /\A[A-Za-z0-9_.-]+\z/;
        my $part = "$key=$value";
        push @parts, is_utf8($part) ? encode('UTF-8', $part) : $part;
    }
    return join('&', @parts);
}

sub money_to_cents {
    my ($money) = @_;
    die "支付金额必须为正数，最多两位小数\n"
        if !defined $money || ref $money || $money !~ /\A(0|[1-9][0-9]{0,7})(?:\.([0-9]{1,2}))?\z/;
    my ($whole, $fraction) = ($1, $2 // '');
    my $cents = $whole * 100 + int(substr($fraction . '00', 0, 2));
    die "支付金额必须大于零\n" unless $cents > 0;
    return $cents;
}

sub cents_to_money {
    my ($cents) = @_;
    die "支付金额无效\n" if !defined $cents || ref $cents || $cents !~ /\A[0-9]+\z/
        || $cents <= 0 || $cents > 9_999_999_999;
    return sprintf('%d.%02d', int($cents / 100), $cents % 100);
}

sub _rsa {
    my ($key) = @_;
    die "缺少易支付 RSA 密钥\n" unless defined $key && length $key;
    require Crypt::PK::RSA;
    return Crypt::PK::RSA->new(\$key);
}

sub sign_request {
    my ($params, $profile) = @_;
    my $kind = protocol_sign_type($profile->{protocol});
    my %signed = (%$params, sign_type => $kind);
    delete $signed{sign};
    my $message = canonical_string(\%signed);
    if ($kind eq 'RSA') {
        $signed{sign} = encode_base64(_rsa($profile->{merchant_private_key})
            ->sign_message($message, 'SHA256', 'v1.5'), '');
    } else {
        die "缺少易支付 MD5 密钥\n" unless defined $profile->{md5_key} && length $profile->{md5_key};
        $signed{sign} = md5_hex($message . $profile->{md5_key});
    }
    return \%signed;
}

sub verify_signature {
    my ($params, $profile) = @_;
    return 0 unless ref $params eq 'HASH' && defined $params->{sign} && !ref $params->{sign};
    my $kind = protocol_sign_type($profile->{protocol});
    return 0 unless defined $params->{sign_type} && $params->{sign_type} eq $kind;
    my $message = canonical_string($params);
    if ($kind eq 'RSA') {
        return 0 unless $params->{sign} =~ /\A[A-Za-z0-9+\/]+={0,2}\z/;
        my $result = eval { _rsa($profile->{platform_public_key})
            ->verify_message(decode_base64($params->{sign}), $message, 'SHA256', 'v1.5') };
        return $result ? 1 : 0;
    }
    return 0 unless defined $profile->{md5_key} && length $profile->{md5_key}
        && $params->{sign} =~ /\A[0-9a-f]{32}\z/;
    my $expected = md5_hex($message . $profile->{md5_key});
    my $difference = 0;
    $difference |= ord(substr($expected, $_, 1)) ^ ord(substr($params->{sign}, $_, 1)) for 0..31;
    return $difference == 0;
}

sub _timestamp {
    my ($params, $profile, $now, $allow_stale) = @_;
    return if $profile->{protocol} eq 'v1_md5';
    die "易支付通知时间戳无效或已过期\n" unless defined $params->{timestamp}
        && !ref $params->{timestamp} && $params->{timestamp} =~ /\A[0-9]{10}\z/;
    die "易支付通知时间戳无效或已过期\n" unless $allow_stale
        || abs(($now // time) - $params->{timestamp}) <= ($profile->{timestamp_skew} // 300);
}

sub validate_payment_evidence {
    my ($params, $order, $profile, %args) = @_;
    my $mode = $args{mode} // 'notify';
    die "订单协议不匹配\n" unless $order->{protocol} eq $profile->{protocol};
    die "订单币种不受支持\n" unless $order->{currency} eq 'CNY';
    if ($mode eq 'notify' || $profile->{protocol} eq 'v2_rsa') {
        die "易支付验签失败\n" unless verify_signature($params, $profile);
        # A replay may only acknowledge a payment that is already durably
        # PAID. It still authenticates every field below, and cannot settle a
        # PENDING order or bypass freshness of a server query response.
        my $paid_replay = $args{allow_paid_replay} && $mode eq 'notify'
            && ($order->{state} // '') eq 'PAID';
        _timestamp($params, $profile, $args{now}, $paid_replay);
    }
    if ($mode eq 'notify') {
        die "易支付交易未成功\n" unless ($params->{trade_status} // '') eq 'TRADE_SUCCESS';
    } elsif ($mode eq 'query') {
        my $code = $profile->{protocol} eq 'v2_rsa' ? 0 : 1;
        die "易支付订单未支付\n" unless defined $params->{code} && $params->{code} eq "$code"
            && defined $params->{status} && $params->{status} eq '1';
    } else {
        die "不支持的易支付凭证类型\n";
    }
    die "易支付商户不匹配\n" unless defined $params->{pid} && !ref $params->{pid}
        && $params->{pid} =~ /\A[0-9]+\z/ && $params->{pid} eq $order->{pid};
    die "易支付订单不匹配\n" unless ($params->{out_trade_no} // '') eq $order->{out_trade_no};
    die "易支付金额不匹配\n" unless money_to_cents($params->{money}) == $order->{amount_cents};
    die "易支付交易号无效\n" unless defined $params->{trade_no} && !ref $params->{trade_no}
        && $params->{trade_no} =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    die "易支付交易号不匹配\n" if $order->{trade_no} && $order->{trade_no} ne $params->{trade_no};
    die "易支付支付方式不匹配\n" if defined $order->{payment_type} && length $order->{payment_type}
        && ($params->{type} // '') ne $order->{payment_type};
    return { trade_no => $params->{trade_no}, amount_cents => 0 + $order->{amount_cents} };
}

sub validate_notification {
    my ($params, $order, $profile, %args) = @_;
    return validate_payment_evidence($params, $order, $profile, %args, mode => 'notify');
}

sub build_payment_request {
    my ($order, $profile, %args) = @_;
    my $base = $profile->{api_url} // '';
    die "易支付地址必须使用 HTTPS\n" unless $base =~ m{\Ahttps://[^/?#\s\@]+(?::[0-9]+)?(?:/[^?#\s]*)?\z};
    $base =~ s{/+\z}{};
    my $flow = $args{flow} // 'create';
    die "不支持的易支付下单方式\n" unless $flow eq 'create' || $flow eq 'submit';
    my %params = (
        pid => $order->{pid}, out_trade_no => $order->{out_trade_no},
        name => $profile->{payment_name} // '账户充值', money => cents_to_money($order->{amount_cents}),
        notify_url => $profile->{notify_url}, return_url => $profile->{return_url},
        defined $order->{payment_type} && length $order->{payment_type} ? (type => $order->{payment_type}) : (),
    );
    if ($profile->{protocol} eq 'v2_rsa') {
        $params{timestamp} = '' . ($args{now} // time);
        $params{method} = 'jump' if $flow eq 'create';
    } elsif ($profile->{protocol} eq 'v1_md5') {
        $params{device} = 'jump' if $flow eq 'create';
    } else { protocol_sign_type($profile->{protocol}); }
    $params{clientip} = $args{clientip} // '127.0.0.1' if $flow eq 'create';
    my $suffix = $profile->{protocol} eq 'v2_rsa' ? "/api/pay/$flow"
        : $flow eq 'create' ? '/mapi.php' : '/submit.php';
    return { url => $base . $suffix, fields => sign_request(\%params, $profile) };
}

sub decode_response {
    my ($payload, $profile, %args) = @_;
    my $data = ref $payload eq 'HASH' ? $payload : eval { JSON::PP->new->utf8->decode($payload) };
    die "易支付响应无效\n" unless ref $data eq 'HASH';
    protocol_sign_type($profile->{protocol});
    my $success = $profile->{protocol} eq 'v2_rsa' ? 0 : 1;
    die "易支付请求未成功\n" unless defined $data->{code} && !ref $data->{code} && $data->{code} eq "$success";
    if ($profile->{protocol} eq 'v2_rsa') {
        die "易支付响应验签失败\n" unless verify_signature($data, $profile);
        _timestamp($data, $profile, $args{now});
    }
    return $data;
}

1;
