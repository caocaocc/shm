#!/usr/bin/perl
use v5.14;
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../pay_systems/epay/lib";
use SHM::Pay::Epay::Install;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha256_hex);
use JSON::PP;
my ($out) = @ARGV;
die "Usage: build.pl NEW-DIRECTORY\n" unless defined($out) && !-e $out && !-l $out;
mkdir($out, 0755) or die $!;
my $module = "$RealBin/../../pay_systems/epay";
my %payload;
for my $file (@SHM::Pay::Epay::Install::runtime, 'setup.pl', 'install') {
    my $source = -f "$module/$file" ? "$module/$file" : "$RealBin/$file";
    make_path(dirname("$out/$file"));
    copy($source, "$out/$file") or die "Cannot copy $file\n";
    chmod(0755, "$out/$file") or die $! if $file eq 'install' || $file eq 'epay.cgi';
    $payload{$file} = encode_base64(SHM::Pay::Epay::Install::bytes($source), '') unless $file eq 'install';
}
my $json = JSON::PP->new->canonical->encode(\%payload);
my $template = SHM::Pay::Epay::Install::bytes("$RealBin/epay_install.tt.in");
my $release = SHM::Pay::Epay::Install::digest($module);
$template =~ s/__RELEASE__/$release/g;
$template =~ s/__PAYLOAD__/encode_base64($json, '')/e;
open my $tt, '>:raw', "$out/epay_install.tt" or die $!;
print {$tt} $template or die $!;
close $tt or die $!;
open my $checks, '>', "$out/SHA256SUMS" or die $!;
for my $file (sort keys(%payload), 'epay_install.tt', 'install') {
    print {$checks} sha256_hex(SHM::Pay::Epay::Install::bytes("$out/$file"))."  $file\n";
}
close $checks or die $!;
