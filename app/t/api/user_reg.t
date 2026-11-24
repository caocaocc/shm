use v5.14;
use utf8;

use Core::Utils qw/shm_test_api/;

use Test::More;

my $login = sprintf 'login-%d-%d', time, $$;

for my $case (
    [undef,      qr/Field required: password/],
    ['abc12',    qr/at least 6 characters/],
    ['a' x 129,  qr/at most 128 characters/],
) {
    my ($password, $error) = @$case;
    my %result = shm_test_api(
        url => 'v1/user', method => 'PUT',
        data => {login => $login, defined($password) ? (password => $password) : ()},
    );
    is($result{json}{status}, 400, 'invalid registration is rejected');
    like($result{json}{error}, $error, 'password validation explains the rejection');
}

my %ret = shm_test_api(
    url => 'v1/user',
    method => 'PUT',
    data => {
        login => $login,
        password => 'abc123',
    },
);

is( $ret{json}->{data}->[0]->{login}, $login, 'Register new user');

my %test = shm_test_api(
    login => 'admin',
    password => 'admin',
    url => 'v1/admin/user?user_id='. $ret{json}->{data}->[0]->{user_id},
    method => 'DELETE',
);

is $test{success}, 1, 'Check user delete status';

my %guest = shm_test_api(url => 'v1/user');
is($guest{json}{status}, 401, 'anonymous requests carry no credentials from the previous request');

done_testing();

exit 0;

