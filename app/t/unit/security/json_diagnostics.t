use v5.14;
use strict;
use warnings;
use Test::More;
use Core::Utils qw(decode_json encode_json encode_json_perl);

{
    package SafeJsonLogger;
    sub warning {push @{$_[0]{messages}}, $_[1]}
    package PrivateJsonObject;
    use overload '""' => sub {'synthetic-private-json-marker'}, fallback => 1;
}
my $logger = bless {messages => []}, 'SafeJsonLogger';
{
    no warnings 'redefine';
    local *Core::Utils::get_service = sub {$logger};
    local $@ = 'caller error context';
    my $decoded = decode_json('{"merchant_private_key":"synthetic-private-json-marker"');
    my $decode_error = $@;
    ok(!defined $decoded, 'malformed JSON remains rejected');
    is($decode_error, 'caller error context', 'parser exceptions do not escape through the global error variable');
    is_deeply($logger->{messages}, ['Invalid JSON input'], 'decode diagnostics are fixed and do not include raw input or parser excerpts');
    for my $encoder (\&encode_json, \&encode_json_perl) {
        $logger->{messages} = [];
        $@ = 'caller error context';
        my $private = bless {}, 'PrivateJsonObject';
        my $encoded = $encoder->($private);
        my $encode_error = $@;
        ok(!defined $encoded, 'unsupported JSON object remains rejected');
        is($encode_error, 'caller error context', 'serialization exceptions do not escape through the global error variable');
        is_deeply($logger->{messages}, ['JSON serialization failed'], 'serialization diagnostics do not stringify a secret-bearing object');
    }
    $logger->{messages} = [];
    is_deeply(decode_json('{"public":1}'), {public => 1}, 'ordinary JSON decoding is unchanged');
    is_deeply($logger->{messages}, [], 'valid data produces no failure diagnostic');
}
done_testing();
