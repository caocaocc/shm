#!/usr/bin/perl

use v5.14;
use strict;
use warnings;
use utf8;
use SHM qw(print_header print_json);
use Core::System::ServiceManager qw(get_service);
use Core::Utils qw(parse_args html_escape encode_utf8);

my %params = parse_args();
my $action = delete $params{action} // 'create';
my $epay;
my $result;
my $ok = eval {
    die "支付事务不支持 dry_run\n" if $params{dry_run};
    # Public callbacks need a DB connection but not a customer session. Every
    # financial callback is authenticated against the order's frozen protocol.
    SHM->new(skip_check_auth => 1) if $action eq 'notify' || $action eq 'return';
    SHM->new() unless $action eq 'notify' || $action eq 'return';
    $epay = get_service('epay');
    if ($action eq 'notify') {
        $result = $epay->process_notification(\%params);
    } elsif ($action eq 'return') {
        $result = $epay->return_status($params{out_trade_no});
    } elsif ($action eq 'create') {
        # Ignore legacy user_id query arguments: only the authenticated user
        # becomes the immutable owner of a pending top-up order.
        $result = $epay->create_order(amount => $params{amount}, ps => $params{ps} // 'epay');
        die "下单失败\n" unless $result;
    } elsif ($action eq 'query') {
        $result = $epay->reconcile(out_trade_no => $params{out_trade_no});
        die "查单失败\n" unless $result;
    } else {
        die "不支持的支付操作\n";
    }
    1;
};

if ($action eq 'notify') {
    # process_notification has committed the payment + durable PAYMENT task.
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

if ($action eq 'return') {
    print_header(type => 'text/html');
    my $text = $result->{state} eq 'PAID' ? '付款已确认，权益交付由服务任务处理。' : '付款尚未确认，请稍后在账户中查询。';
    print encode_utf8('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>付款结果</title><p>' . $text . '</p></html>');
} elsif ($action eq 'create' && $result->{checkout_url}) {
    print_header(status => 303, location => $result->{checkout_url});
} elsif ($action eq 'create' && $result->{checkout_request}) {
    my $request = $result->{checkout_request};
    my $html = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>前往支付</title>'
        . '<form id="epay" method="post" action="' . html_escape($request->{url}) . '">';
    for my $name (sort keys %{ $request->{fields} }) {
        $html .= '<input type="hidden" name="' . html_escape($name) . '" value="'
            . html_escape($request->{fields}->{$name}) . '">';
    }
    $html .= '<button type="submit">前往支付</button></form><script>document.getElementById("epay").submit()</script></html>';
    print_header(type => 'text/html');
    print encode_utf8($html);
} else {
    print_json($result);
}

exit 0;
