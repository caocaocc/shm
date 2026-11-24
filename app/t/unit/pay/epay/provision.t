use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../../pay_systems/epay/lib";
use SHM::Pay::Epay::Install;
use JSON::PP;
my $worker = (getpwnam('www-data'))[2];
plan skip_all => 'requires SHM worker or root' unless defined $worker && ($> == 0 || $> == $worker);
{
    package FreshDatabase;
    sub selectrow_array {
        my ($self,$sql,undef,$key) = @_;
        return $self->{published} if $sql =~ /JSON_CONTAINS_PATH/;
        return if $sql =~ /SELECT credential_box/;
        return '{}' if defined($key) && $key eq 'pay_systems';
        return if defined($key) && $key eq 'epay_merchants';
        die 'Unexpected query';
    }
    sub do {
        my ($self,$sql,undef,$value) = @_;
        push @{$self->{sql}},$sql;
        $self->{published} = JSON::PP->new->decode($value)->{epay} if $sql =~ /UPDATE config/;
        return 1;
    }
    sub commit { 1 }
}
sub fixture {
    my $root = tempdir(CLEANUP=>1);
    make_path("$root/data","$root/pay_systems/epay");
    for my $file (qw(epay.cgi accounts.sql epay.sql)) {
        my $path = "$root/pay_systems/epay/$file";
        open my $out,'>',$path or die $!;
        print {$out} 'fixture';
        close $out or die $!;
        chmod(0755,$path) or die $! if $file eq 'epay.cgi';
    }
    return ($root,bless({sql=>[]},'FreshDatabase'));
}
my ($root,$db) = fixture();
SHM::Pay::Epay::Install::bootstrap($db,$root,0);
ok(!-e "$root/data/epay", 'an existing stock site must opt in');
SHM::Pay::Epay::Install::bootstrap($db,$root,1);
ok($db->{published} && !$db->{published}{show_for_client}, 'new site has a hidden, registered channel');
for my $name (@SHM::Pay::Epay::Install::entry) {
    is(readlink("$root/data/pay_systems/$name"), "$root/pay_systems/epay/epay.cgi", 'entry resolves to the distributed CGI');
}
ok(!-e "$root/data/epay/key", 'new site defers its key until credentials are stored');
my $count = @{$db->{sql}};
SHM::Pay::Epay::Install::bootstrap($db,$root,0);
is(scalar(@{$db->{sql}}), $count, 'configured site restarts without writing DDL or merchant settings');
($root,$db) = fixture();
mkdir("$root/data/epay",0700) or die $!;
chown($worker,-1,"$root/data/epay") or die $! if $> == 0;
open my $marker,'>',"$root/data/epay/existing-merchant-backup" or die $!;
close $marker;
SHM::Pay::Epay::Install::bootstrap($db,$root,1);
is_deeply($db->{sql}, [], 'a new database does not adopt other payment material');
ok(!-e "$root/data/pay_systems/epay.cgi", 'skipping adoption leaves public entries alone');
done_testing;
