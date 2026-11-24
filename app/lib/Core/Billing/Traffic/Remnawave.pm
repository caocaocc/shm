package Core::Billing::Traffic::Remnawave;

use v5.14;
use utf8;
use HTTP::Tiny;
use JSON::PP ();
use URI;

sub quota {
    my ($service) = @_;
    my $panel = $service->settings->{remnawave};
    return unless defined $panel;
    die "流量套餐设置无效\n" unless ref($panel) eq 'HASH';
    my $limit = $panel->{traffic_limit_bytes};
    return if !defined($limit) || (!ref($limit) && $limit =~ /\A0*\z/);
    die "流量额度须为正整数字节\n" unless !ref($limit) && $limit =~ /\A[0-9]+\z/ && $limit <= 9007199254740991;
    return 0+$limit;
}

sub reading {
    my ($us) = @_;
    my $server = $us->server or return;
    my $cfg = $server->get_settings->{remnawave};
    return unless ref $cfg eq 'HASH' && $cfg->{api} && $cfg->{token} && $cfg->{token} !~ /[\s\x00-\x1f\x7f]/;
    my $url = URI->new($cfg->{api});
    return unless ($url->scheme // '') =~ /\Ahttps?\z/ && $url->host && !$url->userinfo && !defined($url->query) && !defined($url->fragment);
    return if $url->scheme eq 'http' && $url->host !~ /\A(?:localhost|127\.0\.0\.1|::1)\z/i && ($cfg->{allow_http} // '') !~ /\A(?:1|true)\z/;
    my $binding = $us->settings->{data} // {};
    return unless ref($binding) eq 'HASH';
    my $user = $binding->{username} || 'us_'.$us->id;
    return unless $user =~ /\A[a-zA-Z0-9_-]{3,36}\z/;
    my $path = $url->path;
    $path =~ s{/+\z}{};
    $path .= '/api' unless $path =~ m{/api\z};
    $url->path("$path/users/by-username/$user");
    my $timeout = $cfg->{http_timeout} // 30;
    return unless $timeout =~ /\A[1-9][0-9]{0,2}\z/ && $timeout <= 600;
    my $ca = $cfg->{ca_cert_path} || $cfg->{ca_file};
    my $client = HTTP::Tiny->new(timeout => $timeout, verify_SSL => 1, max_redirect => 0, max_size => 1048576,
        proxy => undef, http_proxy => undef, https_proxy => undef,
        ($ca ? (SSL_options => {SSL_ca_file => $ca}) : ()));
    my $reply = $client->get($url->as_string, {headers => {Authorization => "Bearer $cfg->{token}"}});
    return unless $reply->{success};
    my $json = eval {JSON::PP::decode_json($reply->{content})};
    return unless ref $json eq 'HASH' && ref $json->{response} eq 'HASH';
    my $row = $json->{response};
    return unless ($row->{username} // '') eq $user && ref($row->{userTraffic}) eq 'HASH' && exists $row->{lastTrafficResetAt};
    my $count = $row->{userTraffic}{usedTrafficBytes};
    return unless defined $count && $count =~ /\A[0-9]+\z/ && $count <= 9007199254740991;
    my $reset = $row->{lastTrafficResetAt};
    if (defined $reset) {
        return unless $reset =~ /\A(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,3}))?Z\z/;
        $reset = $1 . '.' . substr(($2 // '') . '000', 0, 3) . 'Z';
    }
    return {bytes => 0+$count, reset_at => $reset};
}

1;
