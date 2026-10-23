use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use Digest::MD5 qw(md5_hex);
use Encode qw(encode);
use MIME::Base64 qw(decode_base64);
use Core::Pay::Epay qw(canonical_string money_to_cents cents_to_money
    sign_request verify_signature validate_notification validate_payment_evidence
    build_payment_request decode_response);

sub rejects {
    my ($code, $name) = @_;
    my $ok = eval { $code->(); 1 };
    ok(!$ok, $name);
}

my $now = time;
my $md5 = { protocol => 'v1_md5', pid => '1001', md5_key => 'epay-unit-test-key',
    api_url => 'https://pay.example.test', notify_url => 'https://bill.example.test/notify',
    return_url => 'https://bill.example.test/return' };
my $order = { out_trade_no => 'shm_test_001', pid => '1001', protocol => 'v1_md5',
    amount_cents => 1230, currency => 'CNY', payment_type => 'alipay' };
my $notify = { pid => '1001', out_trade_no => $order->{out_trade_no}, trade_no => '202610120000001',
    money => '12.30', type => 'alipay', trade_status => 'TRADE_SUCCESS', extension => '0' };

is(canonical_string({ z => 0, a => '中文 & = +', sign => 'ignored', sign_type => 'RSA',
    empty => '', omitted => undef, array => [1] }), encode('UTF-8', 'a=中文 & = +&z=0'),
    'sign original UTF-8 bytes, retain zero and separators, omit only excluded values');
is(money_to_cents('12.3'), 1230, 'yuan decimal becomes exact cents');
is(money_to_cents('0.01'), 1, 'smallest positive unit');
is(cents_to_money(1230), '12.30', 'outgoing money uses two decimal places');
is(money_to_cents('99999999.99'), 9999999999, 'decimal(10,2) upper boundary');
rejects(sub { money_to_cents($_) }, "reject invalid money $_") for qw(0 -1 1.234 1e2 NaN 100000000.00 01.00);

my $signed = sign_request($notify, $md5);
is($signed->{sign}, md5_hex('extension=0&money=12.30&out_trade_no=shm_test_001&pid=1001&trade_no=202610120000001&trade_status=TRADE_SUCCESS&type=alipayepay-unit-test-key'),
    'MD5 fixture uses original sorted fields and appends key, not an ampersand');
ok(verify_signature($signed, $md5), 'MD5 signed notification verifies');
is(validate_notification($signed, $order, $md5)->{amount_cents}, 1230, 'valid notification binds frozen amount');
ok(!verify_signature({ %$signed, extension => 1 }, $md5), 'signed extension tamper rejected');
ok(!verify_signature({ %$signed, sign_type => 'RSA2' }, $md5), 'unknown algorithm cannot downgrade to MD5');
for my $case ([money => '12.31'], [pid => '1002'], [out_trade_no => 'another'],
    [trade_status => 'TRADE_CLOSED'], [type => 'wxpay']) {
    my $bad = sign_request({ %$notify, @$case }, $md5);
    rejects(sub { validate_notification($bad, $order, $md5) }, "valid signature but mismatched $case->[0] rejected");
}
rejects(sub { validate_notification($signed, { %$order, currency => 'RUB' }, $md5) }, 'currency cannot be changed');
rejects(sub { validate_notification($signed, { %$order, trade_no => 'different' }, $md5) }, 'known platform order cannot be rebound');
my $v1request = build_payment_request($order, $md5);
is($v1request->{url}, 'https://pay.example.test/mapi.php', 'V1 API endpoint');
is($v1request->{fields}->{device}, 'jump', 'V1 jump device');
ok(!exists $v1request->{fields}->{timestamp}, 'V1 does not invent a timestamp field');
is(build_payment_request($order, $md5, flow => 'submit')->{url}, 'https://pay.example.test/submit.php', 'V1 page endpoint');
is(decode_response({code => 1}, $md5)->{code}, 1, 'V1 success code is 1');
rejects(sub { decode_response({code => 0}, $md5) }, 'V2 success code is not accepted for V1');
rejects(sub { build_payment_request($order, { %$md5, api_url => 'http://pay.example.test' }) }, 'server request cannot use insecure transport');
is(validate_payment_evidence({ %$notify, code => 1, status => 1 }, $order, $md5, mode => 'query')->{trade_no},
    $notify->{trade_no}, 'legacy authenticated server query shares frozen evidence validation');
rejects(sub { validate_payment_evidence({ %$notify, code => 1, status => 0 }, $order, $md5, mode => 'query') },
    'query not-paid is not proof of settlement');

