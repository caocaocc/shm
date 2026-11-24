package SHM::Pay::Epay::Vault;
use v5.14;
use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode :flock O_NOFOLLOW);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use MIME::Base64 qw(encode_base64 decode_base64);
use Exporter 'import';
our @EXPORT_OK = qw(pack_json unpack_json site_key account_values save_account seal_order read_order);
my $codec = JSON::PP->new->utf8->canonical;
sub pack_json { $codec->encode($_[0]) }
sub unpack_json { utf8::is_utf8($_[0]) ? JSON::PP->new->decode($_[0]) : $codec->decode($_[0]) }

sub site_key {
    my ($db) = @_;
    require Crypt::PRNG;
    my $directory = ($ENV{SHM_ROOT_DIR} || '/app').'/data/epay';
    my $worker = (getpwnam('www-data'))[2] // $>;
    my @info = lstat($directory);
    die "Unsafe payment directory\n" unless @info && S_ISDIR($info[2]) && ($info[2] & 0777) == 0700 && $info[4] == $worker;
    my $guard;
    sysopen($guard, $directory, O_RDONLY | O_NOFOLLOW) && flock($guard, LOCK_EX) or die "Cannot lock payment directory\n";
    my $path = "$directory/key";
    unless (lstat($path)) {
        my ($in_use) = $db->selectrow_array(q{SELECT EXISTS(SELECT 1 FROM epay_accounts)
            OR EXISTS(SELECT 1 FROM epay_orders WHERE JSON_EXTRACT(profile_config,'$.credential_box') IS NOT NULL)});
        die "Restore the existing payment key\n" unless defined($in_use) && !$in_use;
        my ($out, $temporary) = tempfile('key.XXXXXXXX', DIR => $directory, UNLINK => 1);
        binmode $out;
        print {$out} Crypt::PRNG::random_bytes(32) or die "Cannot write payment key\n";
        chown($worker, -1, $temporary) or die "Cannot set key ownership\n" if $> == 0;
        close($out) && rename($temporary, $path) or die "Cannot publish payment key\n";
    }
    sysopen(my $in, $path, O_RDONLY | O_NOFOLLOW) or die "Cannot open payment key\n";
    @info = stat($in);
    die "Unsafe payment key\n" unless S_ISREG($info[2]) && ($info[2] & 0777) == 0600 && $info[3] == 1
        && $info[4] == $worker && $info[7] == 32;
    binmode $in;
    my $key;
    read($in, $key, 33) == 32 or die "Incomplete payment key\n";
    return $key;
}

sub envelope {
    my ($key, $aad, $data) = @_;
    require Crypt::AuthEnc::GCM;
    require Crypt::PRNG;
    my $iv = Crypt::PRNG::random_bytes(12);
    my ($ciphertext, $tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES', $key, $iv, $aad, pack_json($data));
    return encode_base64($iv.$ciphertext.$tag, '');
}
sub cleartext {
    my ($key, $aad, $box) = @_;
    require Crypt::AuthEnc::GCM;
    my $bytes = decode_base64($box // '');
    die "Invalid merchant snapshot\n" unless length($bytes) > 28 && encode_base64($bytes, '') eq $box;
    my ($iv, $ciphertext, $tag) = (substr($bytes, 0, 12), substr($bytes, 12, length($bytes) - 28), substr($bytes, -16));
    my $result = Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES', $key, $iv, $aad, $ciphertext, $tag);
    die "Invalid merchant snapshot\n" unless defined $result;
    return unpack_json($result);
}
sub account_values {
    my ($db, $name, $box) = @_;
    return unless defined $box;
    return cleartext(site_key($db), "SHM:epay:account:1:$name", $box);
}
sub save_account {
    my ($db, $name, $values) = @_;
    if (!keys %$values) {
        $db->do('DELETE FROM epay_accounts WHERE profile=?', undef, $name);
        return;
    }
    my $box = envelope(site_key($db), "SHM:epay:account:1:$name", $values);
    $db->do('INSERT INTO epay_accounts(profile,credential_box) VALUES(?,?) ON DUPLICATE KEY UPDATE credential_box=?',
        undef, $name, $box, $box);
}
sub order_context {
    my ($row, $metadata) = @_;
    my @fields = qw(amount_cents currency gateway_id key_version out_trade_no payment_type pid profile protocol user_id);
    my %identity = map { $_ => defined($row->{$_}) ? "$row->{$_}" : '' } @fields;
    return 'SHM:epay:credentials:1:'.pack_json({identity => \%identity, profile => $metadata});
}
sub seal_order {
    my ($db, $row, $profile, $secrets) = @_;
    my $metadata = { %$profile, credential_box => envelope(site_key($db), order_context($row, $profile), $secrets) };
    my $bytes = pack_json($metadata);
    return (JSON::PP->new->ascii->canonical->encode($metadata), sha256_hex($bytes));
}
sub read_order {
    my ($db, $row) = @_;
    my $metadata = unpack_json($row->{profile_config});
    die "Order snapshot changed\n" unless sha256_hex(pack_json($metadata)) eq $row->{config_fingerprint};
    my $box = delete $metadata->{credential_box};
    return {%$metadata, %{cleartext(site_key($db), order_context($row, $metadata), $box)}};
}
1;
