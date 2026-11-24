use v5.14;
use utf8;

use Test::More;
use Test::Deep;
use Data::Dumper;
use Core::Utils qw/shm_test_api/;

my %user = (
    login => 'danuk',
    password => 'danuk',
);

subtest 'GET /v1/service/' => sub {
    my %ret = shm_test_api(
        url => 'v1/service?service_id=2',
        method => 'GET',
        %user,
    );
    is $ret{json}->{items}, 1, 'Check items field';
    is scalar @{ $ret{json}->{data} }, 1, 'Check count items in data';
    is $ret{json}->{data}->[0]->{service_id}, 2, 'Check data';
};

subtest 'a hidden service is absent from the customer catalogue' => sub {
    my %ret = shm_test_api(url => 'v1/service?service_id=5', %user);
    is($ret{json}{status}, 200);
    is(ref($ret{json}{data}), 'ARRAY', 'customer receives the usual listing envelope');
    ok(!(grep { defined } @{$ret{json}{data}}), 'no hidden service details are exposed');
};

done_testing();

exit 0;

