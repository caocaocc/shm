package Core::Routing::Store;
use v5.14;
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock :mode);
use Crypt::AuthEnc::GCM ();
use Crypt::PRNG qw(random_bytes);
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use JSON::PP ();
use MIME::Base64 qw(encode_base64 decode_base64);
use URI ();

our $DIRECTORY = ($ENV{SHM_ROOT_DIR} || '/app') . '/data/routing-templates';
our $JSON = JSON::PP->new->canonical->utf8;
sub decode {
    my ($data) = @_;
    return (utf8::is_utf8($data) ? JSON::PP->new : $JSON)->decode($data);
}

sub key {
    my ($db, $create) = @_;
    sysopen(my $guard, "$DIRECTORY/key.lock", O_NOFOLLOW | O_RDWR | O_CREAT, 0600) or die "KEY_UNAVAILABLE\n";
    flock($guard, LOCK_EX) or die "KEY_UNAVAILABLE\n";
    my $path = "$DIRECTORY/key";
    unless (-e $path) {
        die "KEY_UNAVAILABLE\n" unless $create && !-l $path;
        my ($exists) = $db->selectrow_array(q{
            SELECT EXISTS(SELECT 1 FROM storage
                WHERE user_id=0 AND (name LIKE 'routing:%' OR name LIKE 'routingp:%'))
        });
        die "KEY_UNAVAILABLE\n" if !defined($exists) || $exists;
        # A partial key must never become visible to another process.
        my $temp = "$path.$$." . unpack('H*', random_bytes(6));
        sysopen(my $new, $temp, O_CREAT | O_EXCL | O_WRONLY, 0600) or die "KEY_UNAVAILABLE\n";
        binmode $new;
        print {$new} random_bytes(32) or die "KEY_UNAVAILABLE\n";
        close($new) && rename($temp, $path) or die "KEY_UNAVAILABLE\n";
    }
    sysopen(my $fh, $path, O_NOFOLLOW | O_RDONLY) or die "KEY_UNAVAILABLE\n";
    my @info = stat($fh);
    my $permissions = $info[2] & 0777;
    die "KEY_UNAVAILABLE\n" unless S_ISREG($info[2]) && $info[7] == 32 &&
        ($permissions == 0600 || $permissions == 0400);
    binmode $fh;
    local $/;
    my $key = <$fh>;
    die "KEY_UNAVAILABLE\n" unless defined $key && length($key) == 32;
    return $key;
}

sub pack_record {
    my ($db, $owner, $id, $record) = @_;
    my $nonce = random_bytes(12);
    my ($cipher, $tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES', key($db, 1), $nonce,
        "routing:$owner:$id", $JSON->encode($record));
    return encode_base64($nonce . $cipher . $tag, '');
}

sub record {
    my ($db, $owner, $id, $lock) = @_;
    my ($box) = $db->selectrow_array('SELECT data FROM storage WHERE user_id=0 AND name=?' . ($lock ? ' FOR UPDATE' : ''), undef, "routing:$id");
    die "STORAGE_FAILED\n" if $db->err;
    return unless defined $box;
    my $bytes = decode_base64($box);
    die "STORAGE_FAILED\n" if length($bytes) < 29;
    my ($iv, $cipher, $tag) = unpack('a12a' . (length($bytes) - 28) . 'a16', $bytes);
    my $key = key($db, 0);
    my $text = Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES', $key, $iv, "routing:$owner:$id", $cipher, $tag);
    die "STORAGE_FAILED\n" unless defined $text;
    my $record = eval { $JSON->decode($text) };
    die "STORAGE_FAILED\n" unless ref($record) eq 'HASH';
    return ($record, $box);
}

sub write_record {
    my ($db, $owner, $id, $record) = @_;
    $db->do('INSERT INTO storage(user_id,name,data) VALUES(0,?,?) ON DUPLICATE KEY UPDATE data=VALUES(data)',
        undef, "routing:$id", pack_record($db, $owner, $id, $record)) or die "STORAGE_FAILED\n";
}

sub service {
    my ($db, $id, $lock) = @_;
    my $row = $db->selectrow_hashref(q{SELECT user_id,status,settings->>'$.server_id' AS server_id FROM user_services WHERE user_service_id=?} .
        ($lock ? ' FOR UPDATE' : ''), undef, $id);
    die "STORAGE_FAILED\n" if $db->err;
    return $row;
}

sub endpoint {
    my ($url) = @_;
    my $uri = eval { URI->new($url)->canonical };
    die "TARGET_UNAVAILABLE\n" unless $uri && $uri->scheme && $uri->scheme =~ /\Ahttps?\z/ && $uri->host
        && !defined($uri->userinfo) && !defined($uri->query) && !defined($uri->fragment);
    my $path = $uri->path // '';
    $path =~ s{/+\z}{};
    $path =~ s{/api\z}{};
    $uri->path($path);
    return "$uri";
}

sub panel {
    my ($db, $server) = @_;
    return unless $server && $server =~ /\A[1-9][0-9]*\z/;
    my ($raw) = $db->selectrow_array('SELECT settings FROM servers WHERE server_id=?', undef, $server);
    die "STORAGE_FAILED\n" if $db->err;
    my $cfg = $raw ? decode($raw)->{remnawave} : undef;
    return unless ref($cfg) eq 'HASH' && !ref($cfg->{token}) && length($cfg->{token} // '') && length($cfg->{api} // '');
    return {url => endpoint($cfg->{api}), token => $cfg->{token}};
}

sub control_name { 'routingp:' . substr($_[0], 0, 23) }

sub control {
    my ($db, $scope, $lock) = @_;
    my ($raw) = $db->selectrow_array('SELECT data FROM storage WHERE user_id=0 AND name=?' . ($lock ? ' FOR UPDATE' : ''), undef, control_name($scope));
    die "STORAGE_FAILED\n" if $db->err;
    return unless defined $raw;
    my $control = decode($raw);
    die "STORAGE_FAILED\n" unless ($control->{scope} // '') eq $scope && ref($control->{pending}) eq 'HASH';
    return $control;
}

sub update_control {
    my ($db, $control) = @_;
    $db->do('UPDATE storage SET data=? WHERE user_id=0 AND name=?', undef, $JSON->encode($control), control_name($control->{scope}))
        or die "STORAGE_FAILED\n";
}

sub tag_prefix { 'SHM_ROUTING_' . substr(hmac_sha256_hex('managed-tag', key($_[0], 0)), 0, 20) . '_us_' }
1;
