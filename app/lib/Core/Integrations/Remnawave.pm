package Core::Integrations::Remnawave;

use v5.14;
use strict;
use warnings;
use utf8;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Scalar::Util qw(blessed);
use B ();
use Socket qw(AF_INET AF_INET6 SOCK_STREAM getaddrinfo getnameinfo NI_NUMERICHOST inet_pton inet_ntop);
use Time::Local qw(timegm timelocal);
use POSIX qw(tzset);
use URI;

# ServiceOptions selects this adapter from administrator-owned Remnawave server
# settings. Geo labels are syntax-checked; the operator supplies node resources.
# The panel administrator owns Profile binding, order and default outbounds.
# This publisher only merges the two fixed Snippets; it never reads Profiles.
# Generic task ownership, encrypted storage and HTTP redaction remain in Core.
my $JSON = JSON::PP->new->canonical->utf8->allow_nonref;
my %SS = map {$_ => 1} qw(aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305);
my $MAX_RESPONSE = 16 * 1024 * 1024;
my $MAX_SNIPPETS = 10_000;

sub new { my ($class, %args) = @_; return bless {%args}, $class }
sub metadata { return {feature=>'routing',requires_secret=>1} }
sub _error { die bless {code => $_[0] || 'INVALID_CONFIG', retry => $_[1] ? 1 : 0}, 'Core::Integrations::Remnawave::Error' }
sub _retry { _error($_[0], 1) }
sub _timeout { !ref($_[0]) && defined($_[0]) && $_[0] =~ /\ASERVICE_OPTIONS_TIMEOUT\s*\z/ }
sub _code {
    my ($error,$fallback)=@_;
    return $error->{code} if blessed($error) && $error->isa('Core::Integrations::Remnawave::Error');
    return $1 if !ref($error) && defined($error) && $error =~ /\A(SERVICE_OPTIONS_BUSY|SERVICE_OPTIONS_KEY_MISSING)\s*\z/;
    return $fallback || 'INTERNAL_ERROR';
}
# Nested validation/HTTP catches must never consume the controller's one-shot
# total alarm and proceed with another request after the deadline.
sub _eval (&) {
    my ($code)=@_;my $want=wantarray;my (@values,$value);
    my $ok=eval {$want?(@values=$code->()):($value=$code->());1};my $error=$@;
    die $error if _timeout($error);
    $@=$error;
    return $want?@values:$value;
}
sub _json { $JSON->encode($_[0]) }
sub _copy { $JSON->decode(_json($_[0])) }
sub _hash { ref($_[0]) eq 'HASH' }
sub _array { ref($_[0]) eq 'ARRAY' }
sub _bool { JSON::PP::is_bool($_[0]) || (blessed($_[0]) && blessed($_[0]) =~ /\A(?:JSON::XS::Boolean|Types::Serialiser::Boolean)\z/) }
sub _truth { _bool($_[0]) && $_[0] ? 1 : 0 }
sub _int {
    my ($value, $low, $high) = @_; $low //= 1; $high //= '9223372036854775807';
    _error('INVALID_CONFIG') if !defined($value) || ref($value);
    my $flags = B::svref_2object(\$value)->FLAGS;
    _error('INVALID_CONFIG') unless $flags & B::SVp_IOK();
    _error('INVALID_CONFIG') unless "$value" =~ /\A(?:0|[1-9][0-9]*)\z/ && $value >= $low
        && (length("$value") < length("$high") || length("$value") == length("$high") && "$value" le "$high");
    return $value;
}
sub _text {
    my ($value, $limit, $empty) = @_; $limit //= 1024;
    _error('INVALID_CONFIG') if defined($value) && !ref($value) && !(B::svref_2object(\$value)->FLAGS & B::SVp_POK());
    _error('INVALID_CONFIG') if !defined($value) || ref($value) || (!$empty && !length($value)) || $value =~ /[\x00-\x1f\x7f\x{d800}-\x{dfff}]/;
    my $bytes = _eval { encode('UTF-8', "$value", FB_CROAK) };
    _error('INVALID_CONFIG') if $@ || length($bytes) > $limit;
    return "$value";
}
sub _keys {
    my ($value, $allowed, $required) = @_;
    _error('INVALID_OUTBOUND') unless _hash($value);
    my %allowed = map {$_ => 1} @$allowed;
    _error('INVALID_OUTBOUND') if grep {!$allowed{$_}} keys %$value;
    _error('INVALID_OUTBOUND') if grep {!exists $value->{$_}} @{ $required || [] };
    return $value;
}

