use v5.14;
use strict;
use warnings;
use Test::More;
use JSON ();
use Core::Config ();
use Core::Cloud::Currency ();

# Exercise the real public response and currency helper. Only configuration
# storage is replaced; a public currency lookup must never need Cloud/FX I/O.
{
    package AuthCurrencyConfig;
    our @ISA = ('Core::Config');
    sub new { bless { values => $_[1] }, $_[0] }
    sub data_by_name { $_[0]{values}{$_[1]} || {} }

    package AuthCurrencyBilling;
    sub new { bless { config => $_[1] }, $_[0] }
    sub get_data { $_[0]{config}->data_by_name('billing') }
}

my $values = {
    billing => { currency => 'RUB', type => 'Honest', private_marker => 'billing-private',
        allow_user_auth_api => 0, allow_user_register_api => 1, allow_user_register_captcha => 1 },
    oauth2 => { google => { enabled => JSON::true, client_id => 'oauth-id', client_secret => 'oauth-private' } },
    telegram => { bot => { client_id => 'bot-id', client_secret => 'telegram-private', oidc_enabled => 1 } },
    passkey => { enabled => 1 },
};
my $config = AuthCurrencyConfig->new($values);
my $billing = AuthCurrencyBilling->new($config);
my $currency = bless {}, 'Core::Cloud::Currency';
my $helper_calls = 0;
my $response;
{
    no warnings 'redefine';
    local *Core::Config::get_service = sub {
        die "Unexpected public auth service $_[0]" unless $_[0] eq 'Cloud::Currency';
        $helper_calls++;
        return $currency;
    };
    local *Core::Cloud::Currency::get_service = sub {
        my ($service, %args) = @_;
        die 'Unexpected currency storage lookup' unless $service eq 'config' && $args{_id} eq 'billing';
        return $billing;
    };
    local *Core::Cloud::cloud_request = sub { die 'Public auth must not request Cloud exchange rates' };

    for my $case (['RUB', 'RUB'], ['CNY', 'CNY'], ['USD', 'USD'], [undef, 'CNY']) {
        $values->{billing}{currency} = $case->[0];
        $response = $config->api_data_by_auth;
        is_deeply($response->{billing}, {currency => $case->[1]},
            'public billing metadata exposes only the actual currency: ' . ($case->[0] // 'default'));
    }
}

is($helper_calls, 4, 'every response uses the shared system currency helper');
is_deeply([sort keys %$response], [qw(auth billing captcha oauth2 passkey register telegram)],
    'existing public auth fields are preserved without exposing other configuration');
ok(!$response->{auth}{enabled}, 'existing disabled password authentication flag is preserved');
ok($response->{register}{enabled}, 'existing registration flag is preserved');
ok($response->{captcha}{enabled}, 'existing CAPTCHA flag is preserved');
ok($response->{passkey}{enabled}, 'existing passkey flag is preserved');
ok($response->{telegram}{enabled}, 'existing Telegram OIDC flag is preserved');
is_deeply($response->{oauth2}{providers}, {google => {enabled => JSON::true}},
    'OAuth response retains its existing safe enabled-only projection');
unlike(JSON::encode_json($response), qr/billing-private|oauth-private|telegram-private|Honest/,
    'billing settings and authentication secrets are absent from the public response');
is($values->{billing}{private_marker}, 'billing-private', 'public projection does not change stored billing settings');

done_testing();
