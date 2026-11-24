use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Core::Routing::Input;

my $panel = 'https://panel.example.test';
my $password = 'p:a@ss';
my @rules = (' Example.COM. ', 'example.com', 'geoip:CN', 'geosite:google', '198.51.100.119/24', '中国.测试');
sub compile_route { Core::Routing::Input::compile($_[0], $_[1] || \@rules, $panel) }
my @forms = (
    'socks5://m:p%3Aa%40ss@8.8.8.8:1090', 'm:p%3Aa%40ss@8.8.8.8:1090',
    '8.8.8.8:1090:m:p:a@ss', '8.8.8.8|1090|m|p:a@ss', '8.8.8.8,1090,m,p:a@ss',
    "8.8.8.8\n1090\nm\np:a\@ss", "用户名: m\n密码: p:a\@ss\n服务器: 8.8.8.8\n端口: 1090",
    q{curl --socks5 8.8.8.8:1090 --proxy-user 'm:p:a@ss'},
);
for my $source (@forms) {
    my $route = compile_route($source);
    is_deeply($route->{outbound}{settings}{servers}, [{address => '8.8.8.8', port => 1090, users => [{user => 'm',pass => $password}]}],
        'provider-specific SOCKS representation has the same endpoint and decoded credentials');
    is_deeply($route->{domains}, ['domain:example.com','geosite:google','domain:xn--fiqs8s.xn--0zwm56d'], 'domains are canonical and unique');
    is_deeply($route->{ips}, ['geoip:cn','198.51.100.0/24'], 'IP rules preserve semantics');
}
my $reverse = compile_route('8.8.8.8:1090@m:password');
is($reverse->{outbound}{settings}{servers}[0]{users}[0]{user}, 'm', 'reverse endpoint and user tuple');
my $auth = 'aes-256-gcm:unit-secret';
for my $ss ('ss://'.$auth.'@8.8.4.4:443', 'ss://'.encode_base64($auth, '').'@8.8.4.4:443#name',
          'ss://'.encode_base64($auth.'@8.8.4.4:443', '')) {
    my $server = compile_route($ss)->{outbound}{settings}{servers}[0];
    is_deeply($server, {address => '8.8.4.4', port => 443, method => 'aes-256-gcm', password => 'unit-secret'}, 'SS share variant');
}
my $key = encode_base64('k' x 32, '');
my $wg = "[Interface]\nAddress=10.42.0.14/24\nPrivateKey=$key\nDNS=10.42.0.1\n[Peer]\nPublicKey=$key\nEndpoint=[2606:4700:4700::1111]:51820\nAllowedIPs=0.0.0.0/0, ::/0";
my $iface = compile_route($wg)->{outbound}{settings};
is_deeply($iface->{address}, ['10.42.0.14/24'], 'preserve distinct WireGuard interface host');
is_deeply($iface->{peers}[0]{allowedIPs}, ['0.0.0.0/0','::/0'], 'dual-stack tunnel ranges');
is_deeply($iface->{remoteDNS}, ['10.42.0.1'], 'private DNS within tunnel is preserved');
for my $case (
    ['socks5://localhost:0', undef, 'INVALID_OUTBOUND'], ['socks5://127.0.0.1:1090', undef, 'ENDPOINT_DENIED'],
    ['socks5://PANEL.EXAMPLE.TEST.:1090', undef, 'ENDPOINT_DENIED'], ['socks5://%Q0:pwd@8.8.8.8:1090', undef, 'INVALID_OUTBOUND'],
    ['ss://'.$auth.'@8.8.4.4:443?plugin=untrusted', undef, 'INVALID_OUTBOUND'], [$wg."\nPostUp=something", undef, 'INVALID_OUTBOUND'],
    [$forms[0], ['regexp:.*'], 'INVALID_RULES'], [$forms[0], ['192.0.2.0/99'], 'INVALID_RULES'],
    [$forms[0], [map { "test$_.example" } 1..201], 'INVALID_RULES'],
) {
    eval { compile_route(@$case[0,1]) };
    is($@, $case->[2]."\n", 'reject invalid input using only a public code');
}
{
    no warnings 'redefine';
    my %answers = ('panel.example.test' => ['8.8.8.8'], 'egress.example.test' => ['1.1.1.1']);
    local *Core::Routing::Input::resolve = sub { @{$answers{$_[0]} || []} };
    my $saved = compile_route('socks5://egress.example.test:1090')->{outbound};
    my $pinned = Core::Routing::Input::pin($saved, $panel);
    is($pinned->{settings}{servers}[0]{address}, '1.1.1.1', 'publishes a resolved numeric endpoint');
    is($saved->{settings}{servers}[0]{address}, 'egress.example.test', 'stored configuration retains the host');
    for my $restricted ('127.0.0.1', '8.8.8.8', '::ffff:127.0.0.1', '100.78.0.1', '2001:db8::1') {
        $answers{'egress.example.test'} = ['1.1.1.1', $restricted];
        eval { Core::Routing::Input::pin($saved, $panel) };
        is($@, "ENDPOINT_DENIED\n", 'every DNS answer must be a permitted destination');
    }
}
done_testing;
