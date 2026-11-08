use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use lib ($ENV{SHM_ROOT_DIR} || '/app') . '/pay_systems/lib';
use SHM::Pay::Epay;

{
    package EpayConfig;
    use parent 'SHM::Pay::Epay';
    sub _system_url { 'https://billing.example.test' }
}
my $controller = bless {}, 'EpayConfig';
my $base = { pid => '1001', apiurl => 'https://pay.example.test', key => 'unit-not-real' };
sub reject {
    my ($profile, $expected, $name) = @_;
    my $ok = eval { $controller->_public_profile('epay', $profile); 1 };
    ok(!$ok, $name);
    like($@, $expected, 'configuration error explains the rejected value');
}
sub native_request {
    my ($profile) = @_;
    my $frozen = $controller->_public_profile('epay', $profile);
    my $credentials = $controller->_configured_credentials($profile);
    return SHM::Pay::Epay::Protocol::build_payment_request(
        {pid => '1001', amount_cents => 123, payment_type => 'alipay'},
        {%$frozen, %$credentials}, flow => $frozen->{checkout} eq 'submit' ? 'submit' : 'create');
}
my $simple = $controller->_public_profile('epay', $base);
is($simple->{protocol}, 'v1_md5', 'MD5 is inferred from provider key');
is($simple->{checkout}, 'submit', 'page checkout is the default');
is($simple->{api_url}, 'https://pay.example.test', 'SDK apiurl is mapped into the existing private snapshot field');
is(native_request($base)->{url}, 'https://pay.example.test/submit.php', 'default MD5 action uses native submit endpoint');
is(native_request({%$base, action => 'mapi'})->{url}, 'https://pay.example.test/mapi.php', 'MD5 mapi action uses native API endpoint');
is($simple->{notify_url}, 'https://billing.example.test/shm/pay_systems/epay.cgi?action=notify', 'notification is derived from trusted system URL');
is($simple->{return_url}, 'https://billing.example.test/shm/pay_systems/epay.cgi?action=return', 'return is derived from trusted system URL');
ok(!exists $simple->{key} && !exists $simple->{md5_key}, 'public profile excludes credentials');
ok(!exists $simple->{key_version}, 'operator does not assign a credential version');
is($controller->_public_profile('epay', {%$base, action=>'mapi'})->{checkout}, 'api', 'API mode can request a payment choice later');
reject({%$base, api_url => 'https://old.example.test'}, qr/不支持的字段/, 'unsupported gateway field is explicitly rejected');
reject({%$base, checkout => 'api'}, qr/不支持的字段/, 'unsupported checkout field is explicitly rejected');
for my $action (undef, '', 'api', 'create', 'web', 'jump', 'submit.php', [], {}) {
    reject({%$base, action => $action}, qr/action 必须为 submit 或 mapi/, 'invalid MD5 action is rejected');
}
reject({%$base,notify_url=>'https://untrusted.example.test/notify'},qr/不支持的字段/,'old callback override is explicitly rejected');
reject({%$base,key=>''},qr/密钥/,'empty MD5 key rejected');
reject({%$base,key=>{}},qr/密钥/,'object MD5 key rejected');
reject({%$base,merchant_private_key=>'another'},qr/不能同时/,'mixed credential groups rejected');
reject({pid=>'1001',apiurl=>'https://pay.example.test',merchant_private_key=>'only-one'},qr/密钥/,'incomplete RSA group rejected');
reject({%$base,pid=>'0'},qr/商户 ID/,'zero merchant rejected');
reject({%$base,action=>'mystery'},qr/action 必须为 submit 或 mapi/,'unknown channel action rejected');
ok(!eval {$controller->_public_profile('epay',$base,type=>'WX_2');1},'unsupported chosen payment type rejected');
ok(!eval {$controller->_public_profile('epay',$base,type=>['alipay']);1},'non-scalar chosen payment type rejected');
reject({%$base,apiurl=>'http://pay.example.test'},qr/HTTPS/,'MD5 gateway also requires TLS');
reject({%$base,apiurl=>'https://name:pass@pay.example.test'},qr/HTTPS/,'URL credentials rejected');
reject({%$base,apiurl=>'https://pay.example.test/?secret=value'},qr/HTTPS/,'gateway query rejected');
reject({%$base,apiurl=>'https://pay.example.test/#fragment'},qr/HTTPS/,'gateway fragment rejected');
is($controller->_public_profile('epay',$base,type=>'alipay')->{type},'alipay','allowed checkout payment choice is accepted');
subtest 'operator can fix a provider payment code without browser overrides' => sub {
    for my $type (qw(alipay wxpay qqpay bank jdpay paypal douyinpay), 'a', 'a' . ('0' x 31)) {
        my $profile = {%$base, type => $type};
        is($controller->_public_profile('epay', $profile)->{type}, $type, 'configured provider code is frozen');
        is($controller->_public_profile('epay', $profile, type => $type)->{type}, $type, 'browser may repeat the configured code');
    }
    for my $type (undef, '', 'Alipay', '0pay', 'ali-pay', 'a' x 33, "alipay\n", ' alipay', '支付宝', [], {}) {
        reject({%$base, type => $type}, qr/支付方式代码无效/, 'malformed configured code is rejected');
    }
    for my $choice ('wxpay', 'qqpay', '', undef, [], {}) {
        ok(!eval { $controller->_public_profile('epay', {%$base, type => 'alipay'}, type => $choice); 1 }, 'browser cannot replace a fixed channel');
        like($@, qr/此支付通道不匹配/, 'channel mismatch is explicit');
    }
    ok(!eval { $controller->_public_profile('epay', $base, type => 'qqpay'); 1 }, 'unconfigured browser choices retain the existing allowlist');
    ok(!eval { $controller->_public_profile('epay', $base, type => undef); 1 }, 'an explicit invalid browser choice is not treated as omission');
    ok(!exists $controller->_public_profile('epay', $base)->{type}, 'omitting the configured type retains the existing cashier flow');
};
reject({%$base,protocol=>'v1_md5',key_version=>'manual'},qr/不支持的字段/,'unsupported protocol and manual credential fields are rejected');
my $http_calls = 0;
$controller->{http_request} = sub { $http_calls++; return {} };
ok(!eval { $controller->_http('http://pay.example.test/api.php', { key=>'unit-not-real' }, $base); 1 }, 'request boundary rejects HTTP');
is($http_calls,0,'insecure request never invokes transport');

