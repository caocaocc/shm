use v5.14;
use Test::More;
use Core::Billing::Traffic qw( quota reading period_usage used_bytes );

{
    package Traffic::TestService;
    sub new { my ($class, $settings) = @_; bless $settings, $class }
    sub settings { shift }
    sub get_settings { shift }
    sub server { shift->{server} }
    sub id { 42 }
}

my $service = Traffic::TestService->new({});
ok(!defined quota($service), 'ordinary plan has no quota');
$service->{remnawave} = {traffic_limit_strategy => 'DAY'};
ok(!defined quota($service), 'reset policy does not enable prepaid billing');
for my $zero (0, '000', undef, '') {
    $service->{remnawave}{traffic_limit_bytes} = $zero;
    ok(!defined quota($service), 'unlimited plan');
}
$service->{remnawave} = {traffic_limit_bytes => '1073741824'};
is(quota($service), 1073741824, 'finite quota works without a strategy');
for my $invalid (-1, '5GB', [], '9007199254740992') {
    $service->{remnawave}{traffic_limit_bytes} = $invalid;
    ok(!eval { quota($service); 1 }, 'invalid quota rejected');
}

my $open = {bytes => 40, reset_at => undef};
my $period = period_usage(100, $open);
is(used_bytes($period, {bytes => 55, reset_at => undef}), 15, 'bill begins inside panel reset window');
is(used_bytes($period, {bytes => 40, reset_at => undef}), 0, 'confirmed zero usage');
ok(!defined used_bytes($period, {bytes => 7, reset_at => undef}), 'counter falls without a reset marker');
my $after_reset = {bytes => 80, reset_at => '2026-11-04T00:00:00.000Z'};
is(used_bytes($period, $after_reset), 80, 'reset gifts earlier traffic even when ending counter exceeds opening');
ok(!defined used_bytes(period_usage(100, $after_reset), $open), 'older reset window cannot replace newer one');
ok(!defined used_bytes(period_usage(100, undef), $after_reset), 'unavailable opening is not zero');
my $unknown_opening = period_usage(100, undef);
is(used_bytes($unknown_opening, $after_reset, '2026-11-03T23:59:59.000Z'), 80,
    'a confirmed later reset starts the chargeable window even when opening was unavailable');
ok(!defined used_bytes($unknown_opening, $after_reset, $after_reset->{reset_at}), 'same moment cannot establish ordering');
ok(!defined used_bytes($unknown_opening, $after_reset, '2026-11-05T00:00:00.000Z'), 'reset precedes bill');
ok(!defined used_bytes($unknown_opening, $open, '2026-11-03T00:00:00.000Z'), 'unknown opening and no reset');
ok(!defined used_bytes($period, undef), 'unavailable closing is not zero');

subtest 'panel user lookup' => sub {
    require IO::Socket::INET;
    require JSON::PP;
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, Proto => 'tcp',
    ) or die "Cannot listen on loopback: $!";
    my $base = 'http://127.0.0.1:' . $listener->sockport;
    my $pid = fork // die "Cannot fork mock panel: $!";
    if (!$pid) {
        require POSIX;
        $SIG{ALRM} = sub { POSIX::_exit(1) };
        alarm 20;
        while (my $socket = $listener->accept) {
            my $first = <$socket> // '';
            my ($path) = $first =~ m{^GET (\S+) HTTP/1};
            my $token;
            while (<$socket>) {
                last if /^\r?\n$/;
                $token = $1 if /^Authorization:\s*Bearer ([^\s]+)\r?$/i;
            }
            my ($name) = ($path // '') =~ m{^/root/api/users/by-username/([A-Za-z_0-9-]+)$};
            my $status = $token && $token eq 'mock-token' && $name ? 200 : 403;
            my $location = '';
            if (($path // '') eq '/redirected') { $status = 200; $name = 'redirect'; }
            if (($name // '') eq 'redirect' && !$location && $path ne '/redirected') {
                $status = 302; $location = "Location: $base/redirected\r\n";
            }
            $name //= '';
            my $user = {
                username => $name eq 'other' ? 'other_person' : $name,
                id => 13, lastTrafficResetAt => undef, userTraffic => {usedTrafficBytes => 44},
            };
            delete $user->{lastTrafficResetAt} if $name eq 'no_marker';
            $user->{lastTrafficResetAt} = '2026-11-04T00:00:00Z' if $name eq 'bound_user';
            $user->{userTraffic}{usedTrafficBytes} = -1 if $name eq 'bad_counter';
            my $body = JSON::PP::encode_json({response => $user});
            print {$socket} "HTTP/1.1 $status Mock\r\n${location}Content-Type: application/json\r\n",
                'Content-Length: ', length($body), "\r\nConnection: close\r\n\r\n", $body;
            close $socket;
        }
        POSIX::_exit(0);
    }
    close $listener;
    local @ENV{qw(http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY)} =
        (('http://127.0.0.1:1') x 3, '', ('http://127.0.0.1:1') x 3, '');
    my $config = {api => "$base/root/", token => 'mock-token', http_timeout => 2};
    my $us = Traffic::TestService->new({server => Traffic::TestService->new({remnawave => $config})});
    is_deeply(reading($us), {bytes => 44, reset_at => undef}, 'server token and service ID select the account');
    {
        no warnings 'redefine';
        my $constructor = \&HTTP::Tiny::new;
        my %connect;
        local *HTTP::Tiny::new = sub { my $class = shift; %connect = @_; $constructor->($class, @_) };
        local $config->{ca_cert_path} = '/etc/shm/panel-ca.pem';
        local $config->{ca_file} = '/legacy-alias.pem';
        ok(reading($us), 'dedicated client accepts existing panel CA setting');
        is($connect{SSL_options}{SSL_ca_file}, $config->{ca_cert_path}, 'panel CA uses the established configuration key');
        ok(!grep({ !exists($connect{$_}) || defined $connect{$_} } qw(proxy http_proxy https_proxy)),
            'all proxy sources are explicitly disabled');
    }
    $us->{data}{username} = 'bound_user';
    is_deeply(reading($us), {bytes => 44, reset_at => '2026-11-04T00:00:00.000Z'}, 'explicit binding and reset marker');
    for my $name (qw(other no_marker bad_counter redirect)) {
        $us->{data}{username} = $name;
        ok(!defined reading($us), "unusable response for $name");
    }
    $us->{data}{username} = 'us_42';
    $config->{token} = 'incorrect';
    ok(!defined reading($us), 'authorization failure is not zero');
    ok(!defined used_bytes($period, reading($us), '2026-11-03T00:00:00.000Z'),
        'unavailable HTTP reading retains its argument position in settlement');
    $us->{server} = undef;
    ok(!defined reading($us), 'no panel assigned before provisioning');
    kill 'TERM', $pid;
    waitpid($pid, 0);
};
done_testing;
