use v5.14;
use strict;
use warnings;
use Test::More;
use Core::Utils qw(shm_test_api);
use HTTP::Response;

my @requests;
{
    no warnings 'redefine';
    local *LWP::UserAgent::request = sub {
        my ($ua, $request) = @_;
        push @requests, $ua->prepare_request($request);
        return HTTP::Response->new(200, 'OK', [], '{}');
    };
    shm_test_api(url => 'v1/user', login => 'fixture', password => 'test-only');
    shm_test_api(url => 'v1/user');
    shm_test_api(url => 'v1/user', method => 'POST', data => {name => 'test'}, login => 'other');
}
is($requests[0]->header('login'), 'fixture', 'authenticated probe carries its login');
is($requests[0]->header('password'), 'test-only', 'authenticated probe carries its password');
ok(!defined $requests[1]->header('login'), 'anonymous request starts without a login');
ok(!defined $requests[1]->header('password'), 'anonymous request starts without a password');
is($requests[2]->header('login'), 'other', 'subsequent requests keep their own credentials');
ok(!defined $requests[2]->header('password'), 'a partial request cannot inherit the previous password');
done_testing;
