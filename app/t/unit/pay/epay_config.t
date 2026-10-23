use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use Core::Epay;

my $controller = bless {}, 'Core::Epay';
my $base = { pid => '1001', protocol => 'v2_rsa', key_version => 'test',
    api_url => 'https://pay.example.test', notify_url => 'https://bill.example.test/notify',
    return_url => 'https://bill.example.test/return' };
sub reject {
    my ($profile, $expected, $name) = @_;
    my $ok = eval { $controller->_public_profile('epay', $profile); 1 };
    ok(!$ok, $name);
    like($@, $expected, 'Chinese configuration error explains the rejected value');
}
reject($base, qr/易支付 API 下单必须配置支付方式/, 'default API checkout requires explicit type');
reject({ %$base, checkout => 'api', type => '' }, qr/支付方式无效/, 'empty type is invalid');
reject({ %$base, type => 'a' x 33 }, qr/支付方式无效/, 'type longer than 32 is invalid');
reject({ %$base, type => 'wx-pay' }, qr/支付方式无效/, 'type cannot contain hyphen');
reject({ %$base, type => 'wx pay' }, qr/支付方式无效/, 'type cannot contain space');
reject({ %$base, type => ['wxpay'] }, qr/支付方式无效/, 'type cannot be an array');
is($controller->_public_profile('epay', { %$base, type => 'alipay' })->{type}, 'alipay', 'fixed alipay is retained');
is($controller->_public_profile('epay_wxpay', { %$base, type => 'wxpay' })->{type}, 'wxpay', 'alias fixed wxpay is retained');
is($controller->_public_profile('epay', { %$base, type => 'WX_2' })->{type}, 'WX_2', 'letters digits underscore allowed');
is($controller->_public_profile('epay', { %$base, type => '0' })->{type}, '0', 'valid single-character type is not treated as absent');
is($controller->_public_profile('epay', { %$base, type => 'a' x 32 })->{type}, 'a' x 32, '32 character boundary accepted');
ok(!exists $controller->_public_profile('epay', { %$base, checkout => 'submit' })->{type}, 'page checkout may use cashier without type');
reject({ %$base, checkout => 'submit', type => 'wx/pay' }, qr/支付方式无效/, 'provided page type must still be valid');
reject({ %$base, protocol => 'v1_md5', type => 'alipay', api_url => 'http://pay.example.test' }, qr/HTTPS/, 'legacy profile also requires TLS');
my $http_calls = 0;
$controller->{http_request} = sub { $http_calls++; return {} };
ok(!eval { $controller->_http('http://pay.example.test/api.php', { key => 'test-not-real' }, $base); 1 }, 'legacy query rejects HTTP at request boundary');
is($http_calls, 0, 'no transport invoked for insecure request');
ok(!eval { $controller->_http('https://name:pass@pay.example.test/api.php', {}, $base); 1 }, 'URL credentials are rejected');
done_testing();
