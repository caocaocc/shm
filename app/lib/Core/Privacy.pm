package Core::Privacy;

use v5.14;
use strict;
use warnings;
use URI::Escape qw(uri_unescape);

# Use the same canonical path when classifying a request and recording its URL.
sub request_path {
    my ($uri) = @_;
    my $path = $uri // '';
    $path =~ s{^[a-z][a-z0-9+.-]*://[^/]*}{}i;
    $path =~ s/[?#].*//s;
    my @parts;
    for (1 .. 6) {
        my $decoded = uri_unescape($path);
        last if $decoded eq $path;
        $path = $decoded;
    }
    return '/private' if $path =~ /%[a-f0-9]{2}|[\x00-\x1f\x7f]/i;
    for my $part (split m{/+}, $path) {
        next unless length($part) && $part ne '.';
        if ($part eq '..') { pop @parts; next; }
        push @parts, $part;
    }
    return '/' . join('/', @parts);
}

sub private_path {
    my ($path) = @_;
    return $path =~ m{(?:^/private$|/(?:admin/config|user/service/routing|pay_systems)(?:/|$))}i;
}

sub private_request_error {
    my ($env) = @_;
    my $site = $env->{HTTP_SEC_FETCH_SITE} // '';
    return 'ORIGIN_DENIED' if $site && $site ne 'same-origin' && $site ne 'none';
    my $origin = $env->{HTTP_ORIGIN} // '';
    if ($origin && $site ne 'same-origin') {
        my $host = $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST} || '';
        my $secure = ($env->{HTTP_X_FORWARDED_PROTO} // '') eq 'https' || ($env->{HTTPS} // '') =~ /^(on|1)$/i;
        my $expected = ($secure ? 'https://' : 'http://') . $host;
        return 'ORIGIN_DENIED' unless lc($origin) eq lc($expected);
    }
    if (($env->{REQUEST_METHOD} // '') eq 'POST') {
        return 'REQUEST_INVALID' if length($env->{QUERY_STRING} // '');
        return 'REQUEST_INVALID' unless ($env->{CONTENT_TYPE} // '') =~ m{\Aapplication/json(?:\s*;|\z)}i;
    }
    return;
}

1;
