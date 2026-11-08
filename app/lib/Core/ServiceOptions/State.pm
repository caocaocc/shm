package Core::ServiceOptions::State;

use v5.14;
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use Errno qw(ENOENT);
use Digest::SHA qw(sha256_hex);
use Crypt::PRNG qw(random_bytes);
use Encode qw(encode_utf8);
use IO::Handle ();
use JSON::PP ();
use Core::Utils qw(encrypt_aes256_gcm_base64 decrypt_aes256_gcm_base64);

my $JSON = JSON::PP->new->canonical->utf8;
my $MAX_BYTES = 16 * 1024 * 1024;

# A scope identifies a remote resource, not a SHM server record. Different
# server records operating on the same resource must use the same scope.
sub new {
    my ($class, %args) = @_;
    my $scope = $args{scope};
    die "Invalid service options state scope\n" unless defined($scope) && !ref($scope)
        && length($scope) && length($scope) <= 8192 && $scope !~ /[\x00-\x1f]/;
    my $controller = $args{controller} or die "Service options state requires a controller\n";
    my $bytes = encode_utf8($scope);
    my $name = 'state-' . sha256_hex($bytes);
    my $lock = $controller->_open_lock($name);
    flock($lock, LOCK_EX | LOCK_NB) or die "SERVICE_OPTIONS_BUSY\n";
    return bless {controller => $controller, lock => $lock,
        path => $controller->_directory . "/$name.json",
        aad => 'shm:service-options-state:' . $bytes}, $class;
}

sub _open {
    my ($self) = @_;
    die "Service options state is closed\n" unless $self->{lock};
}

sub load {
    my ($self) = @_;
    $self->_open;
    unless (sysopen(my $in, $self->{path}, O_RDONLY | O_NOFOLLOW)) {
        return undef if $! == ENOENT;
        die "Cannot open service options state\n";
    } else {
        Core::ServiceOptions::_secure_file($in);
        die "Service options state is too large\n" if (stat($in))[7] > $MAX_BYTES;
        binmode $in;
        my $encoded = do {local $/; <$in>};
        close($in) or die "Cannot close service options state\n";
        my $envelope = $JSON->decode($encoded);
        die "Invalid service options state\n" unless ref($envelope) eq 'HASH'
            && !ref($envelope->{version}) && ($envelope->{version} // '') eq '1'
            && defined($envelope->{box}) && !ref($envelope->{box});
        my $plain = decrypt_aes256_gcm_base64($envelope->{box}, $self->{controller}->_key, $self->{aad});
        my $value = $JSON->decode($plain);
        die "Invalid service options state\n" unless ref($value) eq 'HASH';
        return $value;
    }
}

sub _check_existing {
    my ($self) = @_;
    return unless -e $self->{path} || -l $self->{path};
    sysopen(my $in, $self->{path}, O_RDONLY | O_NOFOLLOW) or die "Unsafe service options state\n";
    Core::ServiceOptions::_secure_file($in);
    close $in;
}

sub _sync_directory {
    my ($self) = @_;
    sysopen(my $dir, $self->{controller}->_directory, O_RDONLY | O_NOFOLLOW)
        or die "Cannot open service options state directory\n";
    $dir->sync or die "Cannot synchronize service options state directory\n";
    close($dir) or die "Cannot close service options state directory\n";
}

sub save {
    my ($self, $value) = @_;
    $self->_open;
    die "Invalid service options state\n" unless ref($value) eq 'HASH';
    $self->_check_existing;
    my $plain = $JSON->encode($value);
    die "Service options state is too large\n" if length($plain) > $MAX_BYTES / 2;
    my $envelope = $JSON->encode({version => 1,
        box => encrypt_aes256_gcm_base64($plain, $self->{controller}->_key, $self->{aad})});
    my $temp = $self->{path} . '.' . unpack('H*', random_bytes(12));
    sysopen(my $out, $temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        or die "Cannot create service options state\n";
    my $ok = eval {
        Core::ServiceOptions::_secure_file($out);
        binmode $out;
        print {$out} $envelope or die "Cannot write service options state\n";
        $out->sync or die "Cannot synchronize service options state\n";
        close($out) or die "Cannot close service options state\n";
        rename($temp, $self->{path}) or die "Cannot publish service options state\n";
        $self->_sync_directory;
        1;
    };
    unless ($ok) { close $out; unlink $temp; die "Cannot save service options state\n" }
    return 1;
}

sub clear {
    my ($self) = @_;
    $self->_open;
    $self->_check_existing;
    if (-e $self->{path}) {
        unlink($self->{path}) or die "Cannot clear service options state\n";
        $self->_sync_directory;
    }
    return 1;
}

sub close {
    my ($self) = @_;
    my $lock = delete $self->{lock};
    return 1 unless $lock;
    close($lock) or die "Cannot release service options state lock\n";
    return 1;
}

sub DESTROY { local $@; eval {$_[0]->close} }

1;
