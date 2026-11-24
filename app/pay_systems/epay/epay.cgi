#!/usr/bin/perl
use v5.14;
use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use SHM qw(get_service);
use Core::Utils qw(parse_args html_escape get_cookies print_header encode_utf8);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use MIME::Base64 qw(encode_base64);
use URI;
use SHM::Pay::Epay;
use SHM::Pay::Epay::Channels qw(settings change);

sub respond {
    my ($status, $type, $content) = @_;
    print_header(status => $status, type => $type, 'Cache-Control' => 'no-store', 'Referrer-Policy' => 'no-referrer',
        'Access-Control-Allow-Origin' => '', 'Access-Control-Allow-Credentials' => 'false', 'X-Content-Type-Options' => 'nosniff');
    print $type eq 'application/json' ? JSON::PP->new->utf8->encode($content) : encode_utf8($content);
}
sub page {
    my ($content) = @_;
    respond(200, 'text/html', '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>易支付</title><body>'.$content.'</body></html>');
}
sub hidden_fields {
    my ($f) = @_;
    return join '', map { '<input type="hidden" name="'.html_escape($_).'" value="'.html_escape($f->{$_}).'">' } sort keys %$f;
}
sub render_checkout {
    my ($result) = @_;
    if ($result->{choose}) {
        my %fields = map { $_ => $result->{$_} } qw(action amount ps);
        return page('<form method="post">'.hidden_fields(\%fields).'<button name="type" value="alipay">支付宝</button> <button name="type" value="wxpay">微信支付</button></form>');
    }
    if (my $form = $result->{form}) {
        return page('<form id="checkout" method="post" action="'.html_escape($form->{url}).'">'.hidden_fields($form->{fields}).
            '<button>前往付款</button></form><script>document.getElementById("checkout").submit()</script>');
    }
    if (my $href = $result->{checkout_url} || $result->{checkout_scheme}) {
        return page('<a href="'.html_escape($href).'">前往付款</a>');
    }
    if (my $payload = $result->{checkout_qrcode}) {
        my $qr = Core::Utils::qrencode($payload);
        die "QR unavailable\n" unless length($qr->{data} // '');
        return page('<img alt="付款二维码" src="data:image/png;base64,'.encode_base64($qr->{data}, '').'">');
    }
    return page('等待支付平台确认。订单号 '.html_escape($result->{out_trade_no}));
}
sub private_settings {
    my ($gateway, $params, $method) = @_;
    my $denied = sub { respond(403, 'application/json', {error => '当前请求无权访问支付设置。'}) };
    return $denied->() if ($ENV{HTTP_SEC_FETCH_SITE} // '') =~ /\A(?:cross-site|same-site)\z/;
    if (length(my $origin = $ENV{HTTP_ORIGIN} // '')) {
        my $scheme = ($ENV{HTTP_X_FORWARDED_PROTO} // '') eq 'https' || ($ENV{HTTPS} // '') =~ /^(?:on|1)$/i ? 'https' : 'http';
        return $denied->() unless lc($origin) eq lc($scheme.'://'.($ENV{HTTP_HOST} // '')) ||
            ($ENV{HTTP_SEC_FETCH_SITE} // '') eq 'same-origin';
    }
    my $sid = get_cookies('session_id');
    SHM::db_connect();
    my $session = $sid && SHM::validate_session(session_id => $sid);
    return respond(401, 'application/json', {error => '请先登录管理端。'}) unless $session;
    my $admin = get_service('user', _id => $session->user_id);
    my $login = SHM::login_from_session($session);
    return $denied->() if !$admin || (!$login && $session->get_settings->{account});
    Core::Utils::switch_user($admin->id);
    local $admin->{login} = $login;
    return $denied->() unless $admin->is_admin && $admin->can_access(uri => '/admin/config', method => 'POST');
    my $nonce = hmac_sha256_hex('epay-settings/'.$admin->id, $sid);
    return respond(200, 'application/json', {%{settings($gateway->dbh)}, nonce => $nonce}) if $method eq 'GET';
    return $denied->() unless $method eq 'POST' && ($params->{nonce} // '') eq $nonce && !$ENV{HTTP_TEST} && !$ENV{SHM_TEST}
        && ($ENV{CONTENT_TYPE} // '') =~ m{\Aapplication/x-www-form-urlencoded(?:;|\z)}i;
    my %known = map { $_ => 1 } qw(profile operation nonce fields name type custom_type show_for_client checkout apiurl pid
        sign_type key merchant_private_key platform_public_key);
    die "Invalid form\n" if grep { !$known{$_} } keys %$params;
    return respond(200, 'application/json', $gateway->transaction(sub { change($_[0], $params) }));
}
my ($callback) = ($ENV{SCRIPT_NAME} // '') =~ m{/epay_(notify|return)\.cgi\z};
my %url = URI->new('?'.($ENV{QUERY_STRING} // ''))->query_form;
my $action = $callback // $url{action} // '';
my $method = $ENV{REQUEST_METHOD} // '';
my $ok = eval {
    die "Invalid request\n" unless $method eq 'GET' || $method eq 'POST';
    die "Oversized request\n" if ($ENV{CONTENT_LENGTH} // 0) > 65536;
    my %input = parse_args(auto_parse_json => 0);
    for (values %input) {
        die "Invalid request value\n" if !defined || ref || index($_, "\0") >= 0;
        $_ = decode('UTF-8', $_, FB_CROAK | LEAVE_SRC) if $method eq 'POST' && !utf8::is_utf8($_);
    }
    $action ||= $input{action} || 'submit';
    my $gateway = SHM::Pay::Epay->new;
    if ($action eq 'settings') {
        private_settings($gateway, \%input, $method);
    } elsif ($action eq 'notify') {
        SHM->new(user_id => 1);
        die "Test request\n" if $ENV{SHM_TEST} || $input{dry_run};
        $gateway->settle($input{out_trade_no}, \%input, 1);
        respond(200, 'text/plain', 'success');
    } elsif ($action eq 'return') {
        SHM->new(user_id => 1);
        my $row = SHM::Pay::Epay::order($gateway->dbh, $input{out_trade_no}, 0);
        page($row->{state} eq 'PAID' ? '款项已到账' : '订单待支付或待确认');
    } else {
        my $actor = SHM->new();
        die "Test request\n" if ($ENV{SHM_TEST} || $input{dry_run}) && $action ne 'status';
        if ($action eq 'query' || $action eq 'status') {
            respond(200, 'application/json', $gateway->status($actor, $input{out_trade_no}, $action eq 'query'));
        } elsif ($action =~ /\A(?:submit|create|mapi)\z/) {
            render_checkout($gateway->checkout($actor, {%input, action => $action}));
        } else { die "Unknown payment action\n" }
    }
    1;
};
unless ($ok) {
    if ($action eq 'settings') { respond(400, 'application/json', {error => '无法读取或保存易支付设置，请核对商户资料。'}) }
    else { respond(400, 'text/plain', $action eq 'notify' ? 'fail' : '易支付处理失败，请核对订单或联系管理员。') }
}
