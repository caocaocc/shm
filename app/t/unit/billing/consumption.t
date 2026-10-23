use v5.14;
use strict;
use warnings;
use Test::More;
use POSIX qw(tzset);
use Core::Billing::Consumption qw(normalize_policy decimal decimal_sum decimal_difference money_to_minor epoch quote);

$ENV{TZ} = 'UTC'; tzset();
my %period = (
    policy => { mode => 'PREPAID', quotas => { traffic => { limit => '100', unit => 'unit' } } },
    cash => '30.00', bonus => '0.00',
    starts_at => '2026-01-01 00:00:00', ends_at => '2026-01-30 23:59:59',
);

subtest 'time and usage use the greater cumulative ratio, not a sum' => sub {
    my $first = quote(%period, at => '2026-01-11 00:00:00', totals => { traffic => '50' });
    is($first->{consumed}, '15.00', '10 days and 50 units consume 15');
    is($first->{refundable_cash}, '15.00', 'remaining prepaid value');
    is($first->{ratio}, '0.50000000', 'usage dominates');
    my $later = quote(%period, at => '2026-01-21 00:00:00', totals => { traffic => '60' });
    is($later->{consumed}, '20.00', '20 days and 60 units consume 20');
    is($later->{refundable_cash}, '10.00', 'time now dominates');
    is(quote(%period, at => '2026-01-31 00:00:00', totals => { traffic => '0' })->{consumed}, '30.00', 'exclusive end is full consumption');
    is(quote(%period, at => '2025-12-31 23:00:00', totals => {})->{consumed}, '0.00', 'time before purchase is clamped to zero');
};

subtest 'multiple generic meters and cap at prepaid price' => sub {
    my $q = quote(%period, policy => { mode => 'PREPAID', quotas => { requests => '1000', storage => '10' } },
        at => '2026-01-01 00:00:00', totals => { requests => '200', storage => '8' });
    is($q->{consumed}, '24.00', 'highest meter ratio wins');
    $q = quote(%period, at => '2026-01-01 00:00:00', totals => { traffic => '1000' });
    is($q->{consumed}, '30.00', 'over quota never charges beyond prepaid amount');
    is($q->{exhausted}, 1, 'exhaustion reported');
    is($q->{refundable_cash}, '0.00', 'no negative refund');
};

subtest 'decimal accounting and monotone bonus-first allocation' => sub {
    is(decimal_sum('0.1', '0.2'), '0.3', 'decimal sum is exact');
    is(decimal_difference('1000000000000000.000000000002', '1000000000000000.000000000001'), '0.000000000001', 'large lifetime counters preserve small delta');
    is(money_to_minor('0.29'), 29, 'money parsed without binary float');
    my $q = quote(%period, cash => '20.00', bonus => '10.00', at => '2026-01-01 00:00:00', totals => { traffic => '50' });
    is_deeply([@$q{qw(retained_cash retained_bonus refundable_cash refundable_bonus)}], ['5.00', '10.00', '15.00', '0.00'], 'bonus is consumed first even below original cash amount');
    $q = quote(%period, cash => '10.00', bonus => '20.00', at => '2026-01-01 00:00:00', totals => { traffic => '50' });
    is_deeply([@$q{qw(retained_cash retained_bonus refundable_cash refundable_bonus)}], ['0.00', '15.00', '10.00', '5.00'], 'bonus-first allocation above original cash amount');
    $q = quote(%period, cash => '0.00', bonus => '30.00', at => '2026-01-01 00:00:00', totals => { traffic => '50' });
    is($q->{refundable_bonus}, '15.00', 'bonus-only payment refunds unused bonus');
    $q = quote(%period, cash => '0.01', at => '2026-01-01 00:00:00', totals => { traffic => '50' });
    is($q->{consumed}, '0.01', 'half a cent rounds once at cumulative valuation');
    is(quote(%period, cash => '0.00', at => '2026-01-01 00:00:00', totals => { traffic => '90' })->{consumed}, '0.00', 'free price stays free');
    my $before = quote(%period, cash => '20.00', bonus => '10.00', at => '2026-01-01 00:00:00', totals => {traffic => '66.666666666666'});
    my $after = quote(%period, cash => '20.00', bonus => '10.00', at => '2026-01-01 00:00:00', totals => {traffic => '66.7'});
    is($before->{consumed}, '20.00', 'original cash boundary');
    is($after->{consumed}, '20.01', 'one cent above original cash boundary');
    is($before->{refundable_cash}, '10.00', 'cash refund before boundary');
    is($after->{refundable_cash}, '9.99', 'crossing boundary cannot increase cash refund');
    my ($last_cash, $last_bonus) = (2000, 1000);
    my $monotone = 1;
    for my $used (0 .. 100) {
        my $value = quote(%period, cash => '20.00', bonus => '10.00', at => '2026-01-01 00:00:00', totals => {traffic => "$used"});
        my ($cash_refund, $bonus_refund) = map { money_to_minor($value->{$_}) } qw(refundable_cash refundable_bonus);
        $monotone = 0 if $cash_refund > $last_cash || $bonus_refund > $last_bonus;
        ($last_cash, $last_bonus) = ($cash_refund, $bonus_refund);
    }
    ok($monotone, 'cash and bonus refunds never increase with greater consumption');
};

subtest 'invalid or untrusted inputs are rejected' => sub {
    for my $value ('-1', 'NaN', 'Inf', '1e3', '1,000', [], '0.0000000000001') {
        ok(!eval { decimal($value); 1 }, 'invalid amount rejected');
    }
    ok(!eval { decimal_difference('2', '3'); 1 }, 'counter decrease rejected');
    ok(!eval { normalize_policy({ mode => 'PAYG', quotas => { traffic => '100' } }); 1 }, 'unsupported mode is not silently enabled');
    ok(!eval { normalize_policy({ mode => 'PREPAID', quotas => { time => '100' } }); 1 }, 'time meter is reserved');
    ok(!eval { normalize_policy({ mode => 'PREPAID', quotas => { traffic => '0' } }); 1 }, 'zero quota rejected');
    ok(!eval { epoch('2026-02-31 00:00:00'); 1 }, 'invalid calendar date rejected');
    ok(!eval { money_to_minor('1.001'); 1 }, 'unrounded money rejected');
    is(normalize_policy(undef), undef, 'legacy tariffs remain disabled');
};

done_testing;
