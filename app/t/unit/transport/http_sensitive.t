use v5.14;
use strict;
use warnings;
use Test::More;
use HTTP::Response;
use IO::Socket::INET;
use POSIX ();
use Core::Transport::Http;
use Core::Const;

{
    package SensitiveHttpLogger;
    sub dump {push @{$_[0]{messages}}, $_[1]}
    sub warning {push @{$_[0]{messages}}, $_[1]}
    package SensitiveHttpUA;
    sub request {
        my ($self, $request) = @_;
        $self->{request} = $request;
        my $response = HTTP::Response->new($self->{code} || 200, 'remote-private-marker');
        $response->header('Content-Type' => 'application/json');
        $response->content($self->{body} // '{"private":"remote-private-marker"}');
        $response->request($request);
        $response->header('Client-Aborted' => 'max_size') if $self->{aborted};
        return $response;
    }
    package SensitiveHttpTask;
    sub server {bless {}, 'SensitiveHttpServer'}
    sub event_settings { {sensitive => 1} }
    sub settings { {template_id => 'synthetic-http-test'} }
    package SensitiveHttpServer;
    sub get { (host => 'https://example.test', settings => {}) }
    package SensitiveHttpTemplate;
    sub get_settings { {} }
    sub parse { 'remote-private-marker' }
}

my $logger = bless {messages => []}, 'SensitiveHttpLogger';
my $transport = bless {}, 'Core::Transport::Http';
{
    no warnings 'redefine';
    local *Core::Transport::Http::logger = sub {$logger};
    local *Core::Utils::get_service = sub {$logger};
    my $ua = bless {}, 'SensitiveHttpUA';
    my %options;
    local *Core::Transport::Http::lwp = sub {shift; %options = @_; $ua};
    my $response = $transport->http(url => 'https://example.test', method => 'PATCH',
        sensitive => 1, verify_hostname => 0, no_redirect => 0, no_proxy => 0,
        headers => {Authorization => 'Bearer private-token'}, content => {password => 'private-password'});
    is($response->code, 200, 'caller receives the response in memory');
    is($options{verify_hostname}, 1, 'sensitive requests force verified TLS');
    is($options{no_redirect}, 1, 'sensitive requests force redirect rejection');
    is($options{no_proxy}, 1, 'sensitive requests ignore environment proxies');
    is($options{max_size}, 16 * 1024 * 1024, 'sensitive response size is bounded');
    is($ua->{request}->header('Authorization'), 'Bearer private-token', 'authentication is sent to the intended request');
    ok(!defined($transport->response), 'sensitive response is not retained on the shared transport');
    is_deeply($logger->{messages}, [], 'headers, request and response never enter the logger');

    $ua->{body} = '{"malformed":"remote-private-marker"';
    my $body = $transport->post('https://example.test', sensitive => 1, full_response => 1);
    like($body->{body}, qr/remote-private-marker/, 'malformed provider body is available only in memory');
    is_deeply($logger->{messages}, [], 'malformed sensitive JSON bypasses the logging decoder');

    $ua->{aborted} = 1;
    my $too_large = $transport->http(url => 'https://example.test', sensitive => 1);
    is($too_large->code, 502, 'a truncated response cannot be mistaken for success');
    unlike($too_large->as_string, qr/remote-private-marker/, 'truncation failure contains only fixed metadata');
    delete $ua->{aborted};

    local *Core::Transport::Http::get_service = sub {bless {}, 'SensitiveHttpTemplate'};
    for my $code (200, 202, 302, 400, 401, 429, 500) {
        $ua->{code} = $code;
        my ($status, $result) = $transport->send(bless {}, 'SensitiveHttpTask');
        is($status, $code >= 200 && $code < 300 ? SUCCESS : FAIL, "sensitive task handles HTTP $code explicitly");
        ok(!exists($result->{request}) && !exists($result->{response}), 'task result does not contain remote requests or responses');
        unlike(join(' ', values %$result), qr/remote-private-marker|private-token|private-password/, 'task result uses fixed safe metadata');
    }
    $ua->{body} = '{}'; $ua->{code} = 200;
    $transport->http(url => 'http://example.test', content => 'ordinary');
    is(scalar @{$logger->{messages}}, 1, 'ordinary transport retains existing diagnostic behavior');
    ok(defined($transport->response), 'ordinary transport retains its response accessor');
    $transport->http(url => 'https://example.test', sensitive => 1);
    ok(!defined($transport->response), 'sensitive request also removes a prior shared response');
}

{
    local $ENV{HTTP_PROXY} = 'http://127.0.0.1:1';
    local $ENV{HTTPS_PROXY} = 'http://127.0.0.1:1';
    local $ENV{http_proxy} = 'http://127.0.0.1:1';
    local $ENV{https_proxy} = 'http://127.0.0.1:1';
    my $ua = $transport->lwp(timeout => 2, no_redirect => 1, no_proxy => 1, ca_bundle => '/qa/placeholder-ca.pem');
    is($ua->max_redirect, 0, 'real LWP disables redirects');
    is_deeply($ua->requests_redirectable, [], 'no method is redirectable');
    ok(!defined($ua->proxy('http')) && !defined($ua->proxy('https')), 'real LWP has no environment proxy for sensitive calls');
    is($ua->ssl_opts('verify_hostname'), 1, 'real LWP verifies TLS hostnames');
    is($ua->ssl_opts('SSL_ca_file'), '/qa/placeholder-ca.pem', 'custom trusted CA selection is supported');
}

subtest 'real redirect is blocked without breaking ordinary HTTP behavior' => sub {
    my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1)
        or plan skip_all => 'loopback sockets unavailable';
    my $port = $listener->sockport;
    my $pid = fork(); die $! unless defined $pid;
    unless ($pid) {
        local $SIG{ALRM} = sub {POSIX::_exit(4)}; alarm 10;
        for (1..3) {
            my $connection = $listener->accept or POSIX::_exit(2);
            my $request = <$connection> // '';
            while (my $line = <$connection>) {last if $line =~ /^\r?\n$/}
            my $redirect = $request =~ m{ /redirect };
            print {$connection} $redirect
                ? "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:$port/target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
            close $connection;
        }
        POSIX::_exit(0);
    }
    close $listener;
    no warnings 'redefine';
    local *Core::Transport::Http::logger = sub {$logger};
    local @ENV{qw(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy)};
    is($transport->http(url => "http://127.0.0.1:$port/redirect", method => 'GET', sensitive => 1, timeout => 2)->code,
        302, 'sensitive request does not follow the redirect');
    is($transport->http(url => "http://127.0.0.1:$port/redirect", method => 'GET', timeout => 2)->code,
        200, 'ordinary GET keeps existing redirect behavior');
    waitpid($pid, 0);
    is($? >> 8, 0, 'loopback server receives exactly the expected three requests');
};

done_testing();
