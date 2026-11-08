#!/usr/bin/perl
use v5.14;
use strict;
use warnings;
use utf8;
use lib (($ENV{SHM_ROOT_DIR} || '/app') . '/pay_systems/lib');
use SHM qw(print_header print_json);
use SHM::Pay::Epay;
use Core::Sql::Data ();
use Core::System::ServiceManager qw(get_service);
use Core::Utils qw(parse_args html_escape encode_utf8 qrencode random_bytes switch_user);
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape_utf8);

if (!$ENV{REQUEST_METHOD} && @ARGV == 1 && $ARGV[0] eq '--install') {
    # Bootstrap before the HTTP server and its log reader are running. SHM->new
    # opens /tmp/shm_log for CGI requests and can block on a stale FIFO after a
    # container restart; the trusted installer only needs a database context.
    binmode STDERR, ':encoding(UTF-8)';
    my $dbh;
    my $ok = eval {
        my $config = get_service('config');
        $dbh = Core::Sql::Data::db_connect(%{ $config->file->{config}{database} })
            or die "无法连接数据库\n";
        $config->local('dbh', $dbh);
        switch_user(1);
        SHM::Pay::Epay->new->initialize();
        $dbh->commit or die "本地支付模块初始化提交失败\n";
        $dbh->disconnect;
        1;
    };
    unless ($ok) {
        eval { $dbh->rollback } if $dbh;
        eval { $dbh->disconnect } if $dbh;
        print STDERR "本地支付模块初始化失败，请保留已有密钥和订单并检查配置。\n";
        exit 1;
    }
    exit 0;
}

local %Core::Utils::response_headers = (
    'Cache-Control' => 'no-store', 'Pragma' => 'no-cache',
    'Referrer-Policy' => 'no-referrer', 'X-Content-Type-Options' => 'nosniff',
);
my %params = parse_args();
my $action = delete $params{action} // 'submit';
# Creation actions identify the request, while the configured channel selects
# the gateway endpoint. A browser cannot override the administrator's mode.
$action = 'create' if $action eq 'submit' || $action eq 'mapi';
my ($epay, $result);
my $ok = eval {
    die "支付事务不支持 dry_run\n" if $params{dry_run};
    if ($action eq 'notify' || $action eq 'return') { SHM->new(skip_check_auth => 1) }
    else { SHM->new() }
    $epay = SHM::Pay::Epay->new;
    if ($action eq 'notify') { $result = $epay->process_notification(\%params) }
    elsif ($action eq 'return') { $result = $epay->return_status($params{out_trade_no}) }
    elsif ($action eq 'create') {
        $result = $epay->create_order(amount => $params{amount}, ps => $params{ps} // 'epay',
            exists($params{type}) ? (type => $params{type}) : ());
        die "下单失败\n" unless $result;
    } elsif ($action eq 'query') {
        $result = $epay->reconcile(out_trade_no => $params{out_trade_no});
        die "查单失败\n" unless $result;
    } elsif ($action eq 'status') {
        $result = $epay->status(out_trade_no => $params{out_trade_no});
        die "查询失败\n" unless $result;
    } else { die "不支持的支付操作\n" }
    1;
};

if ($action eq 'notify') {
    print_header(status => $ok ? 200 : 503, type => 'text/plain');
    print $ok ? 'success' : 'fail';
    exit 0;
}
unless ($ok) {
    my ($error) = get_service('report')->errors;
    print_header(status => 400);
    print_json({ error => $error // '支付处理失败，请联系管理员' });
    exit 0;
}
sub page {
    my ($title, $body, $script) = @_;
    my $nonce = unpack('H*', random_bytes(16));
    print_header(type => 'text/html',
        'Content-Security-Policy' => "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'nonce-$nonce'; form-action https: 'self'; base-uri 'none'; frame-ancestors 'none'");
    print encode_utf8('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'
        . html_escape($title) . '</title><style>body{font:16px system-ui;max-width:32rem;margin:3rem auto;padding:1rem;line-height:1.6}button,a{margin:.5rem .5rem .5rem 0}img{max-width:100%}</style><h1>'
        . html_escape($title) . '</h1>' . $body
        . ($script ? '<script nonce="' . $nonce . '">' . $script . '</script>' : '') . '</html>');
}
if ($action eq 'return') {
    page('付款结果', '<p>' . ($result->{state} eq 'PAID' ? '付款已确认，请返回用户中心查看余额。' : '付款尚未确认，请稍后在用户中心查询原订单。') . '</p>');
} elsif ($action eq 'create' && $result->{need_payment_type}) {
    page('选择支付方式', '<form method="post" action="/shm/pay_systems/epay.cgi"><input type="hidden" name="action" value="'
        . html_escape($result->{action}) . '"><input type="hidden" name="ps" value="'
        . html_escape($result->{profile}) . '"><input type="hidden" name="amount" value="'
        . html_escape($result->{amount}) . '"><p>充值金额：' . html_escape($result->{amount})
        . ' 元</p><button name="type" value="alipay">支付宝</button><button name="type" value="wxpay">微信支付</button></form>');
} elsif ($action eq 'create' && $result->{checkout_error}) {
    page('支付请求待确认', '<p>' . html_escape($result->{checkout_error}) . '</p><p>订单号：'
        . html_escape($result->{out_trade_no}) . '</p><p><a href="/shm/pay_systems/epay.cgi?action=query&amp;out_trade_no='
        . uri_escape_utf8($result->{out_trade_no}) . '">查询原订单</a></p>');
} elsif ($action eq 'create' && $result->{checkout_url}) {
    print_header(status => 303, location => $result->{checkout_url});
} elsif ($action eq 'create' && $result->{checkout_request}) {
    my $request = $result->{checkout_request};
    my $form = '<form id="epay" method="post" action="' . html_escape($request->{url}) . '">';
    for my $name (sort keys %{ $request->{fields} }) {
        $form .= '<input type="hidden" name="' . html_escape($name) . '" value="' . html_escape($request->{fields}{$name}) . '">';
    }
    page('前往支付', $form . '<button type="submit">前往支付</button></form>', 'document.getElementById("epay").submit()');
} elsif ($action eq 'create' && ($result->{checkout_qrcode} || $result->{checkout_scheme})) {
    my $body = '<p>订单号：' . html_escape($result->{out_trade_no}) . '</p>';
    if ($result->{checkout_qrcode}) {
        my $qr = qrencode($result->{checkout_qrcode}, format => 'PNG');
        if ($qr->{success}) { $body .= '<img alt="付款二维码" src="data:image/png;base64,' . encode_base64($qr->{data}, '') . '">' }
        else { $body .= '<p>二维码生成失败，请查询原订单后重试。</p>' }
    } else {
        $body .= '<p><a href="' . html_escape($result->{checkout_scheme}) . '">打开支付应用</a></p>';
    }
    $body .= '<p><a href="/shm/pay_systems/epay.cgi?action=query&amp;out_trade_no=' . uri_escape_utf8($result->{out_trade_no}) . '">查询付款结果</a></p>';
    page('完成付款', $body);
} else { print_json($result) }
exit 0;
