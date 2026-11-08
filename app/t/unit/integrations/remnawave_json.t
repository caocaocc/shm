use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Core::Integrations::Remnawave;

my $JSON = JSON::PP->new->canonical->utf8;
sub accepts {
    my ($body, $expected, $label) = @_;
    my $value;
    my $ok = eval {$value = Core::Integrations::Remnawave::_strict_json($body); 1};
    my $error = $@;
    ok($ok, $label);
    diag(Core::Integrations::Remnawave::_code($error)) unless $ok;
    is_deeply($value, $expected, 'JSON values decode once to the original Unicode structure');
}
sub rejects {
    my ($body, $label) = @_;
    my $ok = eval {Core::Integrations::Remnawave::_strict_json($body); 1};
    my $error = $@;
    ok(!$ok, $label);
    is(Core::Integrations::Remnawave::_code($error), 'REMOTE_RESPONSE', 'invalid input produces only a fixed safe code');
}

my $data = {response => {description => '中文说明 😀', '中文键' => {'😀' => '表情值'}, snippets => [
    {name => 'Out Users', snippet => [{tag => '中文标签', protocol => 'freedom', settings => {}}]},
    {name => '平台片段 😀', snippet => [{domain => ['regexp:^中文\\.example$', 'geosite:cn'],
        description => 'escaped "quote" \\ slash / 中文', nested => [JSON::PP::true, JSON::PP::false, undef, -123.5]}]},
]}};
my $bytes = $JSON->encode($data);
my $original = $bytes;
accepts($bytes, $data, 'literal Unicode keys and values parse from UTF-8 response bytes');
is($bytes, $original, 'validation does not consume or modify caller response bytes');
my $characters = decode('UTF-8', $bytes, FB_CROAK | LEAVE_SRC);
ok(utf8::is_utf8($characters), 'fixture also covers an already-decoded HTTP body');
accepts($characters, $data, 'already-decoded Unicode uses the same byte-coordinate scanner');
is($characters, decode('UTF-8', $original, FB_CROAK | LEAVE_SRC), 'validation does not consume the Unicode caller body');
my $escaped = $JSON->ascii->encode($data);
$JSON->ascii(0);
accepts($escaped, $data, 'escaped Unicode and surrogate pairs preserve the same values');

my $large = {response => {snippets => [map {{name => "中文片段 $_ 😀", snippet => [{type => 'field',
    domain => ['geosite:cn', 'regexp:^中文\\.example$'], description => '用户注释 "引号" / escaped',
    nested => {'中文' => '配置', array => [JSON::PP::true, JSON::PP::false, undef, -123.5e2]}}]}} 1..2000]}};
my $large_bytes = $JSON->encode($large);
cmp_ok(length($large_bytes), '>', 400_000, 'fixture covers a substantial valid multi-snippet response');
accepts($large_bytes, $large, 'complex multi-snippet UTF-8 response parses without offset drift');
accepts('{"first":{"中文":1},"second":{"中文":2}}', {first => {'中文' => 1}, second => {'中文' => 2}},
    'identical names in separate objects remain valid');

for my $duplicate ('{"id":1,"id":2}', '{"id":1,"\\u0069d":2}',
    '{"中文":1,"\\u4e2d\\u6587":2}', '{"😀":1,"\\ud83d\\ude00":2}') {
    rejects($duplicate, 'duplicate or escaped-equivalent key is rejected in a character body');
    rejects(encode('UTF-8', $duplicate, FB_CROAK | LEAVE_SRC), 'duplicate or escaped-equivalent key is rejected in a byte body');
}
for my $invalid ("\xff", "\xc0\xaf", "\x80", "\xed\xa0\x80", "\xe4\xb8") {
    rejects('{"response":{"label":"' . $invalid . '"}}', 'invalid UTF-8 bytes are rejected before JSON scanning');
}
rejects('{"label":"' . chr(0xd800) . '"}', 'an invalid Unicode surrogate scalar is rejected before encoding');
for my $malformed ('{"a":1} trailing', '{"a":1,}', '{"a":NaN}', '{"a":"unterminated}', '{"a":"\\q"}') {
    rejects($malformed, 'trailing data and malformed JSON remain rejected');
}
my $depth_128 = ('[' x 128) . '0' . (']' x 128);
my $depth_ok = eval {Core::Integrations::Remnawave::_strict_json($depth_128); 1};
ok($depth_ok, 'existing maximum nesting depth remains accepted');
rejects(('[' x 129) . '0' . (']' x 129), 'nesting beyond the existing depth limit is rejected');
rejects('"' . ('x' x (16 * 1024 * 1024)) . '"', 'oversized byte responses remain rejected');
rejects('"' . ('中' x 5_592_406) . '"', 'size limit applies to encoded bytes even for a shorter Unicode scalar');

done_testing();
