package Core::Transport::Http;

use parent 'Core::Base';

use v5.32;
use utf8;
use Core::Base;
use Core::Const;
use Core::Utils qw(
    encode_json
    decode_json
    encode_utf8
);
use HTTP::Request::Common qw(
    GET
    POST
    PUT
    DELETE
    PATCH
    OPTIONS
);
use URI;
use URI::QueryParam;
use CGI;
use LWP::UserAgent;

sub send {
    my $self = shift;
    my $task = shift;
    my %server;

    if ( my $server = $task->server ) {
        %server = $server->get;
    } else {
        return undef, {
            error => 'Server not exists',
        };
    }

    my $template_id =   $task->event_settings->{template_id} ||
                        $task->settings->{template_id} ||
                        $server{settings}->{template_id};

    my $template = get_service('template', _id => $template_id );
    unless ( $template ) {
        return undef, {
            error => "template with id `$template_id` not found",
        }
    }

    my %settings = (
        %{ $server{settings} || {} },
        %{ $template->get_settings || {} },
        %{ $task->event_settings },
    );

    my $content = $template->parse(
        $task->settings->{user_service_id} ? ( usi => $task->settings->{user_service_id} ) : (),
        task => $task,
    );

    my $method = lc( $settings{method} ) || 'post';
    unless ( $method =~ /^(get|post|put|delete|patch|options)$/ ) {
        return undef, {error => "unknown method `$method`"};
    }

    my $url = $template->parse(
        data => $server{host},
        $task->settings->{user_service_id} ? ( usi => $task->settings->{user_service_id} ) : (),
        task => $task,
    );

    unless ( defined $url ) {
        return undef, {error => "not configure `URL`"};
    }

    my $verify_hostname = $settings{verify_hostname} // 1;
    my $timeout = $settings{timeout} || 10;

    my %request_args = (
        url => $url,
        method => $method,
        content_type => $settings{content_type},
        headers => $settings{headers},
        content => $content,
        verify_hostname => $verify_hostname,
        timeout => $timeout,
        sensitive => $settings{sensitive} ? 1 : 0,
    );

    my $response = $self->http( %request_args );
    # Sensitive integrations consume their response in memory. Never persist
    # credentials, arbitrary remote status text or JSON in task history/storage.
    if ($settings{sensitive}) {
        return $response->is_success
            ? (SUCCESS, {message => 'HTTP_REQUEST_OK', status => {code => $response->code}})
            : (FAIL, {error => 'HTTP_REQUEST_FAILED', status => {code => $response->code}});
    }
    my %info = (
        request => \%request_args,
        response => $response->json_content || sprintf("*NOT_JSON* Length: %d", length $response->decoded_content ),
        status => {
            code => $response->code,
            line => $response->status_line,
        },
    );

    if ( $response->is_success ) {
        if ( my $name = $settings{storage_save_key} ) {
            get_service('storage')->save(
                $name,
                $response->json_content || $response->decoded_content,
            );
        }

        return SUCCESS, {
            %info,
            message => "successful",
        };
    } else {
        my $status = SUCCESS;
        # TODO: make array of success statuses
        if ( $response->code >= 500 ) {
            $status = FAIL;
        }

        return $status, {
            error => $response->status_line,
            %info,
        };
    }
}

sub HTTP::Response::json_content {
    my $self = shift;
    return undef unless $self->header('content-type') =~ m/application\/json/gi;
    return decode_json( $self->decoded_content );
}

sub lwp {
    my $self = shift;
    my %args = (
        timeout => 10,
        keep_alive => 4,
        verify_hostname => 1,
        no_redirect => 0,
        no_proxy => 0,
        ca_bundle => undef,
        max_size => undef,
        @_,
    );

    my $http_proxy  = $args{no_proxy} ? '' : ($ENV{HTTP_PROXY}  || $ENV{http_proxy}  || '');
    my $https_proxy = $args{no_proxy} ? '' : ($ENV{HTTPS_PROXY} || $ENV{https_proxy} || '');
    my $no_proxy    = $args{no_proxy} ? '' : ($ENV{NO_PROXY}    || $ENV{no_proxy}    || '');

    state %ua_cache;
    my $cache_key = join('|', $args{timeout}, $args{verify_hostname} // 0,
        $args{no_redirect} // 0, $args{no_proxy} // 0, $args{ca_bundle} // '', $args{max_size} // '',
        $http_proxy, $https_proxy, $no_proxy);

    return $ua_cache{$cache_key} //= do {
        my $ua = LWP::UserAgent->new(
            agent => 'SHM',
            timeout => $args{timeout},
            keep_alive => $args{keep_alive},
            ssl_opts => {
                verify_hostname => $args{verify_hostname},
                $args{ca_bundle} ? (SSL_ca_file => $args{ca_bundle}) : (),
            },
            $args{no_redirect} ? (max_redirect => 0, requests_redirectable => []) : (),
            defined($args{max_size}) ? (max_size => $args{max_size}) : (),
        );
        $ua->proxy('http',  $http_proxy)  if $http_proxy;
        $ua->proxy('https', $https_proxy) if $https_proxy;
        if ( $no_proxy ) {
            $ua->no_proxy( split /\s*,\s*/, $no_proxy );
        }
        $ua;
    };
}

