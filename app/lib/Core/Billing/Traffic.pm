package Core::Billing::Traffic;

use v5.14;
use Exporter 'import';
use Core::Billing::Traffic::Remnawave ();
our @EXPORT_OK = qw(quota reading period_usage used_bytes);

sub quota   { Core::Billing::Traffic::Remnawave::quota(@_) }
sub reading { scalar Core::Billing::Traffic::Remnawave::reading(@_) }

sub period_usage {
    my ($limit, $sample) = @_;
    my %period = (limit_bytes => 0 + $limit);
    @period{qw(start_bytes start_reset_at)} = @$sample{qw(bytes reset_at)} if $sample;
    return \%period;
}

sub used_bytes {
    my ($period, $sample, $opened_at) = @_;
    return unless $sample;
    my $reset = $sample->{reset_at} // '';
    if (!defined $period->{start_bytes}) {
        return unless $opened_at && $reset gt $opened_at;
        return $sample->{bytes};
    }
    my $opening_reset = $period->{start_reset_at} // '';
    return if $reset lt $opening_reset;
    return $sample->{bytes} if $reset gt $opening_reset;
    my $used = $sample->{bytes} - $period->{start_bytes};
    return $used < 0 ? undef : $used;
}

1;