subtest 'RSA-SHA256 protocol and trust boundary' => sub {
    unless (eval { require Crypt::PK::RSA; 1 }) { plan skip_all => 'Cryptx unavailable on this host; container test runs RSA cases'; }
    my $merchant = Crypt::PK::RSA->new();
    $merchant->generate_key(256, 65537); # Cryptx key size is bytes (2048 bits).
    my $platform = Crypt::PK::RSA->new();
    $platform->generate_key(256, 65537);
    my $rsa = { %$md5, protocol => 'v2_rsa',
        merchant_private_key => $merchant->export_key_pem('private'),
        platform_public_key => $platform->export_key_pem('public') };
    my $rsa_order = { %$order, protocol => 'v2_rsa' };
    my $request = build_payment_request($rsa_order, $rsa, now => $now);
    is($request->{url}, 'https://pay.example.test/api/pay/create', 'V2 API endpoint');
    is($request->{fields}->{method}, 'jump', 'V2 requests jump method');
    is($request->{fields}->{sign_type}, 'RSA', 'wire label is RSA, not RSA2');
    ok($merchant->verify_message(decode_base64($request->{fields}->{sign}),
        canonical_string($request->{fields}), 'SHA256', 'v1.5'), 'merchant signs RSA-SHA256 request');
    my $provider = { %$rsa, merchant_private_key => $platform->export_key_pem('private') };
    my $incoming = sign_request({ %$notify, timestamp => $now }, $provider);
    ok(verify_signature($incoming, $rsa), 'platform public key validates provider response');
    ok(validate_notification($incoming, $rsa_order, $rsa, now => $now), 'RSA notification accepted');
    ok(!verify_signature(sign_request({ %$notify, timestamp => $now }, $rsa), $rsa), 'merchant key is not trusted as platform key');
    ok(!verify_signature({ %$incoming, sign_type => 'MD5' }, $rsa), 'frozen RSA cannot accept MD5 downgrade');
    ok(!verify_signature({ %$incoming, sign_type => 'RSA2' }, $rsa), 'RSA2 label is rejected');
    ok(!verify_signature({ %$incoming, money => '13.00' }, $rsa), 'RSA amount tamper rejected');
    rejects(sub { validate_notification(sign_request({ %$notify, timestamp => $now - 301 }, $provider),
        $rsa_order, $rsa, now => $now) }, 'expired timestamp rejected');
    ok(validate_notification(sign_request({ %$notify, timestamp => $now - 300 }, $provider),
        $rsa_order, $rsa, now => $now), 'exact configured timestamp boundary accepted');
    rejects(sub { validate_notification(sign_request({ %$notify, timestamp => $now + 301 }, $provider),
        $rsa_order, $rsa, now => $now) }, 'future timestamp beyond allowed skew rejected');
    my $old = sign_request({ %$notify, timestamp => $now - 3600 }, $provider);
    my $paid = { %$rsa_order, state => 'PAID', trade_no => $notify->{trade_no} };
    ok(validate_notification($old, $paid, $rsa, now => $now, allow_paid_replay => 1),
        'expired authentic notification may acknowledge an already paid order');
    rejects(sub { validate_notification($old, { %$rsa_order, state => 'PENDING' }, $rsa,
        now => $now, allow_paid_replay => 1) }, 'paid replay flag never permits stale pending settlement');
    rejects(sub { validate_notification($old, $paid, $rsa, now => $now) },
        'pure helper does not bypass freshness without explicit paid-replay opt-in');
    rejects(sub { validate_notification(sign_request($notify, $provider), $paid, $rsa,
        now => $now, allow_paid_replay => 1) }, 'paid replay still requires a well-formed protocol timestamp');
    rejects(sub { validate_notification({ %$old, money => '13.00' }, $paid, $rsa,
        now => $now, allow_paid_replay => 1) }, 'expired paid replay still rejects signature tampering');
    for my $change ([money => '13.00'], [pid => '1002'], [trade_no => 'another_trade'],
        [out_trade_no => 'another_order'], [type => 'wxpay'], [trade_status => 'TRADE_CLOSED']) {
        my $wrong = sign_request({ %$notify, timestamp => $now - 3600, @$change }, $provider);
        rejects(sub { validate_notification($wrong, $paid, $rsa, now => $now, allow_paid_replay => 1) },
            "signed expired paid replay cannot change $change->[0]");
    }
    my $old_query = sign_request({ %$notify, code => 0, status => 1, timestamp => $now - 3600 }, $provider);
    rejects(sub { validate_payment_evidence($old_query, $paid, $rsa,
        mode => 'query', now => $now, allow_paid_replay => 1) }, 'paid replay flag cannot relax query response freshness');
    my $response = sign_request({ code => 0, timestamp => $now, trade_no => $notify->{trade_no},
        pay_type => 'jump', pay_info => 'https://pay.example.test/checkout' }, $provider);
    is(decode_response($response, $rsa, now => $now)->{code}, 0, 'V2 response success is signed code 0');
    rejects(sub { decode_response({ %$response, code => 1 }, $rsa, now => $now) }, 'V1 success code is not accepted for V2');
    rejects(sub { decode_response({ code => 0, timestamp => $now }, $rsa, now => $now) }, 'unsigned V2 response rejected');
};

done_testing();
