use v5.14;
use utf8;
use strict;
use warnings;
use Core::Utils qw(shm_test_api);
use Test::More;
use Test::Deep;
use Core::System::ServiceManager qw(get_service);
use SHM;

my $user = SHM->new(user_id => 40092);
my $spool = get_service('spool');
my ($before) = $user->dbh_auto_commit->selectrow_array('SELECT COALESCE(MAX(id),0) FROM spool');

subtest 'Request password reset by a login identity' => sub {
    my %ret = shm_test_api(url => 'v1/user/passwd/reset', method => 'POST',
        data => {login => 'danuk'});
    is($ret{success}, 1, 'request succeeds');
    is($ret{json}{status}, 200, 'normal API response');
};

subtest 'Inspect and remove only this request reset task' => sub {
    # The HTTP worker committed independently; release the old SQL snapshot.
    $user->commit;
    my @rows = grep {ref($_->{event}) eq 'HASH'
        && uc($_->{event}{name} // '') eq 'USER_PASSWORD_RESET'}
        $spool->list(where => {user_id => 40092, id => {'>' => $before}}, limit => 0);
    is(scalar @rows, 1, 'exactly one new reset task belongs to this request');
    return unless @rows == 1;
    my $row = $rows[0];
    cmp_deeply($row, superhashof({
        user_id => 40092, prio => 100, status => 'NEW',
        user_service_id => undef, executed => undef,
        event => superhashof({
            name => 'USER_PASSWORD_RESET', kind => 'UserService', server_gid => 3,
            settings => superhashof({template_id => 'user_password_reset', category => '%'}),
        }),
    }), 'current reset event retains its configured transport and template');
    ok($spool->id($row->{id})->delete, 'only the newly created reset task is deleted');
    $user->commit;
};

done_testing();
