use v5.14;
use strict;
use warnings;

use Test::More;
use FindBin;
use Text::Balanced qw(extract_codeblock);

# Exercise the CGI's actual route schemas and validator without bootstrapping
# SHM, connecting to its database, or enqueuing a real SSH command.
open my $file, '<', "$FindBin::Bin/../../../public_html/shm/v1.cgi"
    or die "Cannot read v1.cgi: $!";
my $source = do { local $/; <$file> };
close $file;

sub source_block {
    my ($anchor) = @_;
    my ($tail) = $source =~ /$anchor(\{.*)\z/s;
    BAIL_OUT('Cannot locate CGI source block') unless defined $tail;
    my ($block) = extract_codeblock($tail, '{}');
    BAIL_OUT('Cannot extract CGI source block') unless defined $block && length $block;
    return $block;
}

sub route_schema {
    my ($action) = @_;
    my $path = "/admin/transport/ssh/$action";
    my $block = source_block(qr/'\Q$path\E'\s*=>\s*/);
    my $route = eval "+$block";
    BAIL_OUT("Cannot load SSH route: $@") unless ref $route eq 'HASH';
    return $route->{PUT}{params};
}

my $validator_body = source_block(qr/sub\s+validate_params\s*/);
my $validate = eval "sub $validator_body";
BAIL_OUT("Cannot load CGI validator: $@") unless ref $validate eq 'CODE';
my $test_schema = route_schema('test');
my $init_schema = route_schema('init');

sub validation_error {
    my ($schema, %args) = @_;
    my %allowed = map { $_ => 1 } keys %$schema;
    return $validate->($schema, \%args, \%allowed);
}

my %connection = (host => 'root@192.0.2.10', key_id => 1);
is(validation_error($test_schema, %connection), undef,
    'legacy TEST payload and an unsaved server do not require server_id');
is(validation_error($test_schema, %connection, server_id => 7), undef,
    'saved-server TEST payload accepts a positive server_id');
like(validation_error($test_schema, %connection, server_id => 0),
    qr/Field 'server_id' must be >= 1/, 'provided zero server_id is rejected');
like(validation_error($test_schema, %connection, server_id => ''),
    qr/Field 'server_id' must be an integer/, 'provided empty server_id is rejected');
like(validation_error($test_schema, %connection, server_id => 'not-an-id'),
    qr/Field 'server_id' must be an integer/, 'provided noninteger server_id is rejected');
like(validation_error($init_schema, %connection), qr/Field required: server_id/,
    'INIT continues to require a saved server_id');
is(validation_error($init_schema, %connection, server_id => 7), undef,
    'INIT still accepts its existing valid payload');
like(validation_error($test_schema, key_id => 1), qr/Field required: host/,
    'TEST continues to require host');
like(validation_error($test_schema, host => '', key_id => 1), qr/Field required: host/,
    'TEST rejects an empty host');
like(validation_error($test_schema, host => $connection{host}), qr/Field required: key_id/,
    'TEST continues to require key_id');
like(validation_error($test_schema, %connection, key_id => 0),
    qr/Field 'key_id' must be >= 1/, 'TEST rejects a zero key_id');
like(validation_error($test_schema, %connection, key_id => 'not-an-id'),
    qr/Field 'key_id' must be an integer/, 'TEST rejects a noninteger key_id');

done_testing();
