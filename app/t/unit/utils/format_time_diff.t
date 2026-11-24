use v5.14;
use utf8;
use Test::More;
use Core::Utils qw(format_time_diff);

{
    no warnings 'redefine';
    local *Core::Utils::Today_and_Now = sub { (2026, 11, 22, 12, 30, 45) };
    is(format_time_diff($_), '', 'invalid datetime') for undef, '', 'broken', '2026-02-30 00:00:00';
    is(format_time_diff('2026-11-22 12:30:10'), '不足一分钟', 'sub-minute interval');
    is(format_time_diff('2026-11-22 12:00:45'), '30分钟', 'minutes');
    is(format_time_diff('2026-11-23 13:31:45'), '1天，1小时，1分钟', 'future interval');
    is(format_time_diff('2020-10-20 01:01:01'), '6年，1个月，2天', 'at most three nonzero units');
}
done_testing;
