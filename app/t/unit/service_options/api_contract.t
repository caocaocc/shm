use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use Text::Balanced qw(extract_codeblock);
use JSON ();
use URI ();

open my $file, '<:encoding(UTF-8)', "$FindBin::Bin/../../../public_html/shm/v1.cgi" or die $!;
my $source = do {local $/; <$file>};
sub block {
    my ($anchor) = @_;
    my ($tail) = $source =~ /$anchor(\{.*)\z/s;
    BAIL_OUT('actual CGI source block missing') unless defined $tail;
    my ($block) = extract_codeblock($tail, '{}');
    return $block;
}
my $route = eval '+' . block(qr/'\/user\/service\/options'\s*=>\s*/);
die $@ if $@;
my $strict = eval 'sub ' . block(qr/sub\s+strict_params_error\s*/); die $@ if $@;
my $validate = eval 'sub ' . block(qr/sub\s+validate_params\s*/); die $@ if $@;
ok($route->{strict_params}, 'configuration route opts into strict top-level parameters');
ok($route->{sensitive_args}, 'configuration route opts into quiet sensitive body parsing');
is($route->{POST}{controller}, 'ServiceOptions', 'save dispatches to the generic controller');
my $schema = $route->{POST}{params};
for my $value (JSON::true, JSON::false, 0, 1) {
    my $input = {user_service_id => 1, enabled => $value};
    is($strict->($schema, $input), undef, 'JSON booleans and 0/1 are accepted before normalization');
    is($validate->($schema, $input, {}), undef, 'valid switch reaches the actual existing validator');
}
for my $literal ('false', '0', 'true', '1') {
    my $input = JSON->new->utf8->decode('{"user_service_id":1,"enabled":' . $literal . '}');
    is($strict->($schema, $input), undef, 'real JSON decoder value passes strict validation: ' . $literal);
    is($validate->($schema, $input, {}), undef, 'decoded boolean is normalized before required-value validation: ' . $literal);
    is($input->{enabled}, $literal eq 'false' || $literal eq '0' ? 0 : 1, 'normalized switch is a numeric 0 or 1');
}
for my $literal ('{}', '[]') {
    my $input = JSON->new->utf8->decode('{"user_service_id":1,"enabled":' . $literal . '}');
    ok($strict->($schema, $input), 'real JSON decoder non-boolean object is rejected: ' . $literal);
}
for my $value ({}, [], 'true', 'false', undef, 2) {
    like($strict->($schema, {user_service_id => 1, enabled => $value}), qr/服务选项请求参数无效/,
        'arbitrary references and non-boolean switches are rejected before coercion');
}
my $unknown = 'do-not-log-secret-field';
my $error = $strict->($schema, {user_service_id => 1, enabled => 1, $unknown => 'do-not-log-secret-value'});
is($error, '服务选项请求参数无效', 'unknown fields fail with a fixed safe message');
unlike($error, qr/do-not-log/, 'strict validation does not echo an attacker-controlled field or value');
is($strict->($schema, {user_service_id => 1, enabled => 1, data => {}, secret => {anything => 'private'}}),
    undef, 'generic secret object may contain adapter-defined secret keys');

my $secret_route = eval '+' . block(qr/'\/user\/service\/options\/secret'\s*=>\s*/); die $@ if $@;
ok($secret_route->{strict_params} && $secret_route->{sensitive_args}, 'owner secret route uses strict and quiet request handling');
is_deeply([sort grep {/\A(?:GET|POST|PUT|DELETE)\z/} keys %$secret_route], ['POST'], 'secret retrieval is POST only');
is($secret_route->{POST}{method}, 'secret_for_api', 'secret route uses the owner-only controller method');
my $secret_schema = $secret_route->{POST}{params};
is($strict->($secret_schema, {user_service_id => 1}), undef, 'secret retrieval accepts only the purchased instance ID');
ok($strict->($secret_schema, {user_service_id => 1, user_id => 2}), 'secret retrieval cannot select or impersonate another owner');
ok($strict->($secret_schema, {user_service_id => 1, format => 'json'}), 'secret retrieval cannot bypass its normal response envelope');
ok($validate->($secret_schema, {user_service_id => 0}, {}), 'secret retrieval rejects invalid IDs');

my $origin = eval 'sub ' . block(qr/sub\s+secret_request_origin_error\s*/); die $@ if $@;
for my $case (
    [{HTTP_HOST => 'client.example', HTTP_ORIGIN => 'https://client.example', HTTP_X_FORWARDED_PROTO => 'https', HTTP_SEC_FETCH_SITE => 'same-origin'}, 1, 'TLS reverse proxy preserves the original scheme'],
    [{HTTP_HOST => 'client.example:443', HTTP_ORIGIN => 'https://client.example', HTTP_X_FORWARDED_PROTO => 'https'}, 1, 'default TLS port is equivalent'],
    [{HTTP_HOST => 'CLIENT.EXAMPLE', HTTP_ORIGIN => 'http://client.example:80'}, 1, 'host casing and default HTTP port are equivalent'],
    [{HTTP_HOST => '[::1]:8080', HTTP_ORIGIN => 'http://[::1]:8080'}, 1, 'IPv6 same-origin requests remain usable'],
    [{HTTP_HOST => 'client.example', HTTP_ORIGIN => 'https://client.example:19125', HTTP_X_FORWARDED_PROTO => 'https', HTTP_SEC_FETCH_SITE => 'same-origin'}, 1, 'official proxy may strip the same-origin browser port'],
    [{HTTP_HOST => 'client.example', HTTP_ORIGIN => 'https://client.example:19125', HTTP_X_FORWARDED_PROTO => 'https'}, 0, 'without browser metadata a missing Host port cannot be inferred'],
    [{HTTP_HOST => 'client.example:443', HTTP_ORIGIN => 'https://client.example:19125', HTTP_X_FORWARDED_PROTO => 'https', HTTP_SEC_FETCH_SITE => 'same-origin'}, 0, 'explicit Host port remains authoritative'],
    [{}, 1, 'non-browser authenticated clients need no Origin'],
    [{HTTP_HOST => 'client.example', HTTP_ORIGIN => 'https://evil.example', HTTP_X_FORWARDED_PROTO => 'https'}, 0, 'cross-origin reads are denied'],
    [{HTTP_HOST => 'client.example', HTTP_ORIGIN => 'null'}, 0, 'opaque origins are denied'],
    [{HTTP_HOST => 'client.example', HTTP_ORIGIN => 'https://evil.example', HTTP_X_FORWARDED_HOST => 'evil.example', HTTP_X_FORWARDED_PROTO => 'https'}, 0, 'forwarded host cannot authorize a different origin'],
    [{HTTP_SEC_FETCH_SITE => 'same-site'}, 0, 'same-site subdomains are not same-origin'],
    [{HTTP_SEC_FETCH_SITE => 'cross-site'}, 0, 'cross-site browser reads are denied even without Origin'],
    [{HTTP_HOST => 'client.example', HTTP_ORIGIN => 'https://client.example/path', HTTP_X_FORWARDED_PROTO => 'https'}, 0, 'non-origin URL syntax is denied'],
) {
    local %ENV = %{$case->[0]};
    is(!$origin->() ? 1 : 0, $case->[1], $case->[2]);
}

done_testing();
