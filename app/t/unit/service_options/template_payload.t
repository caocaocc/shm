use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use Core::Template;
use Core::Spool;
use MIME::Base64 qw(decode_base64url);
use JSON::PP ();

local $ENV{SHM_TEST} = 1;
my $template = Core::Template->new;
my $input = {items => [{user_id => 1, data => {label => '中文规则'}, secret => {value => '私密内容'}}]};
my $encoded = $template->parse(data => '{{ toBase64Url(toJson(payload)) }}', vars => {payload => $input});
like($encoded, qr/\A[A-Za-z0-9_-]+\z/, 'template payload uses only unpadded Base64URL characters');
my $decoded = JSON::PP->new->utf8->decode(decode_base64url($encoded));
is_deeply($decoded, $input, 'actual template JSON/Base64 helpers preserve UTF-8 secret and public text');
my $bytes = "\xff\x00\x80";
is(decode_base64url($template->parse(data => '{{ toBase64Url(blob) }}', vars => {blob => $bytes})),
    $bytes, 'existing byte-string Base64URL semantics remain unchanged');


done_testing();
