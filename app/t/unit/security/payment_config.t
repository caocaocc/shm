use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use File::Temp qw(tempdir);
use File::Spec;
use FindBin;
use Cwd qw(abs_path);
use IPC::Open3;
use Symbol qw(gensym);

# Exercise the real log policy without requiring a database or retaining an
# instance of the framework's global service registry.
BEGIN {
    package Core::Base;
    sub import {}
    sub user_id { $_[0]{user_id} }
    sub add { my ($self, %args) = @_; $self->{captured} = \%args; return 1 }
    $INC{'Core/Base.pm'} = __FILE__;
}
use Core::Logs::Api;

my $private = 'synthetic-private-config-marker';
my $log = bless {user_id => 42}, 'Core::Logs::Api';
my $body = {POSTDATA => qq({"merchant_private_key":"$private"), any_secret_object => {unknown => $private}};
for my $path (
    '/admin/config', '/admin/config/pay_systems', '/admin/config/pay_systems/',
    '/shm/v1/admin/config/pay_systems?private=' . $private,
    'https://bill.example.test/shm/v1/admin/config/pay_systems?private=' . $private,
    '//admin///config/./pay_systems', '/admin/other/../config/pay_systems',
    '/shm/v1/%61dmin/config%2Fpay_systems', '/admin/config%252Fpay_systems',
) {
    for my $method (qw(POST PUT PATCH DELETE)) {
        $log->add(url => $path, method => $method, args => $body, response_error => "Invalid JSON $private");
        is_deeply($log->{captured}{args}, {redacted => 1}, "$method config request is redacted after path normalization");
        unlike(JSON::PP->new->encode($log->{captured}), qr/\Q$private\E/, 'neither raw body, URL query nor parser error reaches logs');
    }
}
for my $path ('/user/service/options', '/admin/user/service/options/secret', '/shm/v1/admin/user/service/options/retry?x=' . $private) {
    $log->add(url => $path, method => 'POST', args => $body);
    is_deeply($log->{captured}{args}, {redacted => 1}, 'existing service-options protection is preserved');
}
$log->add(url => '/user/auth?password=' . $private, method => 'POST', args => {
    login => 'customer', password => $private, POSTDATA => $private,
    nested => [{key => $private, md5_key => $private, merchant_private_key => $private,
        platform_public_key => $private, merchantPrivateKey => $private,
        client_secret => $private, Authorization => $private, sign => $private,
        merchant_private_key_file => $private, public => 'retained'}],
});
unlike(JSON::PP->new->encode($log->{captured}), qr/\Q$private\E/, 'credential variants, signatures and raw body copies are masked recursively');
is($log->{captured}{args}{login}, 'customer', 'ordinary public diagnostics are retained');
is($log->{captured}{args}{nested}[0]{public}, 'retained', 'public nested values remain available');
is($log->{captured}{url}, '/user/auth', 'request query does not duplicate unmasked arguments');

subtest 'legacy customer payment list exposes checkout data, never the complete merchant configuration' => sub {
    my $directory = tempdir(CLEANUP => 1);
    my $fixture = {
        epay => {paysystem => 'epay', weight => 3,
            payment_url => '/shm/pay_systems/epay.cgi', template_id => 'legacy-payment-template',
            key => $private, md5_key => $private, merchant_private_key => $private,
            platform_public_key => $private, credential_versions => {old => {anything => $private}},
            unknown => $private, nested => {private => $private}},
        static => {name => 'Static checkout', show_for_client => 1, template => '<form>Public checkout</form>'},
        hidden => {show_for_client => JSON::PP::false, name => $private, secret => $private},
        invalid => 'not-a-profile',
    };
    my $json = JSON::PP->new->canonical->utf8->encode($fixture);
    open my $stub, '>', File::Spec->catfile($directory, 'SHM.pm') or die $!;
    print {$stub} <<'STUB';
package SHM;
use strict;
use warnings;
use JSON::PP ();
our $FIXTURE = <<'PUBLIC_PAYMENT_TEST_JSON';
STUB
    print {$stub} $json, "\nPUBLIC_PAYMENT_TEST_JSON\n";
    print {$stub} <<'STUB';
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::get_service"} = \&get_service;
    *{"${caller}::print_json"} = \&print_json;
}
sub new {bless {}, shift}
sub get_service {
    my ($name, %args) = @_;
    return bless {}, 'PublicPaymentConfig' if $name eq 'config';
    return bless {}, 'PublicPaymentLocal' if $name eq 'Pay::Local';
    die 'Unexpected template' unless $name eq 'template' && $args{_id} eq 'legacy-payment-template';
    return bless {}, 'PublicPaymentTemplate';
}
sub print_json {print JSON::PP->new->canonical->utf8->encode($_[0])}
package PublicPaymentConfig;
sub get_data {JSON::PP->new->utf8->decode($SHM::FIXTURE)}
package PublicPaymentLocal;
sub profile {
    my ($self, $name, $profile) = @_;
    return {%$profile} unless $name eq 'epay';
    return {name => "\x{6613}\x{652f}\x{4ed8}", show_for_client => 1, %$profile};
}
package PublicPaymentTemplate;
sub parse {'<form>Rendered legacy checkout</form>'}
1;
STUB
    close $stub or die $!;
    my $app = abs_path(File::Spec->catdir($FindBin::Bin, '..', '..', '..'));
    my $cgi = File::Spec->catfile($app, 'public_html', 'shm', 'user', 'pay_systems.cgi');
    my $error = gensym;
    my $pid = open3(my $input, my $output, $error, $^X, '-I', $directory, $cgi);
    close $input;
    my $result = do {local $/; <$output>};
    my $diagnostics = do {local $/; <$error>};
    waitpid($pid, 0);
    is($?, 0, 'real legacy CGI runs successfully with isolated services');
    is($diagnostics, '', 'legacy CGI emits no credential-bearing diagnostics');
    unlike($result, qr/\Q$private\E/, 'merchant keys, private objects and hidden profiles are absent from the HTTP result');
    my $profiles = JSON::PP->new->utf8->decode($result);
    is(scalar @$profiles, 2, 'only valid customer-visible profiles are returned');
    my ($epay) = grep {($_->{paysystem} // '') eq 'epay'} @$profiles;
    is($epay->{name}, '易支付', 'public display name is preserved');
    is($epay->{payment_url}, '/shm/pay_systems/epay.cgi', 'public checkout location is preserved');
    is($epay->{template_id}, 'legacy-payment-template', 'template selection remains compatible');
    is($epay->{template}, '<form>Rendered legacy checkout</form>', 'legacy template still renders');
    my ($static) = grep {($_->{name} // '') eq 'Static checkout'} @$profiles;
    is($static->{template}, '<form>Public checkout</form>', 'existing public HTML templates remain available');
};

done_testing();