subtest 'RSA is identified by complete provider credential pair' => sub {
    unless (eval {require Crypt::PK::RSA;1}) {plan skip_all=>'Cryptx unavailable on host; official runtime runs this test'}
    my $merchant=Crypt::PK::RSA->new;$merchant->generate_key(256,65537);
    my $platform=Crypt::PK::RSA->new;$platform->generate_key(256,65537);
    my $rsa={pid=>'1001',apiurl=>'https://pay.example.test',merchant_private_key=>$merchant->export_key_pem('private'),platform_public_key=>$platform->export_key_pem('public')};
    is($controller->_public_profile('epay',$rsa)->{protocol},'v2_rsa','RSA inferred without protocol field');
    is(native_request($rsa)->{url}, 'https://pay.example.test/api/pay/submit', 'default RSA action uses native submit endpoint');
    is(native_request({%$rsa, action => 'create'})->{url}, 'https://pay.example.test/api/pay/create', 'RSA create action uses native API endpoint');
    is($controller->_public_profile('epay', {%$rsa, action => 'create'})->{checkout}, 'api', 'RSA create is frozen using the existing private checkout value');
    for my $action (undef, '', 'api', 'mapi', 'web', 'jump', [], {}) {
        reject({%$rsa, action => $action}, qr/action 必须为 submit 或 create/, 'invalid RSA action is rejected');
    }
    my $pem_credentials=$controller->_configured_credentials($rsa);
    my $private_body=$rsa->{merchant_private_key};my $public_body=$rsa->{platform_public_key};
    for ($private_body,$public_body) {s/-----[^-]+-----//g;s/\s//g}
    my $body_credentials=$controller->_configured_credentials({%$rsa,merchant_private_key=>$private_body,platform_public_key=>$public_body});
    is($body_credentials->{merchant_private_key},$pem_credentials->{merchant_private_key},'DER Base64 merchant key matches PEM');
    is($body_credentials->{platform_public_key},$pem_credentials->{platform_public_key},'DER Base64 platform key matches PEM');
    my $wrapped=$private_body;$wrapped =~ s/(.{64})/$1\n/g;
    is($controller->_configured_credentials({%$rsa,merchant_private_key=>$wrapped})->{merchant_private_key},$pem_credentials->{merchant_private_key},'standard Base64 line breaks are accepted');
    reject({%$rsa,merchant_private_key=>$private_body.'='},qr/RSA 密钥/,'noncanonical Base64 padding rejected');
    reject({%$rsa,merchant_private_key=>'not a key!'},qr/RSA 密钥/,'garbage RSA key rejected');
    reject({%$rsa,platform_public_key=>$private_body},qr/RSA 密钥/,'Base64 private key cannot be used as platform public key');

    reject({%$rsa,merchant_private_key=>$merchant->export_key_pem('public')},qr/RSA 密钥/,'merchant key must be private');
    reject({%$rsa,platform_public_key=>$platform->export_key_pem('private')},qr/RSA 密钥/,'platform key must be public');
};
subtest 'public errors accept only deliberate payment failures' => sub {
    my $failure = eval { SHM::Pay::Epay::Protocol::money_to_cents('invalid'); 1 };
    my $error = $@;
    ok(!$failure, 'controlled validation fails');
    like(SHM::Pay::Epay::_safe_error($error), qr/支付金额/, 'controlled error remains useful');
    for my $private ("数据库失败：private-token\n", "library key=private-token\n", {}) {
        is(SHM::Pay::Epay::_safe_error($private), '易支付处理失败，请联系管理员',
            'unknown text or object is hidden regardless of language');
    }
};
done_testing();
