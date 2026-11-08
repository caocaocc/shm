package Core::Logs::Api;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;

sub table { return 'logs_api' }
sub dbh { shift->dbh_auto_commit }

sub _mask_sensitive_args {
    my $value = shift;

    if ( ref $value eq 'HASH' ) {
        my %copy;
        for my $key ( keys %$value ) {
            if ( _is_sensitive_key($key) ) {
                $copy{$key} = '***';
            } else {
                $copy{$key} = _mask_sensitive_args( $value->{$key} );
            }
        }
        return \%copy;
    }

    if ( ref $value eq 'ARRAY' ) {
        return [ map { _mask_sensitive_args($_) } @$value ];
    }

    return $value;
}

sub _is_sensitive_key {
    my $key = lc( shift // '' );
    return 1 if $key =~ /^(?:password|token|otp_token|session_id|secret|private_key|hash|code|id_token|code_verifier|client_secret|nonce|captcha_token|captcha_answer|credential_id|userhandle|authenticatordata|clientdatajson|attestationobject|signature|sign|authorization|(?:get|post|put|patch|delete)data)$/;
    return $key =~ /(?:\A|_)(?:password|passwd|secret|token|key|private_key|public_key|api_key|md5_key)(?:_file)?\z/
        || $key =~ /(?:privatekey|publickey|apikey|md5key)\z/;
}

sub _log_path {
    my $path = shift // '';
    return '/' if ref $path;
    $path =~ s{\A[A-Za-z][A-Za-z0-9+.-]*://[^/]*}{};
    $path =~ s/[?#].*\z//s;
    # Routing layers may decode escaped separators or collapse slash/dot
    # segments before dispatch. Do the same for the redaction decision.
    for (1..4) {
        my $previous = $path;
        $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        last if $path eq $previous;
    }
    $path =~ tr{\\}{/};
    $path =~ s{[?#].*\z}{}s;
    my @parts;
    for my $part (split m{/+}, $path) {
        next if $part eq '' || $part eq '.';
        if ($part eq '..') { pop @parts; next; }
        push @parts, $part;
    }
    $path = '/' . join('/', @parts);
    $path =~ s{\A/(?:shm/)?v1(?:\.cgi)?(?=/|\z)}{}i;
    return $path || '/';
}

sub structure {
    return {
        user_id => {
            type => 'number',
            auto_fill => 1,
            title => '用户 ID',
        },
        date => {
            type => 'now',
            title => '日期',
        },
        url => {
            type => 'text',
            required => 1,
            title => 'URL',
        },
        method => {
            type => 'text',
            required => 1,
            title => '方法',
        },
        args => {
            type => 'json',
            title => '参数',
        },
        descr => {
            type => 'text',
            title => '说明',
        },
        duration => {
            type => 'number',
            default => 0,
            title => '耗时',
        },
        response_code => {
            type => 'number',
            required => 1,
            title => '响应代码',
        },
        ip => {
            type => 'text',
            title => 'IP 地址',
        },
        response_error => {
            type => 'text',
            title => '错误',
        },
    }
}

sub add {
    my $self = shift;
    my %args = (
        url => undef,
        method => undef,
        args => {},
        response_code => undef,
        duration => 0,
        @_,
    );

    my $path = _log_path($args{url});
    # Query parameters already have their own masked args field. Never retain
    # a second, unfiltered copy in the URL column.
    $args{url} = $path;
    my $config_write = uc($args{method} // '') =~ /\A(?:POST|PUT|PATCH|DELETE)\z/
        && $path =~ m{\A/admin/config(?:/|\z)}i;
    if ($config_write || $path =~ m{\A/(?:admin/)?user/service/options(?:/(?:retry|secret))?\z}i) {
        # These endpoints also accept arbitrary secret object keys. Never log
        # raw bodies, malformed JSON, or a client-selected secret field name.
        $args{args} = {redacted => 1};
        $args{response_error} = '敏感配置请求失败'
            if $config_write && defined($args{response_error}) && length($args{response_error});
    } else {
        $args{args} = _mask_sensitive_args( $args{args} ) if ref $args{args};
    }

    $self->{user_id} = 0 unless $self->user_id;

    return $self->SUPER::add( %args );
}

sub cleanup {
    my $self = shift;
    my $days = cfg('billing')->{cleanup}->{ApiLogs} // 30;
    return $self unless $days;

    $self->_delete( where => {
        date => { '<', \[ 'NOW() - INTERVAL ? DAY', $days ] },
    });

    return $self;
}

1;
