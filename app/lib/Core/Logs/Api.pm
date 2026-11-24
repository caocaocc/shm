package Core::Logs::Api;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Privacy ();

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
    (my $compact = $key) =~ s/[^a-z0-9]//g;
    return 1 if $compact =~ /password|secret|(?:private|public|md5)key|authorization/;
    return 1 if $compact =~ /^(?:key|sign|postdata|patchdata|putdata|deletedata|outboundtext|credentialversions)$/;
    return $key =~ /^(?:password|token|otp_token|session_id|secret|private_key|hash|code|id_token|code_verifier|client_secret|nonce|captcha_token|captcha_answer|credential_id|userhandle|authenticatordata|clientdatajson|attestationobject|signature)$/;
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
            title => '响应码',
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

    $args{url} = Core::Privacy::request_path($args{url});
    if ($Core::Utils::sensitive_request || Core::Privacy::private_path($args{url})) {
        $args{args} = { redacted => 1 };
        delete $args{response_error};
    } elsif (ref $args{args}) {
        $args{args} = _mask_sensitive_args($args{args});
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
