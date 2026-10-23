use v5.14;
use strict;
use warnings;
use Test::More;
BEGIN {
    plan skip_all => 'requires SHM_SQL_CONFIG_TEST=1 and a DB_NAME ending in _test'
        unless ($ENV{SHM_SQL_CONFIG_TEST} // '') eq '1'
            && ($ENV{DB_NAME} // '') =~ /_test\z/;
}
use SHM;
use Core::System::ServiceManager qw(get_service);

# One isolated user exercises the upstream passwd() fix through real models.
# Do not change shared DEV users, configuration, or the rest of the database.
my $admin = SHM->new(user_id => 1);
my $dbh = $admin->dbh;
$dbh->{RaiseError} = 1;
my $database = $dbh->selectrow_array('SELECT DATABASE()');
plan skip_all => 'password account integration requires an actual *_test database'
    unless $database && $database =~ /_test\z/;
my $user_id;
END {
    if ($dbh && $user_id) {
        eval {
            $dbh->rollback;
            $dbh->do('DELETE FROM sessions WHERE user_id=?', undef, $user_id);
            $dbh->do('DELETE FROM accounts WHERE user_id=?', undef, $user_id);
            $dbh->do('DELETE FROM users WHERE user_id=?', undef, $user_id);
            $dbh->commit;
            1;
        } or diag('isolated password fixture cleanup failed: ' . $@);
    }
}

my $login = 'passwd-accounts-' . $$ . '-' . time;
my $email = $login . '@example.com';
my ($user_old, $login_old, $email_old, $new_password) =
    qw(users-old-password login-old-password email-old-password new-shared-password);
$dbh->do('INSERT INTO users (login,password,balance,credit,bonus,gid,settings) VALUES (?,?,0,0,0,0,?)',
    undef, $login, $admin->make_password($user_old), '{}');
$user_id = $dbh->{mysql_insertid};
$dbh->commit;
my $user = SHM->new(user_id => $user_id);
$user->logins->add(login => $login, type => 'login');
$user->logins->add(login => $email, type => 'email');
my $login_obj = $user->logins->id($login, ['login']);
my $email_obj = $user->logins->id($email, ['email']);
ok($login_obj && $email_obj, 'isolated login and email accounts created');
$login_obj->set_password($login_old);
$email_obj->set_password($email_old);
$dbh->commit;
sub account_hash {
    my ($name, $type) = @_;
    return $dbh->selectrow_array(
        q{SELECT JSON_UNQUOTE(JSON_EXTRACT(settings, '$.password.hash')) FROM accounts WHERE user_id=? AND login=? AND type=?},
        undef, $user_id, $name, $type);
}
my $old_user_hash = $user->get_password;
my @old_account_hashes = (account_hash($login, 'login'), account_hash($email, 'email'));
$user->gen_session;
$user->gen_session;
is($dbh->selectrow_array('SELECT COUNT(*) FROM sessions WHERE user_id=?', undef, $user_id),
    2, 'user has live sessions before changing its password');

my $report = get_service('report');
$report->errors;
is($user->passwd(old_password => 'incorrect-password', password => $new_password),
    undef, 'incorrect old password is rejected');
my $errors = $report->errors;
is_deeply($errors, ['INVALID_OLD_PASSWORD'], 'stable old-password error is retained');
$user->reload;
is($user->get_password, $old_user_hash, 'failed password change preserves users hash');
is_deeply([account_hash($login, 'login'), account_hash($email, 'email')],
    \@old_account_hashes, 'failed password change preserves account hashes');
is($dbh->selectrow_array('SELECT COUNT(*) FROM sessions WHERE user_id=?', undef, $user_id),
    2, 'failed password change does not revoke sessions');

# The email password differs from users.password: verifying only the users
# hash would reject this legitimate request, as the old implementation did.
ok($user->passwd(old_password => $email_old, password => $new_password),
    'an owned email account password authorizes the real password change');
$dbh->commit;
$user->reload;
ok($user->verify_password($new_password, $user->get_password, $login),
    'users hash verifies the new password');
is($dbh->selectrow_array('SELECT COUNT(*) FROM sessions WHERE user_id=?', undef, $user_id),
    0, 'successful password change revokes all user sessions');

for my $identity ([$login, $login_old, 'login'], [$email, $email_old, 'email']) {
    my ($name, $old_password, $type) = @$identity;
    my $hash = account_hash($name, $type);
    ok(defined($hash) && $user->verify_password($new_password, $hash, $name),
        "$type account stores a hash of the new password");
    my $authenticated = $user->auth(login => $name, password => $new_password);
    ok($authenticated && $authenticated->id == $user_id,
        "$type authenticates with the new password through the real auth entry");
    is($authenticated ? $authenticated->login : undef, $login,
        "$type authentication keeps the primary users.login value");
    is($authenticated && $authenticated->auth_login ? $authenticated->auth_login->get_login : undef, $name,
        "$type authentication separately exposes the submitted account identity");
    is($user->auth(login => $name, password => $old_password), undef,
        "$type rejects its previous password through the real auth entry");
    $report->errors;
}

done_testing();