# JSON::PP otherwise silently accepts duplicate members. Scan recursively before
# decoding, including escaped equivalent keys, without logging the raw input.
sub _strict_json {
    my ($raw) = @_;
    _retry('REMOTE_RESPONSE') if !defined($raw) || ref($raw) || length($raw) > $MAX_RESPONSE;
    # JSON::PP::decode_prefix reports consumed UTF-8 bytes, even when its input
    # is a Unicode scalar. Keep every offset in a byte buffer and use the UTF-8
    # codec for both prefix scanning and the final decoded result. Validate
    # without consuming either the caller's body or the buffer being scanned.
    my $bytes = _eval {
        my $buffer = utf8::is_utf8($raw) ? encode('UTF-8', $raw, FB_CROAK | LEAVE_SRC) : $raw;
        decode('UTF-8', $buffer, FB_CROAK | LEAVE_SRC);
        $buffer;
    };
    _retry('REMOTE_RESPONSE') if $@ || !defined($bytes) || length($bytes) > $MAX_RESPONSE;
    my $position = 0; my $length = length($bytes); my $walk;
    my $white = sub {$position++ while $position < $length && substr($bytes,$position,1) =~ /[ \t\r\n]/};
    my $string = sub {
        _retry('REMOTE_RESPONSE') unless substr($bytes,$position,1) eq '"';
        my ($value,$used) = _eval {$JSON->decode_prefix(substr($bytes,$position))};
        _retry('REMOTE_RESPONSE') if $@ || !defined($used) || ref($value);
        $position += $used; return $value;
    };
    $walk = sub {
        my ($depth) = @_; _retry('REMOTE_RESPONSE') if $depth > 128;
        $white->(); my $char = substr($bytes,$position,1);
        if ($char eq '{') {
            $position++; $white->(); my %seen;
            if (substr($bytes,$position,1) eq '}') {$position++; return}
            while (1) {
                $white->(); my $key = $string->(); _retry('REMOTE_RESPONSE') if $seen{$key}++;
                $white->(); _retry('REMOTE_RESPONSE') unless substr($bytes,$position++,1) eq ':';
                $walk->($depth+1); $white->(); my $end = substr($bytes,$position++,1);
                last if $end eq '}'; _retry('REMOTE_RESPONSE') unless $end eq ',';
            }
        } elsif ($char eq '[') {
            $position++; $white->(); if (substr($bytes,$position,1) eq ']') {$position++; return}
            while (1) {$walk->($depth+1); $white->(); my $end=substr($bytes,$position++,1); last if $end eq ']'; _retry('REMOTE_RESPONSE') unless $end eq ','}
        } elsif ($char eq '"') {$string->()}
        else {
            my ($token) = substr($bytes,$position) =~ /\A(true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/;
            _retry('REMOTE_RESPONSE') unless defined $token; $position += length($token);
        }
    };
    $walk->(0); $white->(); _retry('REMOTE_RESPONSE') unless $position == $length;
    my $value = _eval {$JSON->decode($bytes)};
    _retry('REMOTE_RESPONSE') if $@; return $value;
}

sub _ip {
    my ($value, $mapped) = @_;
    return undef if !defined($value) || ref($value) || $value =~ /[%\s]/;
    if ($value !~ /:/) {
        return undef unless $value =~ /\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/;
        return undef if grep {$_ > 255} split /\./, $value;
        my $packed=inet_pton(AF_INET,$value); return {family=>4,packed=>$packed,text=>inet_ntop(AF_INET,$packed)} if defined $packed;
        return undef;
    }
    my $packed = _eval {inet_pton(AF_INET6,$value)}; return undef unless defined $packed;
    if ($mapped && substr($packed,0,12) eq ("\0" x 10)."\xff\xff") {
        return {family=>4,packed=>substr($packed,12),text=>inet_ntop(AF_INET,substr($packed,12))};
    }
    return {family=>6,packed=>$packed,text=>_v6_text($packed)};
}
sub _v6_text {
    return '::ffff:'.inet_ntop(AF_INET,substr($_[0],12)) if substr($_[0],0,12) eq ("\0" x 10)."\xff\xff";
    my @words=unpack('n8',$_[0]);my ($best,$best_length)=(-1,1);
    for (my $i=0;$i<8;$i++) {next if $words[$i];my $start=$i;$i++ while $i<8 && !$words[$i];my $length=$i-$start;if ($length>$best_length) {($best,$best_length)=($start,$length)}}
    my @text=map {sprintf '%x',$_} @words;
    return join(':',@text) if $best<0;
    return join(':',@text[0..$best-1]).'::'.join(':',@text[$best+$best_length..7]);
}
sub _network {
    my ($value, $interface) = @_;
    _error('INVALID_OUTBOUND') if !defined($value) || ref($value);
    my ($host,$prefix) = split m{/}, $value, -1;
    _error('INVALID_OUTBOUND') if $value =~ m{/.*/};
    my $ip = _ip($host,0) or _error('INVALID_OUTBOUND');
    my $bits = $ip->{family} == 4 ? 32 : 128;
    $prefix = $bits unless defined $prefix;
    _error('INVALID_OUTBOUND') unless "$prefix" =~ /\A(?:0|[1-9][0-9]*)\z/ && $prefix <= $bits;
    my $mask = pack('B*', ('1' x $prefix).('0' x ($bits-$prefix)));
    my $network = $ip->{packed} & $mask;
    my $text = $interface ? $ip->{text} : $ip->{family}==4?inet_ntop(AF_INET,$network):_v6_text($network);
    return {family=>$ip->{family},packed=>$network,prefix=>0+$prefix,text=>"$text/$prefix"};
}
sub _within {
    my ($ip,$network)=@_; return 0 unless $ip->{family}==$network->{family};
    my $bits=$ip->{family}==4?32:128;
    my $mask=pack('B*',('1' x $network->{prefix}).('0' x ($bits-$network->{prefix})));
    return ($ip->{packed}&$mask) eq $network->{packed};
}
my @NONPUBLIC4 = qw(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4);
my @NONPUBLIC6 = qw(::1/128 ::/128 64:ff9b:1::/48 100::/64 2001::/23 2001:db8::/32 2002::/16 3fff::/20 fc00::/7 fe80::/10 ff00::/8);
my @PUBLIC_EXCEPTIONS = qw(192.0.0.9/32 192.0.0.10/32 2001:1::1/128 2001:1::2/128 2001:3::/32 2001:4:112::/48 2001:20::/28 2001:30::/28);
sub _public_ip {
    my ($ip)=@_;
    return 1 if grep {_within($ip,_network($_,0))} @PUBLIC_EXCEPTIONS;
    return !grep {_within($ip,_network($_,0))} ($ip->{family}==4 ? @NONPUBLIC4:@NONPUBLIC6);
}
sub _hostname {
    my $value=_text($_[0],253); my $ip=_ip($value,0); return $ip->{text} if $ip;
    $value =~ s/\.+\z//;
    if ($value =~ /[^\x00-\x7f]/) {
        my $converted=_eval {require Net::IDN::Encode; Net::IDN::Encode::domain_to_ascii($value)};
        _error('INVALID_OUTBOUND') if $@ || !defined($converted); $value=$converted;
    }
    $value=lc $value;
    _error('INVALID_OUTBOUND') if !length($value) || length($value)>253 || $value =~ /\A[0-9.]+\z/ || $value =~ /\A(?:0x|0[0-9])/;
    _error('INVALID_OUTBOUND') if grep {!/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/} split /\./,$value,-1;
    return $value;
}
sub _endpoint {
    my $value=_text($_[0],300); my ($host,$port)=$value =~ /\A\[([^]]+)\]:([0-9]+)\z/;
    ($host,$port)=$value =~ /\A([^:]+):([0-9]+)\z/ unless defined $host;
    _error('INVALID_OUTBOUND') unless defined $host;
    _error('INVALID_OUTBOUND') if length($port)>5;
    return (_hostname($host),_int(0+$port,1,65535));
}
sub _key {
    my ($value,$size)=@_; _text($value,128);
    _error('INVALID_OUTBOUND') unless $value =~ /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/;
    my $raw=decode_base64($value); _error('INVALID_OUTBOUND') unless length($raw)==$size;
    return encode_base64($raw,'');
}

