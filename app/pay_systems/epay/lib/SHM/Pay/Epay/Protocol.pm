package SHM::Pay::Epay::Protocol;
use v5.14;
use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use URI;
use Exporter 'import';
our @EXPORT_OK = qw(canonical_string money_to_cents cents_to_money gateway_url sign_request verify_signature
    verify_notification match_payment build_payment_request decode_response checkout_result rsa_key);

sub money_to_cents {
    my ($value) = @_;
    my ($yuan, $fraction) = defined($value) && !ref($value) ?
        $value =~ /\A(0|[1-9][0-9]{0,7})(?:\.([0-9]{1,2}))?\z/ : ();
    die "Invalid payment amount\n" unless defined $yuan;
    my $result = $yuan * 100 + substr(($fraction // '').'00', 0, 2);
    die "Invalid payment amount\n" unless $result;
    return $result;
}
sub cents_to_money { sprintf '%d.%02d', int($_[0] / 100), $_[0] % 100 }

sub gateway_url {
    my ($source) = @_;
    die "Invalid HTTPS gateway\n" unless defined($source) && !ref($source)
        && $source =~ m{\Ahttps://[^/?#\s\\@]+(?:/[^?#\s\\]*)?\z}i;
    my $uri = URI->new($source)->canonical;
    die "Invalid HTTPS gateway\n" unless $uri->host && !$uri->userinfo && $uri->port > 0 && $uri->port <= 65535;
    my $base = $uri->as_string;
    $base =~ s{/+\z}{};
    return $base;
}

sub canonical_string {
    my ($fields, $protocol) = @_;
    my $rsa = ($protocol // $fields->{sign_type} // '') =~ /\A(?:RSA|v2_rsa)\z/;
    my @pairs = map { "$_=$fields->{$_}" } grep {
        $_ ne 'sign' && $_ ne 'sign_type' && defined($fields->{$_}) && !ref($fields->{$_})
            && length($fields->{$_}) && (!$rsa || $fields->{$_} =~ /[^\x00\x09-\x0b\x0d\x20]/)
    } sort keys %$fields;
    return encode('UTF-8', join '&', @pairs);
}

sub rsa_key {
    my ($text, $private) = @_;
    require Crypt::PK::RSA;
    die "Invalid RSA key\n" if !defined($text) || ref($text);
    if ($text !~ /\A\s*-----BEGIN /) {
        $text =~ s/\s+//g;
        my $der = decode_base64($text);
        die "Invalid RSA key\n" unless length($der) && encode_base64($der, '') eq $text;
        $text = $der;
    }
    my $key = Crypt::PK::RSA->new(\$text);
    die "Wrong RSA key type\n" unless !!$key->is_private == !!$private;
    return $key;
}
sub label {
    return 'MD5' if $_[0] eq 'v1_md5';
    return 'RSA' if $_[0] eq 'v2_rsa';
    die "Unknown payment protocol\n";
}
sub sign_request {
    my ($fields, $merchant) = @_;
    my $kind = label($merchant->{protocol});
    my $message = canonical_string($fields, $merchant->{protocol});
    my $signature = $kind eq 'MD5' ? md5_hex($message.encode('UTF-8', $merchant->{md5_key})) :
        encode_base64(rsa_key($merchant->{merchant_private_key}, 1)->sign_message($message, 'SHA256', 'v1.5'), '');
    return { %$fields, sign => $signature, sign_type => $kind };
}
sub verify_signature {
    my ($fields, $merchant) = @_;
    my $sig = $fields->{sign} // '';
    return 0 unless length($sig) && !ref($sig) && ($fields->{sign_type} // '') eq label($merchant->{protocol});
    if ($fields->{sign_type} eq 'MD5') {
        my $want = sign_request($fields, $merchant)->{sign};
        return $sig =~ /\A[0-9a-fA-F]{32}\z/ && (lc($sig) ^ $want) !~ /[^\0]/;
    }
    my $raw = decode_base64($sig);
    return 0 unless encode_base64($raw, '') eq $sig;
    return eval { rsa_key($merchant->{platform_public_key}, 0)->verify_message(
        $raw, canonical_string($fields, $merchant->{protocol}), 'SHA256', 'v1.5') } || 0;
}
sub signed_at {
    my ($data, $profile, $allow_old, $now) = @_;
    die "Invalid signature\n" unless verify_signature($data, $profile);
    return if $profile->{protocol} ne 'v2_rsa';
    my $time = $data->{timestamp} // '';
    die "Invalid timestamp\n" unless $time =~ /\A[0-9]{10}\z/ && ($allow_old || abs($now - $time) <= 300);
}
sub verify_notification {
    my ($data, $order, $profile, %args) = @_;
    signed_at($data, $profile, $args{allow_paid_replay} && ($order->{state} // '') eq 'PAID', $args{now} // time);
    die "Payment incomplete\n" unless ($data->{trade_status} // '') eq 'TRADE_SUCCESS';
}
sub match_payment {
    my ($evidence, $row, $merchant) = @_;
    die "Order mismatch\n" unless $row->{currency} eq 'CNY' && ($evidence->{currency} // 'CNY') eq 'CNY'
        && ($evidence->{pid} // '') eq $row->{pid} && ($evidence->{out_trade_no} // '') eq $row->{out_trade_no}
        && money_to_cents($evidence->{money}) == $row->{amount_cents};
    my $trade = $evidence->{trade_no} // '';
    die "Trade mismatch\n" unless $trade =~ /\A[A-Za-z0-9_.-]{1,64}\z/ && ($row->{trade_no} // $trade) eq $trade;
    die "Payment channel mismatch\n" if defined($row->{payment_type}) && ($evidence->{type} // '') ne $row->{payment_type};
    return $trade;
}

sub build_payment_request {
    my ($row, $config, %args) = @_;
    my $page = ($args{flow} // 'create') eq 'submit';
    my $rsa = label($config->{protocol}) eq 'RSA';
    my $url = gateway_url($config->{api_url});
    my %form = (pid => $row->{pid}, out_trade_no => $row->{out_trade_no}, name => '账户充值',
        money => cents_to_money($row->{amount_cents}), notify_url => $config->{notify_url}, return_url => $config->{return_url});
    $form{type} = $row->{payment_type} if defined $row->{payment_type};
    $form{timestamp} = $args{now} // time if $rsa;
    unless ($page) {
        $form{$rsa ? 'method' : 'device'} = 'jump';
        $form{clientip} = $args{clientip} // '127.0.0.1';
    }
    my $path = $page ? ($rsa ? 'api/pay/submit' : 'submit.php') : ($rsa ? 'api/pay/create' : 'mapi.php');
    return {url => "$url/$path", fields => sign_request(\%form, $config)};
}
sub decode_response {
    my ($reply, $profile, %args) = @_;
    my $rsa = label($profile->{protocol}) eq 'RSA';
    die "Gateway rejected order\n" unless ref($reply) eq 'HASH' && ($reply->{code} // '') eq ($rsa ? '0' : '1');
    signed_at($reply, $profile, 0, $args{now} // time) if $rsa;
    return $reply;
}
sub checkout_result {
    my ($reply, $merchant) = @_;
    my ($mode, $target) = @{$reply}{qw(pay_type pay_info)};
    if (label($merchant->{protocol}) eq 'MD5') {
        my @provided = grep { length($reply->{$_} // '') } qw(payurl qrcode urlscheme);
        die "Invalid checkout response\n" unless @provided == 1;
        $mode = $provided[0];
        $target = $reply->{$mode};
    }
    my %keys = (jump => 'checkout_url', payurl => 'checkout_url', qrcode => 'checkout_qrcode', urlscheme => 'checkout_scheme');
    my $key = $keys{$mode // ''} or die "Invalid checkout type\n";
    die "Invalid checkout target\n" unless defined($target) && !ref($target) && length($target) <= 4096 && $target !~ /[\x00-\x20\x7f\\]/;
    my $uri = URI->new($target);
    my $web = ($uri->scheme // '') =~ /\Ahttps\z/i && $uri->can('host') && $uri->host && !defined($uri->userinfo);
    my $app = $target =~ m{\A(?:weixin|alipays)://[^\s/?#]+}i;
    die "Invalid checkout URL\n" unless ($web && $key ne 'checkout_scheme') || ($app && $key ne 'checkout_url');
    return {$key => $target};
}
1;
