use v5.14;
use strict;
use warnings;
use Test::More;
use Core::Utils qw(round round_up round_down);

is(round('1.005'), 1.01, 'decimal half-cent rounds up');
is(round('-1.005'), -1.01, 'negative half-cent rounds away from zero');
is(round('-1.23'), -1.23, 'negative whole-cent amount is not increased');
is(round('99999999.99'), 99999999.99, 'maximum stored money keeps its cents');
is(round('0.0049'), 0, 'sub-half-cent value rounds down');
is(round(undef), 0, 'missing optional money retains zero compatibility');
is(round_up('1.001'), 1.01, 'ceiling is exact for positive amounts');
is(round_up('-1.001'), -1, 'ceiling moves negative amounts toward zero');
is(round_down('1.009'), 1, 'floor is exact for positive amounts');
is(round_down('-1.001'), -1.01, 'floor moves negative amounts away from zero');

for my $value ('NaN', 'inf', 'not-money') {
    my $ok = eval { round($value); 1 };
    ok(!$ok, "rejects nonfinite or malformed amount: $value");
}

done_testing();
