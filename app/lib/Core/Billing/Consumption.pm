package Core::Billing::Consumption;

use v5.14;
use utf8;
use strict;
use warnings;
use Math::BigRat;
use Time::Local qw(timelocal);
use Exporter 'import';

our @EXPORT_OK = qw(normalize_policy decimal decimal_sum decimal_difference money_to_minor minor_to_money epoch quote);

# Meter amounts stay decimal strings throughout persistence and calculation.
# DECIMAL(38,12) is also the ingress/database contract.
sub decimal {
    my ($value, $positive) = @_;
    die "计量值必须为非负十进制数\n" if !defined($value) || ref($value)
        || $value !~ /\A\d{1,26}(?:\.\d{1,12})?\z/;
    my $number = Math::BigRat->new("$value");
    die "计量额度必须大于零\n" if $positive && $number->is_zero;
    my $normalized = "$value";
    $normalized =~ s/^0+(?=\d)//;
    $normalized =~ s/(\.\d*?)0+$/$1/;
    $normalized =~ s/\.$//;
    return $normalized;
}

sub normalize_policy {
    my ($config) = @_;
    return undef unless defined $config;
    die "消费策略无效，仅支持显式 PREPAID 模式\n" unless ref($config) eq 'HASH'
        && ($config->{mode} // '') eq 'PREPAID'
        && ref($config->{quotas}) eq 'HASH' && keys %{ $config->{quotas} };
    die "计量项目不能超过32项\n" if keys(%{ $config->{quotas} }) > 32;
    my %quotas;
    for my $meter (keys %{ $config->{quotas} }) {
        die "计量名称无效，time 为系统保留名称\n" unless $meter =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/
            && lc($meter) ne 'time';
        my $quota = $config->{quotas}{$meter};
        my ($limit, $unit) = ref($quota) eq 'HASH'
            ? ($quota->{limit}, $quota->{unit} // '') : ($quota, '');
        die "计量单位无效\n" if ref($unit) || length($unit) > 32 || $unit =~ /[\x00-\x1f]/;
        $quotas{$meter} = { limit => decimal($limit, 1), unit => "$unit" };
    }
    return { mode => 'PREPAID', quotas => \%quotas };
}

sub _decimal_text {
    my ($number) = @_;
    my $digits = $number->copy->bmul('1000000000000')->as_int->bstr;
    $digits = ('0' x (13 - length($digits))) . $digits if length($digits) < 13;
    return decimal(substr($digits, 0, -12) . '.' . substr($digits, -12));
}

sub decimal_sum {
    my $sum = Math::BigRat->new(0);
    $sum->badd(decimal($_)) for @_;
    return _decimal_text($sum);
}

sub decimal_difference {
    my ($current, $baseline) = @_;
    my $delta = Math::BigRat->new(decimal($current))->bsub(decimal($baseline));
    die "同一计数世代的累计用量不能倒退\n" if $delta->is_neg;
    return _decimal_text($delta);
}

sub money_to_minor {
    my ($value) = @_;
    die "金额必须为非负数且最多保留两位小数\n" if !defined($value) || ref($value)
        || $value !~ /\A\d{1,8}(?:\.\d{1,2})?\z/;
    return 0 + Math::BigRat->new("$value")->bmul(100)->as_int->bstr;
}

sub minor_to_money {
    my ($minor) = @_;
    die "金额分值必须为非负整数\n" unless defined($minor) && "$minor" =~ /\A\d+\z/;
    return sprintf('%d.%02d', int($minor / 100), $minor % 100);
}

# The existing SHM dates are local DATETIME strings. End dates are inclusive;
# quote() converts them to a half-open interval by adding exactly one second.
sub epoch {
    my ($date) = @_;
    die "计量日期无效\n" unless defined($date) && !ref($date)
        && $date =~ /\A(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\z/;
    my ($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4, $5, $6);
    my $epoch = eval { timelocal($second, $minute, $hour, $day, $month - 1, $year) };
    die "计量日期无效\n" if $@ || !defined $epoch;
    my @actual = localtime($epoch);
    die "计量日期无效\n" unless sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $actual[5] + 1900, $actual[4] + 1, @actual[3,2,1,0]) eq $date;
    return $epoch;
}

sub _ratio_text {
    my ($ratio) = @_;
    my $digits = $ratio->copy->bmul(100_000_000)->bfloor->as_int->bstr;
    $digits = ('0' x (9 - length($digits))) . $digits if length($digits) < 9;
    return substr($digits, 0, -8) . '.' . substr($digits, -8);
}

sub quote {
    my (%args) = @_;
    my $policy = normalize_policy($args{policy});
    die "缺少消费策略\n" unless $policy;
    my $start = defined($args{starts_epoch}) ? $args{starts_epoch} : epoch($args{starts_at});
    my $end = defined($args{ends_epoch}) ? $args{ends_epoch} : epoch($args{ends_at}) + 1;
    my $at = defined($args{at_epoch}) ? $args{at_epoch} : epoch($args{at});
    die "计量时间戳无效\n" if grep { !defined($_) || ref($_) || "$_" !~ /\A\d+\z/ } ($start, $end, $at);
    die "计费期间无效\n" unless $end > $start;
    my $elapsed = $at - $start;
    $elapsed = 0 if $elapsed < 0;
    my $time_ratio = Math::BigRat->new($elapsed)->bdiv($end - $start);
    my $ratio = $time_ratio->copy;
    my (%meter_ratios, %totals);
    for my $meter (keys %{ $policy->{quotas} }) {
        my $used = decimal(($args{totals} || {})->{$meter} // '0');
        $totals{$meter} = $used;
        my $meter_ratio = Math::BigRat->new($used)->bdiv($policy->{quotas}{$meter}{limit});
        $meter_ratios{$meter} = _ratio_text($meter_ratio);
        $ratio = $meter_ratio->copy if $meter_ratio->bcmp($ratio) > 0;
    }
    my $exhausted = $ratio->bcmp(1) >= 0 ? 1 : 0;
    $ratio = Math::BigRat->new(1) if $exhausted;
    my $cash = money_to_minor($args{cash});
    my $bonus = money_to_minor($args{bonus} // '0');
    my $retained = 0 + $ratio->copy->bmul($cash + $bonus)->badd('1/2')->bfloor->as_int->bstr;

    # New PREPAID periods consume bonus first at every ratio. Both cash and
    # bonus refund values must be monotone as consumption increases; switching
    # allocation branches at the original cash amount creates an arbitrage.
    # The legacy non-consumption money_back path remains unchanged.
    my $kept_bonus = $bonus < $retained ? $bonus : $retained;
    my $kept_cash = $retained - $kept_bonus;
    return {
        mode => 'PREPAID',
        time_ratio => _ratio_text($time_ratio),
        meter_ratios => \%meter_ratios,
        totals => \%totals,
        ratio => _ratio_text($ratio),
        exhausted => $exhausted,
        consumed => minor_to_money($retained),
        retained_cash => minor_to_money($kept_cash),
        retained_bonus => minor_to_money($kept_bonus),
        refundable_cash => minor_to_money($cash - $kept_cash),
        refundable_bonus => minor_to_money($bonus - $kept_bonus),
    };
}

1;
