package SHM::Pay::Epay::Install;
use v5.14;
use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8);
use Fcntl qw(:DEFAULT :flock :mode O_NOFOLLOW);
use JSON::PP;
use File::Basename qw(dirname);
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use SHM::Pay::Epay::Channels ();
use SHM::Pay::Epay::Vault qw(account_values pack_json save_account site_key unpack_json read_order);

our @entry = qw(epay.cgi epay_notify.cgi epay_return.cgi);
our @runtime = qw(accounts.sql epay.sql epay.cgi lib/SHM/Pay/Epay.pm lib/SHM/Pay/Epay/Channels.pm
    lib/SHM/Pay/Epay/Install.pm lib/SHM/Pay/Epay/Protocol.pm lib/SHM/Pay/Epay/Vault.pm);

sub bytes {
    my ($path) = @_;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die "Cannot read module resource\n";
    die "Expected regular resource\n" unless -f $fh;
    binmode $fh;
    local $/;
    return scalar <$fh>;
}
sub digest {
    my ($source) = @_;
    return sha256_hex(join '', map { $_."\0".sha256_hex(bytes("$source/$_"))."\n" } sort @runtime);
}
sub directory {
    my ($name, $perm, $worker, $group) = @_;
    if (!lstat($name)) {
        mkdir($name, $perm) or die "Cannot create payment directory\n";
        chown($worker, $group, $name) or die "Cannot assign payment directory\n" if $> == 0;
    }
    my @s = lstat($name);
    die "Unsafe payment directory\n" unless @s && S_ISDIR($s[2]) && ($s[2] & 0022) == 0
        && ($perm != 0700 || (($s[2] & 0777) == 0700 && $s[4] == $worker));
}
sub paths_free {
    my ($public, $target) = @_;
    return 0 if -l $public;
    for my $entry (@entry) {
        my $path = "$public/$entry";
        return 0 if lstat($path) && (!-l _ || (readlink($path) // '') ne $target);
    }
    return 1;
}
sub publish {
    my ($public, $target) = @_;
    for my $name (@entry) {
        my $path = "$public/$name";
        next if (readlink($path) // '') eq $target;
        symlink($target, $path) or die "Cannot publish payment entry\n";
    }
}
sub schema {
    my ($db, $source) = @_;
    $db->do(bytes("$source/$_")) for qw(accounts.sql epay.sql);
}
sub registration {
    my ($db) = @_;
    my $select = 'SELECT value FROM config WHERE config.key=? FOR UPDATE';
    my ($raw) = $db->selectrow_array($select, undef, 'pay_systems');
    my $catalog = unpack_json($raw);
    my ($legacy) = $db->selectrow_array($select, undef, 'epay_merchants');
    my $old = defined($legacy) ? unpack_json($legacy) : {};
    die "Invalid merchant registry\n" unless ref($old) eq 'HASH' && ref($catalog) eq 'HASH';
    die "Conflicting default payment channel\n" if exists($catalog->{epay})
        && !SHM::Pay::Epay::Channels::ours($catalog, 'epay');
    $catalog->{epay} //= {name => '易支付', action => 'submit', show_for_client => JSON::PP::false};
    my %profiles = map { $_ => 1 } keys %$old, grep { SHM::Pay::Epay::Channels::ours($catalog, $_) } keys %$catalog;
    my @fields = qw(apiurl pid key merchant_private_key platform_public_key);
    for my $id (sort keys %profiles) {
        my $row = $catalog->{$id};
        die "Unknown legacy merchant\n" unless SHM::Pay::Epay::Channels::ours($catalog, $id) && $id =~ /\A[a-z][a-z0-9_-]{0,31}\z/;
        my ($box) = $db->selectrow_array('SELECT credential_box FROM epay_accounts WHERE profile=? FOR UPDATE', undef, $id);
        my $stored = account_values($db, $id, $box) || {};
        my %merged = %$stored;
        my $migrate = 0;
        my $previous = $old->{$id} // {};
        die "Invalid legacy merchant\n" if ref($previous) ne 'HASH' || grep { my $f = $_; !grep { $_ eq $f } @fields } keys %$previous;
        for my $from ($row, $previous) {
            for my $field (@fields) {
                next unless exists($from->{$field});
                my $v = $from->{$field};
                die "Invalid merchant value\n" if !defined($v) || ref($v);
                die "Conflicting merchant configuration for $id\n" if exists($merged{$field}) && $merged{$field} ne $v;
                $merged{$field} = $v;
                $migrate = 1;
            }
        }
        if ($migrate) {
            SHM::Pay::Epay::Channels::validate(\%merged);
            save_account($db, $id, \%merged) unless pack_json(\%merged) eq pack_json($stored);
            delete @{$row}{@fields};
        }
        $row->{payment_url} //= '/shm/pay_systems/epay.cgi';
    }
    $db->do('UPDATE config SET value=? WHERE config.key=?', undef, JSON::PP->new->ascii->encode($catalog), 'pay_systems');
    $db->do('DELETE FROM config WHERE config.key=?', undef, 'epay_merchants') if defined $legacy;
}
sub prepare_directories {
    my ($data) = @_;
    my ($worker, $group) = (getpwnam('www-data'))[2,3];
    die "Missing payment worker\n" unless defined $worker;
    directory("$data/epay", 0700, $worker, $group);
    directory("$data/pay_systems", 0755, $worker, $group);
}
sub bootstrap {
    my ($db, $root, $fresh) = @_;
    return if $ENV{LEGACY_PAYSYSTEMS_PATH};
    my $data = "$root/data";
    my $public = "$data/pay_systems";
    my $target = "$root/pay_systems/epay/epay.cgi";
    my $owned = grep { (readlink("$public/$_") // '') eq $target } @entry;
    return unless $fresh || $owned;
    my $occupied = 0;
    if ($fresh && lstat("$data/epay")) {
        my @s = lstat("$data/epay");
        my $worker = (getpwnam('www-data'))[2];
        $occupied = !S_ISDIR($s[2]) || ($s[2] & 0777) != 0700 || !defined($worker) || $s[4] != $worker;
        if (!$occupied) {
            opendir(my $dir, "$data/epay") or die "Cannot inspect payment directory\n";
            $occupied = grep { $_ ne '.' && $_ ne '..' } readdir $dir;
            closedir $dir;
        }
    }
    if (!paths_free($public, $target) || $occupied) {
        warn encode_utf8("易支付预装已跳过，请核对共享卷中的现有支付入口和商户资料。\n");
        return;
    }
    die "Missing bundled payment entry\n" unless -f $target && -x $target;
    prepare_directories($data);
    publish($public, $target);
    # The managed links make an interrupted first initialization recognizable on restart.
    unless ($fresh) {
        my ($registered) = $db->selectrow_array(q{SELECT JSON_CONTAINS_PATH(value,'one','$.epay') FROM config WHERE config.key='pay_systems'});
        return if $registered;
    }
    local $db->{RaiseError} = 1;
    schema($db, dirname($target));
    registration($db);
    $db->commit;
}
sub standalone {
    my ($db, $source, $data) = @_;
    my $private = "$data/epay";
    my $public = "$data/pay_systems";
    die "SHM uses a different public payment directory\n" if $ENV{LEGACY_PAYSYSTEMS_PATH};
    my $target = '../epay/module/epay.cgi';
    die "Conflicting CGI entry\n" unless paths_free($public, $target);
    prepare_directories($data);
    # All standalone installations publish through this same directory.
    sysopen(my $serial, $public, O_RDONLY | O_NOFOLLOW) or die "Cannot open installer lock\n";
    flock($serial, LOCK_EX) or die "Cannot lock installer\n";
    die "Conflicting CGI entry\n" unless paths_free($public, $target);
    my $old = readlink("$private/module");
    die "Conflicting module location\n" if lstat("$private/module") && (!defined($old) || $old !~ m{\Areleases/[0-9a-f]{64}\z});
    my $hash = digest($source);
    my $release = "$private/releases/$hash";
    my ($worker, $group) = (getpwnam('www-data'))[2,3];
    directory("$private/releases", 0755, $worker, $group);
    if (!lstat($release)) {
        my $stage = tempdir('new-XXXXXXXX', DIR => "$private/releases", CLEANUP => 1);
        for my $file (@runtime) {
            my $out = "$stage/$file";
            make_path(dirname($out));
            copy("$source/$file", $out) or die "Cannot stage payment module\n";
        }
        chmod(0755, "$stage/epay.cgi") or die "Cannot publish payment CGI\n";
        # A root-run command installer must leave the release readable by the web worker.
        chmod(0755, $stage) or die "Cannot publish payment directory\n";
        die "Staged module differs\n" unless digest($stage) eq $hash;
        rename($stage, $release) or die "Cannot activate staged release\n";
    }
    die "Stored payment release differs\n" if -l $release || digest($release) ne $hash || !-x "$release/epay.cgi";
    local $db->{RaiseError} = 1;
    schema($db, $release);
    eval {
        registration($db);
        site_key($db);
        my $sample = $db->selectrow_hashref(q{SELECT * FROM epay_orders WHERE JSON_EXTRACT(profile_config,'$.credential_box') IS NOT NULL LIMIT 1});
        read_order($db, $sample) if $sample;
        $db->commit;
        1;
    } or do { my $error = $@; $db->rollback; die $error };
    if (($old // '') ne "releases/$hash") {
        my $tmp = tempdir('link-XXXXXXXX', DIR => $private, CLEANUP => 1);
        symlink("releases/$hash", "$tmp/module") && rename("$tmp/module", "$private/module") or die "Cannot activate payment release\n";
    }
    publish($public, $target);
    return $hash;
}
1;
