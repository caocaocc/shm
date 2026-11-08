use v5.14;
use strict;
use warnings;
use Test::More;
use Core::User;

{
    package PaymentCurrency;
    sub new { bless {}, shift }
    sub system_currency { 'CNY' }
    package PaymentReport;
    sub new { bless { errors => [] }, shift }
    sub add_error { push @{$_[0]->{errors}}, $_[1] }
    package PaymentRows;
    sub new { bless { writes => [] }, shift }
    sub add { my ($self, %args) = @_; push @{$self->{writes}}, \%args; return 7 }
    sub id { $_[0] }
    sub get { $_[0]->{writes}[-1] }
    package PaymentUser;
    our @ISA = ('Core::User');
    sub new { bless { rows => PaymentRows->new, balance => 0 }, shift }
    sub pays { $_[0]->{rows} }
    sub set_balance { my ($self, %args) = @_; $self->{balance} += $args{balance} }
    sub add_bonuses_for_partners { }
    sub make_event { }
}

my $currency = PaymentCurrency->new;
my $report = PaymentReport->new;
{
    no warnings 'redefine';
    local *Core::User::get_service = sub {
        return $currency if $_[0] eq 'Cloud::Currency';
        return $report if $_[0] eq 'report';
        die "Unexpected service $_[0]";
    };
    local *Core::User::cfg = sub { {} };

    my $user = PaymentUser->new;
    ok(!defined($user->payment(money => '10.00', currency => 'RUB')), 'foreign currency is not silently credited as CNY');
    is($user->{balance}, 0, 'rejected currency leaves balance unchanged');
    is(scalar @{$user->{rows}{writes}}, 0, 'rejected currency creates no payment record');
    ok(@{$report->{errors}}, 'currency failure is reported');

    ok($user->payment(money => '10.00', currency => 'cny'), 'matching currency accepts case normalization');
    is($user->{balance}, 10, 'matching amount credited once');
    is($user->{rows}{writes}[0]{currency}, 'CNY', 'normalized currency passed to payment adapter boundary');
    ok($user->payment(money => '2.50'), 'legacy manual input defaults to account currency');
    is($user->{balance}, 12.5, 'legacy amount retains its original unit');
}

done_testing();
