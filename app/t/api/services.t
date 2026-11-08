use v5.14;
use utf8;

use Test::More;
use Test::Deep;
use Core::Utils qw/shm_test_api/;

my %user = (
    login => 'danuk',
    password => 'danuk',
);

# Service 2 is orderable; service 5 is an internal child of the fixture tariff.
subtest 'GET /v1/service/ for an orderable tariff' => sub {
    my %ret = shm_test_api(
        url => 'v1/service?service_id=2',
        method => 'GET',
        %user,
    );
    is $ret{json}->{items}, 1, 'Check items field';
    is scalar @{ $ret{json}->{data} }, 1, 'Check count items in data';
    is $ret{json}->{data}->[0]->{service_id}, 2, 'Check data';
};

subtest 'Internal child service cannot be exposed as an orderable tariff' => sub {
    my %ret = shm_test_api(url => 'v1/service?service_id=5', method => 'GET', %user);
    is($ret{json}->{status}, 200, 'authenticated request completed');
    is(ref($ret{json}->{data}), 'ARRAY', 'normal list envelope is returned');
    my @rows = grep { ref($_) eq 'HASH' } @{ $ret{json}->{data} || [] };
    is(scalar @rows, 0, 'non-orderable child details are not returned');
};

done_testing();

exit 0;