sub normalize_outbound {
    my ($self,$input)=@_;
    my $value=_copy(_keys($input,[qw(protocol settings)],[qw(protocol settings)]));
    my $protocol=_text($value->{protocol},32);
    if ($protocol eq 'shadowsocks' || $protocol eq 'socks') {
        my $settings=_keys($value->{settings},['servers'],['servers']);
        _error('INVALID_OUTBOUND') unless _array($settings->{servers}) && @{$settings->{servers}}==1;
        my $server=_keys($settings->{servers}[0],$protocol eq 'shadowsocks'?[qw(address port method password)]:[qw(address port users)],$protocol eq 'shadowsocks'?[qw(address port method password)]:[qw(address port)]);
        $server->{address}=_hostname($server->{address}); _int($server->{port},1,65535);
        if ($protocol eq 'shadowsocks') {
            my $method=_text($server->{method},64); _error('INVALID_OUTBOUND') unless $SS{$method};
            _text($server->{password},2048);
            if ($method =~ /\A2022-/) {
                my @keys=split /:/,$server->{password},-1;
                _error('INVALID_OUTBOUND') if $method eq '2022-blake3-chacha20-poly1305' && @keys!=1;
                _key($_,$method =~ /aes-128/?16:32) for @keys;
            }
        } elsif (exists $server->{users}) {
            _error('INVALID_OUTBOUND') unless _array($server->{users}) && @{$server->{users}}==1;
            my $credentials=_keys($server->{users}[0],[qw(user pass)],[qw(user pass)]);
            _text($credentials->{user},255); _text($credentials->{pass},255);
        }
        return $value;
    }
    _error('INVALID_OUTBOUND') unless $protocol eq 'wireguard';
    my $settings=_keys($value->{settings},[qw(secretKey address peers mtu remoteDNS)],[qw(secretKey address peers)]);
    $settings->{secretKey}=_key($settings->{secretKey},32);
    _error('INVALID_OUTBOUND') unless _array($settings->{address}) && @{$settings->{address}}>=1 && @{$settings->{address}}<=8;
    $settings->{address}=[map {_network(_text($_,100),1)->{text}} @{$settings->{address}}];
    if (exists $settings->{remoteDNS}) {
        _error('INVALID_OUTBOUND') unless _array($settings->{remoteDNS}) && @{$settings->{remoteDNS}}>=1 && @{$settings->{remoteDNS}}<=8;
        # These DNS servers are reached inside this userspace tunnel. Provider
        # private addresses are valid; only the outer peer uses _safe_ip.
        $settings->{remoteDNS}=[map {my $ip=_eval {_ip(_text($_,64),0)} or _error('INVALID_OUTBOUND'); $ip->{text}} @{$settings->{remoteDNS}}];
    }
    _int($settings->{mtu},576,9000) if exists $settings->{mtu};
    _error('INVALID_OUTBOUND') unless _array($settings->{peers}) && @{$settings->{peers}}==1;
    my $peer=_keys($settings->{peers}[0],[qw(publicKey preSharedKey endpoint allowedIPs keepAlive)],[qw(publicKey endpoint allowedIPs)]);
    $peer->{publicKey}=_key($peer->{publicKey},32); $peer->{preSharedKey}=_key($peer->{preSharedKey},32) if exists $peer->{preSharedKey};
    my ($host,$port)=_endpoint($peer->{endpoint}); $peer->{endpoint}=$host =~ /:/ ? "[$host]:$port":"$host:$port";
    _int($peer->{keepAlive},0,65535) if exists $peer->{keepAlive};
    _error('INVALID_OUTBOUND') unless _array($peer->{allowedIPs}) && @{$peer->{allowedIPs}}>=1 && @{$peer->{allowedIPs}}<=64;
    $peer->{allowedIPs}=[map {_network(_text($_,100),0)->{text}} @{$peer->{allowedIPs}}];
    return $value;
}
sub normalize_rules {
    my ($self,$values)=@_; _error('INVALID_RULES') unless _array($values) && @$values<=200;
    my (@domains,@ips,%seen);
    for my $raw (@$values) {
        my $value=_text($raw,253); $value =~ s/\A\s+|\s+\z//g;
        my ($normal,$target); my $ip=_ip($value,0);
        if ($ip) {$normal=$ip->{text};$target=\@ips}
        elsif ($value =~ m{/} && _eval {$normal=_network($value,0)->{text};1}) {$target=\@ips}
        elsif ($value =~ /\A(geosite|geoip):([a-z0-9_!.-]+(?:\@[a-z0-9_!-]+)?)\z/iaa) {$normal=lc($value);$target=lc($1) eq 'geosite'?\@domains:\@ips}
        else {
            _error('INVALID_RULES') if $value =~ m{[:/*\@]};
            my $domain=_hostname($value); _error('INVALID_RULES') unless $domain =~ /\./;
            $normal='domain:'.$domain;$target=\@domains;
        }
        push @$target,$normal unless $seen{$normal}++;
    }
    return (\@domains,\@ips);
}

sub _request {
    my ($self,$method,$path,$body,$missing)=@_; my $response;
    my $ok=_eval {
        my %args=(url=>$self->{api}.$path,method=>$method,headers=>{Authorization=>'Bearer '.$self->{config}{token}},
            content_type=>'application/json',content=>defined($body)?_json($body):'',timeout=>$self->{request_timeout},
            sensitive=>1,verify_hostname=>1,no_redirect=>1,no_proxy=>1,
            ($self->{config}{ca_bundle}?(ca_bundle=>$self->{config}{ca_bundle}):()));
        if ($self->{http}) {$response=$self->{http}->(%args)}
        else {require Core::System::ServiceManager; $response=Core::System::ServiceManager::get_service('Transport::Http')->http(%args)}
        1;
    };
    _retry('REMOTE_IO') unless $ok && blessed($response) && $response->can('code') && $response->can('content');
    return undef if $missing && $response->code==404;
    _retry('REMOTE_HTTP') unless $response->code>=200 && $response->code<300;
    my $raw=$response->content; _retry('REMOTE_RESPONSE') if length($raw)>$MAX_RESPONSE;
    return length($raw)?_strict_json($raw):undef;
}
sub _unwrap { my $value=$_[0]; _retry('REMOTE_RESPONSE') unless _hash($value) && _hash($value->{response}); return $value->{response} }
sub _resolve {
    my ($self,$host,$port)=@_; my $literal=_ip($host,1); return [$literal] if $literal;
    my @values; my $ok=_eval {
        if ($self->{resolver}) {my $result=$self->{resolver}->($host,$port); _retry('ENDPOINT_DNS') unless _array($result); @values=@$result}
        else {
            my ($error,@results)=getaddrinfo($host,$port,{socktype=>SOCK_STREAM}); _retry('ENDPOINT_DNS') if $error;
            for my $result (@results) {my ($err,$address)=getnameinfo($result->{addr},NI_NUMERICHOST); _retry('ENDPOINT_DNS') if $err; push @values,$address}
        }
        1;
    };
    _retry('ENDPOINT_DNS') unless $ok;
    my (%seen,@ips);
    for my $value (@values) {my $ip=_ip($value,1) or _retry('ENDPOINT_DNS'); push @ips,$ip unless $seen{$ip->{text}}++}
    _retry('ENDPOINT_DNS') unless @ips; return \@ips;
}
sub _safe_ip {
    my ($self,$host,$port)=@_; my $ips=$self->_resolve($host,$port);
    unless ($self->{management_ips}) {
        my %management;
        $management{$_->{text}}=1 for @{$self->_resolve($self->{panel_host},443)};
        $self->{management_ips}=\%management;
    }
    for my $ip (@$ips) {
        _error('ENDPOINT_DENIED') if $self->{management_ips}{$ip->{text}} || !_public_ip($ip);
    }
    my @sorted=sort {$a->{family}<=>$b->{family} || $a->{packed} cmp $b->{packed}} @$ips;
    return $sorted[0]{text};
}
sub _compile {
    my ($self,$value,$usi)=@_; $value=$self->normalize_outbound($value); $value->{tag}=$self->{prefix}."us_${usi}_out";
    if ($value->{protocol} eq 'wireguard') {
        my $peer=$value->{settings}{peers}[0]; my ($host,$port)=_endpoint($peer->{endpoint}); $host=$self->_safe_ip($host,$port);
        $peer->{endpoint}=$host =~ /:/?"[$host]:$port":"$host:$port"; $value->{settings}{noKernelTun}=JSON::PP::true;
    } else {my $server=$value->{settings}{servers}[0];$server->{address}=$self->_safe_ip($server->{address},$server->{port})}
    return $value;
}
sub _snippets {
    my $self=shift; my $rows=_unwrap($self->_request('GET','/api/snippets'))->{snippets}; _retry('REMOTE_RESPONSE') unless _array($rows);
    _retry('REMOTE_RESPONSE') if @$rows>$MAX_SNIPPETS;
    my %found;
    for my $row (@$rows) {
        # The endpoint returns every administrator-owned fragment. Only the
        # two fixed targets belong to this publisher; other names and values
        # are neither interpreted nor rewritten.
        next unless _hash($row) && defined($row->{name}) && !ref($row->{name})
            && ($row->{name} eq $self->{out_name} || $row->{name} eq $self->{rule_name});
        _retry('REMOTE_RESPONSE') if exists($found{$row->{name}}) || !_array($row->{snippet});
        $found{$row->{name}}=$row->{snippet};
    }
    _retry('SNIPPETS_NOT_READY') unless keys(%found)==2;
    return \%found;
}
sub _owned {my ($self,$entry,$usi,$route)=@_;return _hash($entry) && defined($entry->{$route?'ruleTag':'tag'}) && !ref($entry->{$route?'ruleTag':'tag'}) && index($entry->{$route?'ruleTag':'tag'},$self->{prefix}."us_${usi}_")==0}
sub _merge {
    my ($self,$current,$operations,$route)=@_; my @result=@{_copy($current)};
    for my $op (@$operations) {
        my $replace=$op->{restore} ? $op->{before}{$route?'rules':'outbounds'} : $route ? $op->{rules} : $op->{outbound}?[$op->{outbound}]:[];
        my ($position)=grep {$self->_owned($result[$_],$op->{usi},$route)} 0..$#result; $position=@result unless defined $position;
        @result=grep {!$self->_owned($_,$op->{usi},$route)} @result;
        splice @result,$position,0,@{_copy($replace)};
    }
    return [grep {!(_hash($_) && ($_->{$route?'ruleTag':'tag'}//'') eq $self->{empty_tag})} @result];
}
sub _targets {
    my ($self,$latest,$operations)=@_; my $outs=$self->_merge($latest->{$self->{out_name}},$operations,0);my $rules=$self->_merge($latest->{$self->{rule_name}},$operations,1);
    push @$outs,{tag=>$self->{empty_tag},protocol=>'blackhole',settings=>{}} unless @$outs && @$rules;
    $rules=[{type=>'field',ruleTag=>$self->{empty_tag},user=>['__shm_no_numeric_user_'.$self->{scope}],outboundTag=>$self->{empty_tag}}] unless @$rules;
    return ($outs,$rules);
}
sub _apply_pending {
    my ($self,$pending)=@_;
    for my $op (@{$pending->{operations}}) {
        my $outs=$op->{restore}?$op->{before}{outbounds}:$op->{outbound}?[$op->{outbound}]:[];
        for my $out (@$outs) {
            my ($host,$port)=$out->{protocol} eq 'wireguard'?_endpoint($out->{settings}{peers}[0]{endpoint}):@{$out->{settings}{servers}[0]}{qw(address port)};
            $self->_safe_ip($host,$port);
        }
    }
    my $latest=$self->_snippets;
    my ($outs,$rules)=$self->_targets($latest,$pending->{operations});
    $self->_request('PATCH','/api/snippets',{name=>$self->{out_name},snippet=>$outs}) if _json($outs) ne _json($latest->{$self->{out_name}});
    $self->_request('PATCH','/api/snippets',{name=>$self->{rule_name},snippet=>$rules}) if _json($rules) ne _json($latest->{$self->{rule_name}});
    $self->_request('POST','/api/snippets/actions/sync',{name=>$self->{out_name}});
    $self->{state}->clear;
}
sub _expired {
    my ($self,$value)=@_; return 0 unless defined($value) && length($value);
    _error('INVALID_SERVICE') if ref($value);
    my ($y,$m,$d,$H,$M,$S,$offset)=$value =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}:[0-9]{2})?\z/;
    _error('INVALID_SERVICE') unless defined $y; ($H,$M,$S)=($H//0,$M//0,$S//0);
    my $epoch=_eval {timegm($S,$M,$H,$d,$m-1,$y)}; _error('INVALID_SERVICE') if $@;
    my @check=gmtime($epoch); _error('INVALID_SERVICE') unless $check[0]==$S && $check[1]==$M && $check[2]==$H && $check[3]==$d && $check[4]==$m-1 && $check[5]+1900==$y;
    if (defined $offset) {
        if ($offset ne 'Z') {my ($sign,$hours,$mins)=$offset =~ /([+-])([0-9]{2}):([0-9]{2})/; _error('INVALID_SERVICE') if $hours>23 || $mins>59; $epoch-=($sign eq '+'?1:-1)*($hours*3600+$mins*60)}
    } else {
        my $old=$ENV{TZ};
        {local $ENV{TZ}=$self->{timezone}; tzset(); $epoch=eval {timelocal($S,$M,$H,$d,$m-1,$y)};my $error=$@;
            if (defined $old) {$ENV{TZ}=$old}else {delete $ENV{TZ}} tzset(); die $error if _timeout($error); _error('INVALID_SERVICE') if $error;}
    }
    return $epoch<=($self->{clock}?$self->{clock}->():time);
}
sub _operation {
    my ($self,$item)=@_; my $usi=_int($item->{user_service_id}); _int($item->{user_id});
    if (($item->{service_status}//'') eq 'REMOVED' || _truth($item->{cleanup})) {return ({usi=>$usi,outbound=>undef,rules=>[]},'cleaned')}
    _error('INVALID_CONFIG') unless _bool($item->{enabled});
    return ({usi=>$usi,outbound=>undef,rules=>[]},'disabled') unless $item->{enabled};
    return (undef,'waiting_service') unless ($item->{service_status}//'') eq 'ACTIVE';
    return (undef,'waiting_service') if $self->_expired($item->{expire});
    _error('INVALID_CONFIG') unless _hash($item->{secret}) && _hash($item->{data});
    _error('INVALID_CONFIG') if grep {$_ ne 'outbound' && $_ ne 'rules'} keys %{$item->{data}};
    if (exists $item->{data}{outbound}) {
        my $summary = _keys($item->{data}{outbound}, [qw(protocol server port)], [qw(protocol server port)]);
        _error('INVALID_OUTBOUND') unless !ref($summary->{protocol})
            && ($summary->{protocol} // '') =~ /\A(?:socks|shadowsocks|wireguard)\z/;
        _hostname($summary->{server}); _int($summary->{port}, 1, 65535);
    }
    my $out=$self->_compile($item->{secret}{outbound},$usi);my ($domains,$ips)=$self->normalize_rules($item->{data}{rules});
    my $user=$self->_request('GET',"/api/users/by-username/us_$usi",undef,1);return (undef,'waiting_service') unless defined $user;
    $user=_unwrap($user); my $numeric=_eval {_int($user->{id})}; _retry('USER_MAPPING') if $@ || ($user->{username}//'') ne "us_$usi";
    my @rules;
    for my $pair (['domain',$domains],['ip',$ips]) {
        push @rules,{type=>'field',ruleTag=>$self->{prefix}."us_${usi}_".$pair->[0],user=>["$numeric"],$pair->[0]=>$pair->[1],outboundTag=>$out->{tag}} if @{$pair->[1]};
    }
    return ({usi=>$usi,outbound=>$out,rules=>\@rules},'submitted');
}

sub _configure {
    my ($self,$settings,$timeout)=@_; _error('INVALID_PANEL_CONFIG') unless _hash($settings) && _hash($settings->{remnawave});
    my $config=$settings->{remnawave};$self->{config}=$config;
    _error('INVALID_ROUTING_CONFIG') if exists $config->{routing};
    $self->{out_name}='Out Users';$self->{rule_name}='Routing Users';
    my $api=_text($config->{api},8192);my $uri=_eval {URI->new($api)};
    _error('INVALID_PANEL_CONFIG') unless $uri && ($uri->scheme//'') =~ /\Ahttps?\z/ && $uri->can('host') && $uri->host && !defined($uri->userinfo) && !defined($uri->query) && !defined($uri->fragment);
    $self->{scope}=substr(sha256_hex(_json([$api,$self->{out_name},$self->{rule_name}])),0,20);
    $self->{prefix}='SHM_ROUTING_'.$self->{scope}.'_';$self->{empty_tag}=$self->{prefix}.'unused';
    $api =~ s{/+\z}{};$self->{api}=$api; _text($config->{token},8192);
    $self->{request_timeout}=30;my $limit=_int($timeout//90,1,90);$self->{request_timeout}=$limit if $limit<$self->{request_timeout};
    $self->{panel_host}=_hostname($uri->host);
    delete $self->{management_ips};
    $self->{timezone}=$ENV{TZ}||'Asia/Shanghai';
    _error('INVALID_PANEL_CONFIG') unless !ref($self->{timezone}) && $self->{timezone} =~ /\A[A-Za-z][A-Za-z0-9_+.-]*(?:\/[A-Za-z0-9_+.-]+)*\z/ && $self->{timezone} !~ /(?:\A|\/)\.\.(?:\/|\z)/ && -f '/usr/share/zoneinfo/'.$self->{timezone};
}
sub _pending {
    my ($self,$value)=@_; return undef unless defined $value;
    _retry('PENDING_CORRUPT') unless _hash($value) && ($value->{scope}//'') eq $self->{scope} && _array($value->{operations}) && @{$value->{operations}}<=500;
    my %seen;
    for my $op (@{$value->{operations}}) {
        _retry('PENDING_CORRUPT') unless _hash($op) && _eval {_int($op->{usi});1} && !$seen{$op->{usi}}++ && _array($op->{rules});
        _retry('PENDING_CORRUPT') if exists($op->{before}) && (!_hash($op->{before}) || !_array($op->{before}{outbounds}) || !_array($op->{before}{rules}));
    }
    return $value;
}
# Preserve the first remote baseline across a partial publish and later saves.
sub _merge_operations {
    my ($previous, $operations, $waiting) = @_;
    my @prior = @{$previous ? $previous->{operations} : []};
    my %combined = map {($_->{usi} => $_)} @prior;
    my @order = map {$_->{usi}} @prior;
    for my $op (@$operations) {
        my $old = $combined{$op->{usi}};
        $op->{before} = $old->{before} if $old && exists($old->{before});
        push @order, $op->{usi} unless $old;
        $combined{$op->{usi}} = $op;
    }
    for my $id (keys %$waiting) {
        my $old = $combined{$id};
        next unless $old && ($old->{outbound} || $old->{restore});
        _retry('PENDING_BASELINE_MISSING') unless exists $old->{before};
        $combined{$id} = {usi => 0 + $id, outbound => undef, rules => [],
            restore => JSON::PP::true, before => $old->{before}};
    }
    my @merged = map {$combined{$_}} @order;
    # Refuse before replacing a journal that must remain recoverable.
    _retry('PENDING_LIMIT') if @merged > 500;
    return \@merged;
}

sub _publish_operations {
    my ($self, $state, $previous, $operations) = @_;
    return unless @$operations;
    my $latest = $self->_snippets;
    for my $op (@$operations) {
        $op->{before} = {
            outbounds => [grep {$self->_owned($_, $op->{usi}, 0)} @{$latest->{$self->{out_name}}}],
            rules => [grep {$self->_owned($_, $op->{usi}, 1)} @{$latest->{$self->{rule_name}}}],
        } unless exists $op->{before};
    }
    my ($outs, $rules) = $self->_targets($latest, $operations);
    if ($previous || _json($outs) ne _json($latest->{$self->{out_name}})
        || _json($rules) ne _json($latest->{$self->{rule_name}})) {
        my $pending = {scope => $self->{scope}, operations => $operations};
        $state->save($pending);
        $self->_apply_pending($pending);
    }
}

sub apply {
    my ($prototype, %args) = @_;
    my $self = bless {%$prototype}, ref($prototype);
    my $payload = $args{payload};
    my (%results, @ids, $state);
    my $ok = eval {
        _error('INVALID_PAYLOAD') unless _hash($payload) && defined($payload->{feature})
            && !ref($payload->{feature}) && $payload->{feature} eq 'routing'
            && _array($payload->{items}) && @{$payload->{items}} <= 500;
        my %seen;
        for my $item (@{$payload->{items}}) {
            _error('INVALID_PAYLOAD') unless _hash($item);
            my $id = _int($item->{user_service_id});
            _error('INVALID_PAYLOAD') if $seen{$id}++;
            push @ids, $id;
        }
        $self->_configure($args{settings}, $args{timeout});
        my $factory = $args{state_factory} || $self->{state_factory};
        _retry('STATE_UNSAFE') unless ref($factory) eq 'CODE';
        $state = _eval {$factory->($self->{scope})};
        my $factory_error = $@;
        _retry(_code($factory_error, 'STATE_UNSAFE')) unless $state && !$factory_error;
        for (qw(load save clear close)) {_retry('STATE_UNSAFE') unless $state->can($_)}
        $self->{state} = $state;
        my $previous = $self->_pending($state->load);
        my @effective = @{$payload->{items}};
        if ($previous && @{$previous->{operations}}) {
            my $current = $args{current_items} || $self->{current_items};
            _retry('PENDING_SOURCE_UNAVAILABLE') unless ref($current) eq 'CODE';
            my @wanted = sort {$a <=> $b} keys %{{map {($_ => 1)}
                (@ids, map {$_->{usi}} @{$previous->{operations}})}};
            my $fresh = _eval {$current->(\@wanted)};
            _retry('PENDING_SOURCE_UNAVAILABLE') if $@ || !_array($fresh);
            my %fresh;
            for my $item (@$fresh) {
                _retry('PENDING_SOURCE_UNAVAILABLE') unless _hash($item)
                    && _eval {_int($item->{user_service_id}); 1} && !$fresh{$item->{user_service_id}};
                $fresh{$item->{user_service_id}} = $item;
            }
            _retry('PENDING_SOURCE_UNAVAILABLE') unless keys(%fresh) == @wanted
                && !grep {!exists $fresh{$_}} @wanted;
            @effective = map {$fresh{$_}} @wanted;
        }
        my (@operations, %waiting);
        my %requested = map {($_ => 1)} @ids;
        for my $item (@effective) {
            my $id = $item->{user_service_id};
            my ($op, $status);
            my $valid = _eval {
                my $effective = _copy($item);
                $effective->{cleanup} = JSON::PP::true if $requested{$id} && _truth($payload->{cleanup});
                ($op, $status) = $self->_operation($effective);
                1;
            };
            if (!$valid) {
                my $error = $@;
                die $error if !blessed($error)
                    || !$error->isa('Core::Integrations::Remnawave::Error') || $error->{retry};
                $results{$id} = {state => 'error', error => $error->{code}} if $requested{$id};
                next;
            }
            $results{$id} = {state => $status} if $requested{$id};
            push @operations, $op if $op;
            $waiting{$id} = 1 if !$op && $status eq 'waiting_service';
        }
        my $merged = _merge_operations($previous, \@operations, \%waiting);
        $self->_publish_operations($state, $previous, $merged);
        1;
    };
    my $error = $@;
    if ($state) {
        my $closed = eval {$state->close; 1};
        if (!$closed && $ok) {
            $ok = 0;
            $error = bless {code => 'STATE_UNSAFE', retry => 1}, 'Core::Integrations::Remnawave::Error';
        }
    }
    die $error if _timeout($error);
    unless ($ok) {
        my $code = _code($error);
        for my $id (@ids) {
            $results{$id} = {state => 'error', error => $code} unless ($results{$id}{state} // '') eq 'error';
        }
        return (0, {items => \%results, @ids ? () : (error => $code)});
    }
    return (1, {items => \%results});
}

1;
