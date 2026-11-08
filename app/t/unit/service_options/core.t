use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use Encode ();
use POSIX ();
use Core::ServiceOptions;
use Core::Logs::Api;
use Core::Utils qw(encrypt_aes256_gcm_base64 decrypt_aes256_gcm_base64);

my $root = tempdir(CLEANUP => 1);
my $encrypted_records_exist = 0;
no warnings 'redefine';
local *Core::ServiceOptions::_has_encrypted_secrets = sub {$encrypted_records_exist};
local $ENV{SHM_ROOT_DIR} = $root;
my $controller = bless {}, 'Core::ServiceOptions';
my $key = $controller->_key;
is(length($key), 32, 'a full AES-256 key is generated');
is($controller->_key, $key, 'key is durable and never regenerated on normal reads');
is((stat("$root/data/service-options"))[2] & 0777, 0700, 'key directory is private');
is((stat("$root/data/service-options/key"))[2] & 0777, 0600, 'key file is private');
is((stat("$root/data/service-options/key"))[7], 32, 'published key has its complete atomic content');
is((stat("$root/data/service-options/key"))[4], Core::ServiceOptions::_storage_uid(), 'root-created key is owned by the API/spool service account');
chmod 0644, "$root/data/service-options/key";
ok(!eval {$controller->_key; 1}, 'insecure existing key permissions fail closed');
chmod 0600, "$root/data/service-options/key";
rename "$root/data/service-options/key", "$root/key-backup" or die $!;
symlink "$root/key-backup", "$root/data/service-options/key" or die $!;
ok(!eval {$controller->_key; 1}, 'key symlink is rejected');
unlink "$root/data/service-options/key";
rename "$root/key-backup", "$root/data/service-options/key" or die $!;
link "$root/data/service-options/key", "$root/key-link" or die $!;
ok(!eval {$controller->_key; 1}, 'key hardlink is rejected');
unlink "$root/key-link";
rename "$root/data/service-options/key", "$root/key-backup" or die $!;
$encrypted_records_exist = 1;
ok(!eval {$controller->_key; 1}, 'missing key is not regenerated while encrypted records exist');
like($@, qr/\ASERVICE_OPTIONS_KEY_MISSING/, 'missing key has a fixed recoverable error');
ok(!-e "$root/data/service-options/key", 'no replacement key is published');
rename "$root/key-backup", "$root/data/service-options/key" or die $!;
$encrypted_records_exist = 0;

subtest 'root initialization remains usable after the application drops to www-data' => sub {
    plan skip_all => 'requires isolated root test process' unless $> == 0;
    my $production_root = tempdir(CLEANUP => 1);
    chmod 0755, $production_root;
    mkdir "$production_root/data", 0755 or die $!;
    local $ENV{SHM_ROOT_DIR} = $production_root;
    Core::ServiceOptions->initialize_storage;
    my $root_key = $controller->_key;
    my $uid = Core::ServiceOptions::_storage_uid();
    is((stat("$production_root/data/service-options"))[4], $uid, 'root initialization assigns the private directory to the runtime account');
    pipe(my $reader, my $writer) or die $!;
    my $pid = fork(); die $! unless defined $pid;
    unless ($pid) {
        close $reader;
        POSIX::setgid($uid) == 0 or POSIX::_exit(2);
        POSIX::setuid($uid) == 0 or POSIX::_exit(3);
        my $ok = eval {$controller->_key eq $root_key};
        print {$writer} $ok ? 'OK' : 'FAIL'; close $writer;
        POSIX::_exit($ok ? 0 : 4);
    }
    close $writer;
    my $result = do {local $/; <$reader>}; close $reader;
    waitpid($pid, 0);
    is($? >> 8, 0, 'the real uid33 process can reopen the root-initialized key');
    is($result, 'OK', 'API/spool and root management read exactly the same key');
};

my $cipher = encrypt_aes256_gcm_base64('private-secret', $key, 'owner:service');
unlike($cipher, qr/private-secret/, 'ciphertext does not contain the plaintext');
is(decrypt_aes256_gcm_base64($cipher, $key, 'owner:service'), 'private-secret', 'authenticated encryption round trips');
ok(!eval {decrypt_aes256_gcm_base64($cipher, $key, 'other-owner:service'); 1}, 'owner/service authentication data cannot be changed');
my $tampered = $cipher;
substr($tampered, 20, 1) = substr($tampered, 20, 1) eq 'A' ? 'B' : 'A';
ok(!eval {decrypt_aes256_gcm_base64($tampered, $key, 'owner:service'); 1}, 'ciphertext tampering is rejected');
is(decrypt_aes256_gcm_base64(encrypt_aes256_gcm_base64('', $key), $key), '', 'empty plaintext remains a supported generic crypto value');
my $unicode = Encode::encode_utf8('私密中文');
is(decrypt_aes256_gcm_base64(encrypt_aes256_gcm_base64($unicode, $key), $key), $unicode, 'Unicode secret bytes survive authenticated encryption');

