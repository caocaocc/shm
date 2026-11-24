package Core::Routing::Input;
use v5.14;
use strict;
use warnings;
use utf8;
use Encode qw(decode encode FB_CROAK);
use MIME::Base64 qw(decode_base64 encode_base64);
use Socket qw(AF_INET AF_INET6 SOCK_STREAM NI_NUMERICHOST inet_pton inet_ntop getaddrinfo getnameinfo);
use Storable qw(dclone);
use Text::ParseWords qw(shellwords);
use URI;
use URI::Escape qw(uri_unescape);

sub bad { die "INVALID_OUTBOUND\n" }
sub denied { die "ENDPOINT_DENIED\n" }
sub trim { my $value = $_[0] // ''; $value =~ s/\A\s+|\s+\z//g; return $value }

sub ip {
    my ($value) = @_;
    return unless defined($value) && $value =~ /\A[0-9a-f:.]+\z/i;
    my $family = index($value, ':') >= 0 ? AF_INET6 : AF_INET;
    my $bytes = inet_pton($family, $value);
    return defined($bytes) ? inet_ntop($family, $bytes) : undef;
}
sub domain {
    my ($name) = @_;
    return unless defined($name) && length($name) && $name !~ m{[\s\x00-\x1f\x7f/\\:%@?#\[\]]};
    $name =~ s/\.\z//;
    if ($name =~ /[^\x00-\x7f]/) {
        require Net::IDN::Encode;
        $name = eval { Net::IDN::Encode::domain_to_ascii($name) };
        return unless defined $name;
    }
    $name = lc $name;
    return if length($name) > 253 || $name =~ /\A[0-9.]+\z/;
    my @labels = split /\./, $name, -1;
    return unless @labels;
    for (@labels) { return unless /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/ }
    return $name;
}
sub cidr {
    my ($text, $preserve, $append) = @_;
    my ($address, $width) = $text =~ m{\A([^/]+)(?:/([0-9]{1,3}))?\z};
    $address = ip($address);
    return unless defined $address;
    my $family = $address =~ /:/ ? AF_INET6 : AF_INET;
    my $packed = inet_pton($family, $address);
    my $bits = length($packed) * 8;
    return $append ? "$address/$bits" : $address unless defined $width;
    return if $width > $bits;
    $width = int($width);
    unless ($preserve) {
        my $binary = unpack('B*', $packed);
        substr($binary, $width) = '0' x ($bits - $width);
        $address = inet_ntop($family, pack('B*', $binary));
    }
    return "$address/$width";
}
sub host_port {
    my ($value) = @_;
    my ($v6, $plain, $port) = ($value // '') =~ /\A(?:\[([a-fA-F0-9:.]+)\]|([^:\s]+)):([0-9]{1,5})\z/;
    return unless defined($port) && $port > 0 && $port <= 65535;
    my $host = defined($v6) ? ($v6 =~ /:/ ? ip($v6) : undef) : ip($plain) // domain($plain);
    return defined($host) ? ($host, 0+$port) : ();
}
sub with_port { return ($_[0] =~ /:/ ? "[$_[0]]" : $_[0]).':'.$_[1] }
sub b64 {
    my ($text) = @_;
    $text =~ tr{-_}{+/};
    bad() unless $text =~ m{\A[A-Za-z0-9+/]+={0,2}\z};
    my $bytes = decode_base64($text);
    my $full = encode_base64($bytes, '');
    (my $short = $full) =~ s/=+\z//;
    bad() unless $text eq $short || $text eq $full;
    return $bytes;
}
sub unescape {
    my ($value) = @_;
    bad() if $value =~ /%(?![a-f0-9]{2})/i;
    return decode('UTF-8', uri_unescape(encode('UTF-8', $value)), FB_CROAK);
}
sub socks_config {
    my ($remote, $user, $pass) = @_;
    my ($host, $port) = host_port($remote);
    bad() unless defined $host;
    my $server = {address => $host, port => $port};
    if (defined($user) || defined($pass)) {
        for ($user, $pass) { bad() unless defined && length && length(encode('UTF-8', $_)) <= 255 && !/[[:cntrl:]]/ }
        $server->{users} = [{user => $user, pass => $pass}];
    }
    return {protocol => 'socks', settings => {servers => [$server]}};
}
sub labelled_socks {
    my ($text) = @_;
    my %labels = (map({($_, 'host')} qw(ip host server address 地址 服务器)), map({($_, 'user')} qw(username user 用户名)),
        map({($_, 'pass')} qw(password pass 密码)), port => 'port', '端口' => 'port', protocol => 'protocol');
    my %item;
    for my $line (split /\r?\n/, $text) {
        next unless length(trim($line));
        my ($name, $value) = $line =~ /\A\s*([^:：=]+?)\s*[:：=]\s?(.*)\z/;
        my $field = $labels{lc($name // '')};
        bad() unless defined($field) && !exists $item{$field};
        $item{$field} = $value;
    }
    bad() if defined($item{protocol}) && trim($item{protocol}) !~ /\Asocks(?:5h?)?\z/i;
    my $remote = trim($item{host});
    $remote = with_port($remote, trim($item{port})) if defined $item{port} && $remote !~ /^\[/;
    $remote .= ':'.trim($item{port}) if defined($item{port}) && trim($item{host}) =~ /^\[/;
    return socks_config($remote, @item{qw(user pass)});
}
sub curl_arguments {
    my ($text) = @_;
    my (undef, @args) = shellwords($text);
    my ($proxy, $auth);
    while (@args) {
        my $arg = shift @args;
        last if !@args && $arg =~ m{\Ahttps?://\S+\z};
        my ($name, $joined) = $arg =~ /\A(--(?:proxy|proxy-user|socks5|socks5-hostname))(?:=(.*))?\z/;
        ($name, $joined) = $arg =~ /\A(-[xU])(.*)\z/ unless $name;
        bad() unless $name;
        my $val = length($joined // '') ? $joined : shift @args;
        bad() unless defined($val) && length($val);
        if ($name eq '-U' || $name eq '--proxy-user') { bad() if defined $auth; $auth = $val }
        else { bad() if defined $proxy; $proxy = $name =~ /^--socks/ ? 'socks5://'.$val : $val }
    }
    bad() unless ($proxy // '') =~ m{\Asocks(?:5h?)?://}i;
    return ($proxy, $auth);
}
sub socks {
    my ($text) = @_;
    my $credentials;
    ($text, $credentials) = curl_arguments($text) if $text =~ /\Acurl\s/;
    my $uri = $text =~ s{\Asocks(?:5h?)?://}{}i;
    if ($uri) {
        $text =~ s{/\z}{};
        bad() if $text =~ m{[\s/?#]};
    } elsif ($text =~ /\n/ && $text =~ /^\s*(?:host|server|ip|address|port|username|user|password|pass|protocol|服务器|地址|端口|用户名|密码)\s*[:：=]/im) {
        return labelled_socks($text);
    } elsif ($text =~ /\A(\[[^\]]+\]|[^\s:,|]+):(\d{1,5}):([^:\r\n]+):([^\r\n]+)\z/) {
        return socks_config("$1:$2", $3, $4);
    } elsif ($text =~ /[\s|,]/) {
        my @fields = index($text, '|') >= 0 ? split(/\|/, $text, -1) : index($text, ',') >= 0 ? split(/,/, $text, -1) : split(/\s+/, $text);
        bad() unless @fields == 4;
        my $host = trim($fields[0]);
        $host = "[$host]" if ip($host) && index($host, ':') >= 0;
        return socks_config($host.':'.trim($fields[1]), @fields[2,3]);
    }
    my ($left, $right, @extra) = split /\@/, $text, -1;
    bad() if @extra || !length($left // '');
    my $remote = $left;
    if (defined $right) {
        bad() if defined $credentials;
        my @reverse = host_port($left);
        if (@reverse && !$uri) {
            bad() if host_port($right);
            $credentials = $right;
        } else {
            $remote = $right;
            $credentials = $left;
            $uri = 1;
        }
    }
    my ($user, $pass);
    if (defined $credentials) {
        ($user, $pass) = split /:/, $credentials, 2;
        bad() unless defined $pass;
        if ($uri && defined($right)) { ($user, $pass) = map { unescape($_) } ($user, $pass) }
    }
    return socks_config($remote, $user, $pass);
}

sub shadowsocks {
    my ($share) = @_;
    $share =~ s/#.*\z//;
    bad() if $share =~ /\?/;
    my ($info, $remote);
    if ($share =~ /\@/) {
        ($info, $remote) = $share =~ m{\A([^@]+)@([^@/]+)/?\z} or bad();
        $info = $info =~ /:/ ? unescape($info) : decode('UTF-8', b64($info), FB_CROAK);
    } else {
        my $body = decode('UTF-8', b64($share), FB_CROAK);
        ($info, $remote) = $body =~ /\A(.+)\@([^@]+)\z/ or bad();
    }
    my ($host, $port) = host_port($remote);
    my ($cipher, $password) = split /:/, $info, 2;
    bad() unless $host && defined($password) && length($password) && $password !~ /[[:cntrl:]]/;
    if ($cipher =~ /\A2022-blake3-(aes-128-gcm|aes-256-gcm|chacha20-poly1305)\z/) {
        my $size = $1 eq 'aes-128-gcm' ? 16 : 32;
        my @keys = split /:/, $password, -1;
        bad() if $cipher =~ /chacha/ && @keys != 1;
        for (@keys) { bad() unless length(b64($_)) == $size }
    } elsif ($cipher !~ /\A(?:aes-(?:128|256)-gcm|x?chacha20-ietf-poly1305)\z/) { bad() }
    return {protocol => 'shadowsocks', settings => {servers => [{method => $cipher, password => $password, address => $host, port => $port}]}};
}

sub wireguard {
    my ($text) = @_;
    my %allowed = (
        interface => {map { $_ => 1 } qw(address dns privatekey mtu)},
        peer => {map { $_ => 1 } qw(endpoint publickey presharedkey allowedips persistentkeepalive)},
    );
    my (%value, %seen, $section);
    for my $line (split /\r?\n/, $text) {
        $line =~ s/#.*//;
        $line = trim($line);
        next if $line eq '';
        if ($line =~ /\A\[(interface|peer)\]\z/i) {
            $section = lc $1;
            bad() if $seen{$section}++;
        } else {
            my ($key, $data) = $line =~ /\A([a-z]+)\s*=\s*(.+)\z/i;
            bad() unless $section && $key && $allowed{$section}{lc $key} && !exists $value{lc $key};
            $value{lc $key} = trim($data);
        }
    }
    for my $field (qw(privatekey publickey address allowedips endpoint)) { bad() unless length($value{$field} // '') }
    for my $field (qw(privatekey publickey presharedkey)) {
        next unless defined $value{$field};
        bad() unless $value{$field} =~ m{\A[A-Za-z0-9+/]{43}=\z} && length(b64($value{$field})) == 32;
    }
    my ($host, $port) = host_port($value{endpoint});
    bad() unless $host;
    my $peer = {publicKey => $value{publickey}, endpoint => with_port($host, $port)};
    my $settings = {secretKey => $value{privatekey}, peers => [$peer]};
    for my $field (qw(address dns allowedips)) {
        next unless exists $value{$field};
        my @items = split /\s*,\s*/, $value{$field}, -1;
        bad() if @items > ($field eq 'allowedips' ? 64 : 8);
        for (@items) {
            $_ = $field eq 'dns' ? ip($_) : cidr($_, $field eq 'address', 1);
            bad() unless defined;
        }
        if ($field eq 'allowedips') { $peer->{allowedIPs} = \@items }
        else { $settings->{$field eq 'dns' ? 'remoteDNS' : 'address'} = \@items }
    }
    $peer->{preSharedKey} = $value{presharedkey} if defined $value{presharedkey};
    if (defined(my $keep = $value{persistentkeepalive})) {
        bad() unless $keep =~ /\A[0-9]{1,5}\z/ && $keep <= 65535;
        $peer->{keepAlive} = 0+$keep;
    }
    if (defined(my $mtu = $value{mtu})) {
        bad() unless $mtu =~ /\A[0-9]{1,5}\z/ && $mtu >= 576 && $mtu <= 65535;
        $settings->{mtu} = 0+$mtu;
    }
    return {protocol => 'wireguard', settings => $settings};
}

sub public_address {
    my ($address) = @_;
    require Data::Validate::IP;
    if ($address =~ /:/) {
        return 0 unless $address =~ /\A[23]/ && Data::Validate::IP::is_public_ipv6($address);
        # Exclude transition tunnels, benchmarking, documentation and ORCHID identifiers.
        return $address !~ /\A(?:2001:(?::|0:|2:|[12][a-f0-9]:|db8:)|2002:|3fff:)/;
    }
    my ($a, $b, $c) = split /\./, $address;
    return 0 if ($a == 100 && $b >= 64 && $b <= 127) || ($a == 198 && ($b == 18 || $b == 19))
        || ($a == 192 && (($b == 0 && $c == 0) || ($b == 88 && $c == 99)));
    return Data::Validate::IP::is_public_ipv4($address);
}
sub endpoints {
    my ($out, $url) = @_;
    my $panel_host = URI->new($url // '')->host;
    my $panel = ip($panel_host) // domain($panel_host);
    denied() unless $panel;
    my ($host, $port) = $out->{protocol} eq 'wireguard' ? host_port($out->{settings}{peers}[0]{endpoint})
        : @{$out->{settings}{servers}[0]}{qw(address port)};
    denied() unless defined($host) && defined($port) && $panel ne $host;
    denied() if ip($host) && !public_address($host);
    return ($host, $port, $panel);
}
sub compile {
    my ($source, $input, $url) = @_;
    bad() unless defined($source) && !ref($source) && length(encode('UTF-8', $source)) <= 16384;
    my $text = trim($source);
    my $out = eval {
        if ($text =~ /\A(?:#[^\n]*\n\s*)*\[Interface\]/i) { wireguard($text) }
        elsif ($text =~ m{\Ass://(.+)\z}i) { shadowsocks($1) }
        else { socks($text) }
    } or bad();
    eval { endpoints($out, $url); 1 } or denied();
    die "INVALID_RULES\n" unless ref($input) eq 'ARRAY';
    my ($bytes, @domains, @ips, @rules, %seen);
    for my $line (@$input) {
        die "INVALID_RULES\n" unless defined($line) && !ref($line) && $line !~ /[\r\n]/;
        $bytes += length(encode('UTF-8', $line))+1;
        die "INVALID_RULES\n" if $bytes > 65536;
        my $rule = lc trim($line);
        next unless length $rule;
        my ($list, $selector);
        if ($rule =~ /\A(geoip|geosite):[a-z0-9][a-z0-9_-]*(?:\@[a-z0-9_-]+)?\z/) {
            $list = $1 eq 'geoip' ? \@ips : \@domains;
            $selector = $rule;
        } elsif (defined(my $ip = cidr($rule, 0, 0))) {
            $rule = $selector = $ip;
            $list = \@ips;
        } else {
            $rule = domain($rule);
            die "INVALID_RULES\n" unless defined($rule) && index($rule, '.') >= 0;
            $selector = 'domain:'.$rule;
            $list = \@domains;
        }
        next if $seen{$rule}++;
        push @$list, $selector;
        push @rules, $rule;
        die "INVALID_RULES\n" if @rules > 200;
    }
    die "INVALID_RULES\n" unless @rules;
    return {outbound => $out, domains => \@domains, ips => \@ips, rules => \@rules};
}

sub resolve {
    my ($host) = @_;
    my $literal = ip($host);
    return ($literal) if defined $literal;
    my $dns = domain($host) or denied();
    my ($error, @addr) = getaddrinfo($dns, undef, {socktype => SOCK_STREAM});
    denied() if $error || !@addr;
    my %answers;
    for my $entry (@addr) {
        my ($failed, $name) = getnameinfo($entry->{addr}, NI_NUMERICHOST);
        my $canonical = ip($name);
        denied() if $failed || !defined $canonical;
        $answers{$canonical} = 1;
    }
    return sort keys %answers;
}
sub pin {
    my ($outbound, $panel_url) = @_;
    my $result = eval {
        my ($host, $port, $panel) = endpoints($outbound, $panel_url);
        my %blocked;
        for my $address (resolve($panel)) {
            $blocked{$address} = 1;
            $blocked{$1} = 1 if $address =~ /\A::ffff:([0-9.]+)\z/;
        }
        my @options = resolve($host);
        denied() unless @options;
        for (@options) { denied() unless public_address($_) && !$blocked{$_} }
        my $copy = dclone($outbound);
        if ($copy->{protocol} eq 'wireguard') { $copy->{settings}{peers}[0]{endpoint} = with_port($options[0], $port) }
        else { $copy->{settings}{servers}[0]{address} = $options[0] }
        $copy;
    };
    return $result || denied();
}
1;