sub http {
    my $self = shift;
    my %args = (
        url => undef,
        method => 'post',
        content_type => '',
        headers => {},
        content => '',
        verify_hostname => 1,
        timeout => 10,
        keep_alive => 4,
        binary => 0,
        sensitive => 0,
        no_redirect => 0,
        no_proxy => 0,
        ca_bundle => undef,
        max_size => undef,
        @_,
    );

    if ($args{sensitive}) {
        # A caller cannot weaken these protections for a sensitive request.
        @args{qw(verify_hostname no_redirect no_proxy)} = (1, 1, 1);
        $args{max_size} //= 16 * 1024 * 1024;
        delete $self->{response};
    }

    $args{content_type} ||= 'application/json; charset=utf-8';

    my $method = uc $args{method};

    my $ua = $self->lwp(
        %args{ qw(
            timeout
            keep_alive
            verify_hostname
            no_redirect
            no_proxy
            ca_bundle
            max_size
        ) }
    );

    if ($method eq 'GET') {
        my $uri = URI->new($args{url});
        my %q = CGI->new($args{content})->Vars();
        $uri->query_param_append($_, $q{$_}) for keys %q;
        $args{url} = $uri->as_string;
    }

    my $content = $args{content};
    if ( ref $content && $args{content_type} !~ /form-data/i ) {
        $content = encode_json( $content );
    }

    my $request_content = ref $content ? $content : encode_utf8( $content );

    no strict 'refs';
    my $response = $ua->request( &{$method}(
        $args{url},
        Content_Type => $args{content_type},
        Content => $request_content,
        %{ $args{headers} || {} },
    ));

    if ($args{sensitive} && $response->header('Client-Aborted')) {
        return HTTP::Response->new(502, 'HTTP_RESPONSE_TOO_LARGE');
    }

    unless ($args{sensitive}) {
        $self->{response} = $response;
        logger->dump( $response->request );
    }

    # Декодирование UTF-8 для текстового контента
    if (!$args{binary}) {
        my $content = $response->decoded_content;
        if (!utf8::is_utf8($content)) {
            utf8::decode($content);
            # Заменяем контент в response объекте
            $response->{_content} = $content;
        }
    }

    return $response;
}

sub response { shift->{response} };

sub _response_body {
    my ($response, $binary, $sensitive) = @_;
    return $response->content if $binary;
    my $body = $response->decoded_content;
    return $response->json_content || $body unless $sensitive;
    # Core::Utils::decode_json logs malformed input. A provider response can
    # contain credentials even when it is not valid JSON, so parse quietly.
    if (($response->header('content-type') || '') =~ m{application/json}i) {
        require JSON::PP;
        my $json = eval { JSON::PP->new->decode($body) };
        return $json unless $@;
    }
    return $body;
}

sub _http {
    my $self = shift;
    my $method = shift;
    my $url = shift;
    my %args = (
        binary => 0,
        get_smart_args( @_ ),
    );

    my $response = $self->http(
        method => $method,
        url => $url,
        %args,
    );

    if ($args{full_response}) {
        return {
            http_headers     => { $response->headers->flatten },
            http_code        => $response->code,
            http_status_line => $response->status_line,
            body             => _response_body($response, $args{binary}, $args{sensitive}),
        };
    } else {
        return _response_body($response, $args{binary}, $args{sensitive});
    }
}

sub get { return shift->_http( 'get', @_ ) }
sub put { return shift->_http( 'put', @_ ) }
sub post { return shift->_http( 'post', @_ ) }
sub delete { return shift->_http( 'delete', @_ ) }
sub patch { return shift->_http( 'patch', @_ ) }
sub options { return shift->_http( 'options', @_ ) }

1;
