use v5.14;
use strict;
use warnings;
use Test::More;
use Core::Utils qw(shm_test_api);

for my $query ('', '?event=changed_tariff&refresh=true') {
    my %result = shm_test_api(url => "v1/admin/topology$query", login => 'admin', password => 'admin');
    ok($result{success}, "administrator can read topology$query");
    is(ref($result{json}{nodes}), 'ARRAY', 'response includes the graph');
}

for my $case (
    ['event=create%2Fdrop', qr/Field 'event' has an invalid format/],
    ['refresh=yes',        qr/Field 'refresh' must be 0 or 1/],
) {
    my ($query, $reason) = @$case;
    my %result = shm_test_api(url => "v1/admin/topology?$query", login => 'admin', password => 'admin');
    is($result{json}{status}, 400, 'invalid query is rejected');
    like($result{json}{error}, $reason, 'response identifies the invalid parameter');
}

done_testing();
