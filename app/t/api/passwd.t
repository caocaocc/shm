use v5.14;
use utf8;
use strict;
use warnings;
use Core::Utils qw(shm_test_api);
use Test::More;

# Do not change the shared legacy danuk fixture: its five-character password
# remains valid for authentication but cannot be newly assigned by the API.
my $login = 'passwd-api-' . $$;
my $password = 'fixture-initial-123';
my %created = shm_test_api(url => 'v1/user', method => 'PUT',
    data => {login => $login, password => $password});
my $user_id = $created{json}{data}[0]{user_id};
BAIL_OUT('Cannot create isolated password fixture') unless $user_id;
END {
    shm_test_api(url => "v1/admin/user?user_id=$user_id&force=1", method => 'DELETE',
        login => 'admin', password => 'admin') if $user_id;
}

sub change_password {
    my ($auth, $old, $new, %extra) = @_;
    return shm_test_api(url => 'v1/user/passwd', method => 'POST',
        login => $login, password => $auth,
        data => {old_password => $old, password => $new, %extra});
}
subtest 'Change own password' => sub {
    my %ret = change_password($password, $password, 'fixture-changed-123');
    is($ret{success}, 1, 'valid password change succeeds');
};
subtest 'Old credentials cannot change the password' => sub {
    my %ret = change_password($password, $password, 'fixture-changed-123');
    is($ret{json}{status}, 401, 'old password no longer authenticates');
};
subtest 'Short replacement is rejected without changing the password' => sub {
    my %ret = change_password('fixture-changed-123', 'fixture-changed-123', 'short');
    is($ret{json}{status}, 400, 'new password respects the upstream minimum length');
};
subtest 'Restore a valid password' => sub {
    my %ret = change_password('fixture-changed-123', 'fixture-changed-123', $password);
    is($ret{success}, 1, 'valid replacement succeeds after rejected short input');
};
subtest 'Authenticated user cannot change another login' => sub {
    my %ret = change_password($password, $password, 'should-not-work', login => 'admin');
    is($ret{success}, '', 'another login is rejected');
    is($ret{json}{status}, 400, 'account ownership rejection is a client error');
    my %own = shm_test_api(url => 'v1/user', login => $login, password => $password);
    is($own{success}, 1, 'own credentials remain usable');
    my %admin = shm_test_api(url => 'v1/user', login => 'admin', password => 'admin');
    is($admin{success}, 1, 'admin credentials remain unchanged');
};

done_testing();
