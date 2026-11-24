use v5.14;
use utf8;

use Core::Utils qw/shm_test_api/;
use Test::More;

my $login = sprintf 'test-passwd-%d-%d', time, $$;
my $original = 'before-change';
my %created = shm_test_api(
    url => 'v1/admin/user', method => 'PUT', login => 'admin', password => 'admin',
    data => { login => $login, password => $original },
);
my $id = $created{json}{data}[0]{user_id};
BAIL_OUT('could not create password-change fixture') unless $id;

subtest 'Try to change user password' => sub {
    my %ret = shm_test_api(
        url => 'v1/user/passwd',
        method => 'POST',
        data => {
            old_password => $original,
            password => 'new_password',
        },
        login => $login,
        password => $original,
    );

    is $ret{success}, 1;
};

subtest 'Try to auth with old password' => sub {
    my %ret = shm_test_api(
        url => 'v1/user/passwd',
        method => 'POST',
        data => {
            old_password => $original,
            password => 'new_password',
        },
        login => $login,
        password => $original,
    );
    is $ret{success}, '';
};

subtest 'Set old password' => sub {
    my %ret = shm_test_api(
        url => 'v1/user/passwd',
        method => 'POST',
        data => {
            old_password => 'new_password',
            password => $original,
        },
        login => $login,
        password => 'new_password',
    );

    is $ret{success}, 1;
};

subtest 'Reject changing another login' => sub {
    my %ret = shm_test_api(
        url => 'v1/user/passwd',
        method => 'POST',
        data => {
            login => 'admin',
            old_password => $original,
            password => 'should_not_work',
        },
        login => $login,
        password => $original,
    );

    is $ret{json}{status}, 400, 'authenticated user cannot change a different account';
};

my %removed = shm_test_api(
    url => "v1/admin/user?user_id=$id", method => 'DELETE',
    login => 'admin', password => 'admin',
);
ok($removed{success}, 'remove test user');
done_testing();

exit 0;
