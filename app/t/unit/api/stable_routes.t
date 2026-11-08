use v5.14;
use strict;
use warnings;
use Test::More;
use FindBin;
use Text::Balanced qw(extract_codeblock);

# Run the stable CGI schemas and its real validator without initializing SHM
# or making registration, database, or network requests.
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
    my ($path, $method) = @_;
    my $block = source_block(qr/'\Q$path\E'\s*=>\s*/);
    my $route = eval "+$block";
    BAIL_OUT("Cannot load CGI route: $@") unless ref $route eq 'HASH';
    return $route->{$method}{params};
}

my $body = source_block(qr/sub\s+validate_params\s*/);
my $validate = eval "sub $body";
BAIL_OUT("Cannot load CGI validator: $@") unless ref $validate eq 'CODE';
my $registration = route_schema('/user', 'PUT');
my $topology = route_schema('/admin/topology', 'GET');

sub check_input {
    my ($schema, $args) = @_;
    my %allowed = map { $_ => 1 } keys %$schema;
    return $validate->($schema, $args, \%allowed);
}

is(check_input($registration, {login => 'stable-user', password => 'abc123'}), undef,
    'stable registration accepts a six-character password');
like(check_input($registration, {login => 'stable-user', password => 'abc12'}),
    qr/Field 'password' must be at least 6 characters/, 'five-character password stays invalid');
like(check_input($registration, {login => 'stable-user'}), qr/Field required: password/,
    'registration still requires a password');
like(check_input($registration, {login => 'stable-user', password => 'a' x 129}),
    qr/Field 'password' must be at most 128 characters/, 'password upper bound is preserved');

my $graph_input = {event => 'changed_tariff', refresh => 'true'};
is(check_input($topology, $graph_input), undef, 'topology accepts a machine event name and refresh flag');
is($graph_input->{refresh}, 1, 'topology refresh uses the actual boolean normalization');
like(check_input($topology, {event => 'create/drop'}), qr/Field 'event' has an invalid format/,
    'topology rejects an invalid event filter');
like(check_input($topology, {refresh => 'yes'}), qr/Field 'refresh' must be 0 or 1/,
    'topology rejects an invalid refresh flag');
is(check_input($topology, {}), undef, 'topology supports its unfiltered graph request');

done_testing();