for my $input ({password => 'x'}, {nested => {private_key => 'x'}}, {pass => 'x'},
    {secret_key => 'x'}, {uri => 'https://name:password@example.test'},
    {text => '-----BEGIN PRIVATE KEY-----'}) {
    ok(!eval {Core::ServiceOptions::_no_secrets_in_data($input); 1}, 'public data rejects a recognizable credential value');
}
ok(eval {Core::ServiceOptions::_no_secrets_in_data({rules => ['example.test'], port => 443}); 1}, 'ordinary generic public data is accepted');

my $receipt = {items => {12 => {state => 'submitted'}, 13 => {state => 'cleaned'}}};
is(Core::ServiceOptions::_results($receipt, [12,13])->{12}{state}, 'submitted', 'structured adapter receipt is validated');
ok(!eval {Core::ServiceOptions::_results($receipt, [12]); 1}, 'extra result identities are rejected');
ok(!eval {Core::ServiceOptions::_results($receipt, [12,13,14]); 1}, 'missing result identities are rejected');
ok(!eval {Core::ServiceOptions::_results('not-a-structured-result', []); 1}, 'unstructured results are never accepted');
ok(!eval {Core::ServiceOptions::_results({items => {12 => {state => 'anything'}}}, [12]); 1}, 'unknown adapter states are rejected');
is(Core::ServiceOptions::_results({items => {12 => {state => 'error', error => 'raw secret message'}}}, [12])->{12}{error},
    'SERVICE_OPTIONS_ERROR', 'untrusted error text is reduced to a fixed safe code');
is(Core::ServiceOptions::_adapter_class('example_adapter'), 'Core::Integrations::ExampleAdapter', 'short snake case maps generically to an installed integration class');
is(Core::ServiceOptions::_adapter_class('remnawave'), 'Core::Integrations::Remnawave', 'single-word names use the same generic mapping');
for my $name ('Transport::Ssh', 'Core::Integrations::Fixture', 'Integrations::Fixture', 'BadName', '../fixture', 'fixture;die', 'bad__name', undef) {
    ok(!Core::ServiceOptions::_adapter_class($name), 'invalid adapter names cannot select arbitrary modules or aliases');
}

{
    no warnings 'redefine';
    my $captured;
    local *Core::Base::add = sub {my ($self, %args) = @_; $captured = \%args; return 1};
    my $logs = bless {user_id => 42, res => {}}, 'Core::Logs::Api';
    for my $path ('/user/service/options', '/user/service/options/secret', '/admin/user/service/options', '/admin/user/service/options/retry') {
        $logs->add(url => $path, args => {PUTDATA => '{"custom":"raw-secret"}', secret => {unknown_field => 'private-secret'}});
        is_deeply($captured->{args}, {redacted => 1}, 'sensitive endpoint masks the entire request, including raw and unknown secret fields');
    }
    $logs->add(url => '/user/auth', args => {login => 'test', password => 'private-secret'});
    is_deeply($captured->{args}, {login => 'test', password => '***'}, 'unrelated existing authentication log behavior is preserved');
}

subtest 'private response defaults cover early errors without leaking into another request' => sub {
    local $ENV{REQUEST_METHOD} = 'POST';
    my $private = '';
    {
        open my $output, '>', \$private or die $!;
        local *STDOUT = $output;
        local $Core::Utils::is_header = 0;
        local %Core::Utils::response_headers = ('Cache-Control' => 'private, no-store', 'Pragma' => 'no-cache');
        Core::Utils::print_json({status => 401, error => 'Unauthorized'});
    }
    like($private, qr/^Cache-control: private, no-store\r?$/mi, 'implicit authentication/error headers inherit no-store');
    like($private, qr/^Pragma: no-cache\r?$/mi, 'private responses also disable legacy caches');
    my $ordinary = '';
    {
        open my $output, '>', \$ordinary or die $!;
        local *STDOUT = $output;
        local $Core::Utils::is_header = 0;
        Core::Utils::print_header(status => 200);
    }
    unlike($ordinary, qr/^Cache-control:|^Pragma:/mi, 'a later ordinary request does not inherit private defaults');
};

done_testing();
