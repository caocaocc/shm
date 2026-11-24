#!/usr/bin/perl
use v5.14;
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use SHM::Pay::Epay::Install;
use SHM ();
use Core::System::ServiceManager qw(get_service);
sub runtime_files { @SHM::Pay::Epay::Install::runtime }
sub digest { SHM::Pay::Epay::Install::digest(@_) }

unless (caller) {
    my $root = $ENV{SHM_ROOT_DIR} || '/app';
    delete @ENV{qw(REQUEST_METHOD QUERY_STRING CONTENT_TYPE CONTENT_LENGTH)};
    SHM::db_connect();
    my $db = get_service('config')->local('dbh');
    SHM::Pay::Epay::Install::standalone($db, $RealBin, "$root/data");
    print "Installed /shm/pay_systems/epay.cgi\n";
}
1;
