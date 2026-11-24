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
use Core::Cloud::Subscription ();
use Core::System::ServiceManager qw(get_service);

# Exercise the real entry points and existing DEV users without the old
# SHM_TEST bypass. The only stub is the external subscription check.
local %ENV = %ENV;
delete @ENV{qw(SHM_TEST HTTP_TEST)};
my $subscription_calls = 0;
{
    no warnings 'redefine';
    local *Core::Cloud::Subscription::check_subscription = sub {
        ++$subscription_calls;
        return 0;
    };

    subtest 'promo validation is available without a Cloud subscription' => sub {
        my $user = SHM->new(user_id => 40092);
        ok(!$ENV{SHM_TEST}, 'test-only subscription bypass is disabled');
        ok(!$user->is_admin, 'normal customer fixture is used');
        my $report = get_service('report');
        $report->errors;
        local $report->{status};
        my $code = 'NO_SUBSCRIPTION_CODE_' . $$;
        my $result = eval { $user->srv('promo')->apply($code) };
        is($@, '', 'real promo entry completes its business validation');
        is($result, undef, 'nonexistent promo code is rejected');
        like(join('\n', @{ $report->errors }), qr/promo code .* not found/,
            'rejection comes from normal promo lookup');
        isnt($report->status // 200, 403, 'missing subscription does not cause Forbidden');
        is($subscription_calls, 0, 'promo never checks the Cloud subscription');
    };

    subtest 'analytics remains available to an administrator without a subscription' => sub {
        my $admin = SHM->new(user_id => 1);
        ok($admin->is_admin, 'administrator fixture is used');
        ok(!$ENV{SHM_TEST}, 'test-only bypass remains disabled');
        my $analytics = $admin->srv('analytics');
        my $report = get_service('report');
        $report->errors;
        local $report->{status};
        my $result = eval { $analytics->api_report(months => 1, no_cache => 1) };
        my $error = $@;
        is($error, '', 'real analytics entry completes');
        is(ref($result), 'HASH', 'real analytics entry returns a report');
        ok(ref($result) eq 'HASH' && ref($result->{overview}) eq 'HASH',
            'report contains the real overview without asserting fixture-dependent totals');
        isnt($report->status // 200, 403, 'missing subscription does not deny administrator analytics');
        is($subscription_calls, 0, 'analytics never checks the Cloud subscription');
    };
}

done_testing();
