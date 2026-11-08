package Core::ServiceOptions;

use v5.14;
use strict;
use warnings;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Const;
use Core::Utils qw(encode_json decode_json now encrypt_aes256_gcm_base64 decrypt_aes256_gcm_base64);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Digest::SHA qw(sha256_hex);
use Crypt::PRNG qw(random_bytes);
use Fcntl qw(:DEFAULT :flock :mode O_NOFOLLOW);
use File::Path qw(make_path);
use IO::Handle ();
use Time::HiRes ();

my $JSON = JSON::PP->new->canonical->utf8;
my %STATES = map { $_ => 1 } qw(submitted disabled waiting_service cleaned error);

sub _fail { die { options_error => 1, status => $_[0], message => $_[1] } }
sub _json { $JSON->encode($_[0]) }
sub _copy { $JSON->decode(_json($_[0])) }

sub _api {
    my ($self, $code) = @_;
    my $result;
    my $ok = eval { $result = get_service('Consumption')->atomic($code); 1 };
    return $result if $ok;
    my $error = $@;
    my $report = get_service('report');
    if (ref($error) eq 'HASH' && $error->{options_error}) {
        $report->status($error->{status});
        $report->add_error($error->{message});
    } elsif (!ref($error) && $error =~ /\ASERVICE_OPTIONS_KEY_MISSING\s*\z/) {
        $report->status(503);
        $report->add_error('SERVICE_OPTIONS_KEY_MISSING');
    } else {
        $report->status(500);
        $report->add_error('服务选项处理失败，请联系管理员');
        logger->warning('ServiceOptions operation failed');
    }
    return undef;
}

sub _actor { get_service('user')->authenticated }

sub _service {
    my ($self, $id, $admin, $lock) = @_;
    _fail(400, '用户服务编号无效') unless defined($id) && !ref($id) && "$id" =~ /\A[1-9]\d*\z/;
    my $actor = _actor();
    _fail(403, '无权执行此操作') if $admin && !$actor->is_admin;
    my $row = $self->dbh->selectrow_hashref(
        'SELECT * FROM user_services WHERE user_service_id=?' . ($lock ? ' FOR UPDATE' : ''), undef, $id);
    _fail(404, '用户服务不存在') unless $row;
    _fail(403, '无权操作其他用户的配置') unless $admin || $row->{user_id} == $actor->id;
    my $us = get_service('us', _id => $id);
    $row->{settings} = decode_json($row->{settings}) || {} unless ref($row->{settings}) eq 'HASH';
    $us->res($row);
    return $us;
}

sub target_for {
    my ($self, $us) = @_;
    # Provisioning owns the assigned server. Options must never choose a server
    # group member or infer a target from another customer's configuration.
    my $instance_settings = $us->res->{settings};
    return undef unless ref($instance_settings) eq 'HASH';
    my $server_id = $instance_settings->{server_id};
    return undef unless defined($server_id) && !ref($server_id) && length("$server_id") && "$server_id" ne '0';
    _fail(503, '服务目标服务器编号无效') unless "$server_id" =~ /\A[1-9]\d*\z/;
    my ($raw) = $self->dbh_auto_commit->selectrow_array(
        'SELECT settings FROM servers WHERE server_id=?', undef, $server_id);
    return undef unless defined $raw;
    my $settings = ref($raw) eq 'HASH' ? $raw : decode_json($raw);
    return undef unless ref($settings) eq 'HASH';
    my @bindings;
    for my $short_name (sort keys %$settings) {
        next unless ref($settings->{$short_name}) eq 'HASH' && _adapter_class($short_name);
        my $adapter = _load_adapter($short_name, 1);
        next unless $adapter;
        my $metadata = _metadata($adapter);
        push @bindings, {target => {adapter => $short_name, server_id => 0 + $server_id},
            feature => $metadata->{feature}};
    }
    _fail(503, '服务服务器匹配到多个选项适配模块') if @bindings > 1;
    return $bindings[0];
}

sub _group {
    my ($binding) = @_;
    return sha256_hex(_json([@{$binding->{target}}{qw(adapter server_id)}, $binding->{feature}]));
}

sub _adapter_class {
    my ($adapter) = @_;
    return undef unless defined($adapter) && !ref($adapter) && length($adapter) <= 64
        && $adapter =~ /\A[a-z][a-z0-9]*(?:_[a-z][a-z0-9]*)*\z/;
    return 'Core::Integrations::' . join('', map {ucfirst($_)} split /_/, $adapter);
}

sub _load_adapter {
    my ($short_name, $optional) = @_;
    my $class = _adapter_class($short_name);
    _fail(503, '服务选项适配模块名称无效') unless $class;
    my $file = $class;
    $file =~ s{::}{/}g;
    $file .= '.pm';
    # Per-call objects avoid retaining plaintext or tokens in a global entity
    # cache. Only installed integration modules in this namespace can load.
    my $loaded = eval {require $file; 1};
    my $error = $@;
    die $error if !ref($error) && ($error // '') =~ /\ASERVICE_OPTIONS_TIMEOUT\s*\z/;
    unless ($loaded) {
        # Skip only an absent candidate itself. Missing dependencies, syntax
        # errors and broken installed modules are configuration failures.
        return undef if $optional && !ref($error)
            && $error =~ /\ACan't locate \Q$file\E in \@INC\b/;
        _fail(503, '服务选项适配模块不可用');
    }
    my $adapter = eval {$class->new};
    $error = $@;
    die $error if !ref($error) && ($error // '') =~ /\ASERVICE_OPTIONS_TIMEOUT\s*\z/;
    _fail(503, '服务选项适配模块不可用') unless blessed($adapter)
        && $adapter->can('metadata') && $adapter->can('apply');
    return $adapter;
}

sub _metadata {
    my ($adapter) = @_;
    my $metadata = eval {$adapter->metadata};
    my $error = $@;
    die $error if !ref($error) && ($error // '') =~ /\ASERVICE_OPTIONS_TIMEOUT\s*\z/;
    _fail(503, '服务选项适配模块信息无效') if $error;
    _fail(503, '服务选项适配模块信息无效') unless ref($metadata) eq 'HASH'
        && keys(%$metadata) == 2 && exists($metadata->{feature}) && exists($metadata->{requires_secret})
        && !ref($metadata->{feature}) && ($metadata->{feature} // '') =~ /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
        && length($metadata->{feature}) <= 64
        && defined($metadata->{requires_secret})
        && (!ref($metadata->{requires_secret}) || JSON::PP::is_bool($metadata->{requires_secret}))
        && "$metadata->{requires_secret}" =~ /\A[01]\z/;
    return {feature => $metadata->{feature}, requires_secret => $metadata->{requires_secret} ? 1 : 0};
}

sub _target {
    my ($self, $binding) = @_;
    _fail(503, 'SERVICE_OPTIONS_TARGET_INVALID') unless _valid_binding($binding);
    my $adapter = _load_adapter($binding->{target}{adapter});
    my $metadata = _metadata($adapter);
    _fail(409, 'SERVICE_OPTIONS_TARGET_CHANGED') unless $metadata->{feature} eq $binding->{feature};
    my $server_id = $binding->{target}{server_id};
    my $row = $self->dbh_auto_commit->selectrow_hashref(
        'SELECT * FROM servers WHERE server_id=?', undef, $server_id);
    _fail(503, '服务选项同步服务器无效') unless $row;
    my $server = get_service('server', _id => $server_id);
    _fail(503, '服务选项同步服务器无效') unless $server;
    $row->{settings} = decode_json($row->{settings}) || {} unless ref($row->{settings}) eq 'HASH';
    $server->res($row);
    return ($server, $adapter, $metadata);
}

sub _directory {
    # Official Compose shares /app/data between API/core and spool. Its older
    # SHM_DATA_DIR=/var/shm default is not that shared volume.
    my $root = ($ENV{SHM_ROOT_DIR} || '/app') . '/data';
    my $dir = "$root/service-options";
    my $uid = _storage_uid();
    die "Service options storage requires the service account\n" unless $> == 0 || $> == $uid;
    make_path($dir, {mode => 0700}) unless -e $dir || -l $dir;
    my @stat = lstat($dir);
    die "Unsafe service options directory\n" unless @stat && S_ISDIR($stat[2])
        && !S_ISLNK($stat[2]) && ($stat[4] == $uid || ($> == 0 && $stat[4] == 0))
        && ($stat[2] & 0777) == 0700;
    chown($uid, -1, $dir) == 1 or die "Cannot initialize service options directory\n" if $> == 0;
    return $dir;
}

sub _storage_uid { my @pw = getpwnam('www-data'); return @pw ? $pw[2] : 33 }
sub initialize_storage { $_[0]->_directory }
sub _sync_directory {
    my $self = shift;
    sysopen(my $dir, $self->_directory, O_RDONLY | O_NOFOLLOW)
        or die "Cannot open service options directory\n";
    $dir->sync or die "Cannot synchronize service options directory\n";
    close($dir) or die "Cannot close service options directory\n";
}
sub _secure_file {
    my ($fh) = @_;
    my @stat = stat($fh);
    my $uid = _storage_uid();
    die "Unsafe service options file\n" unless S_ISREG($stat[2]) && $stat[3] == 1
        && ($stat[2] & 0777) == 0600
        && ($stat[4] == $uid || ($> == 0 && $stat[4] == 0));
    chown($uid, -1, $fh) == 1 or die "Cannot initialize service options file\n" if $> == 0;
}

sub _open_lock {
    my ($self, $name) = @_;
    my $path = $self->_directory . "/$name.lock";
    sysopen(my $fh, $path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600) or die "Cannot open service options lock\n";
    _secure_file($fh);
    return $fh;
}

sub _key {
    my $self = shift;
    my $lock = $self->_open_lock('key');
    flock($lock, LOCK_EX) or die "Cannot lock service options key\n";
    my $path = $self->_directory . '/key';
    unless (-e $path || -l $path) {
        die "SERVICE_OPTIONS_KEY_MISSING\n" if $self->_has_encrypted_secrets || $self->_has_encrypted_state;
        my $temp = $path . '.' . unpack('H*', random_bytes(12));
        sysopen(my $out, $temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
            or die "Cannot create service options key\n";
        binmode $out;
        my $ok = eval {
            _secure_file($out);
            print {$out} random_bytes(32) or die "Cannot write service options key\n";
            $out->sync or die "Cannot synchronize service options key\n";
            close($out) or die "Cannot close service options key\n";
            rename($temp, $path) or die "Cannot publish service options key\n";
            $self->_sync_directory;
            1;
        };
        unless ($ok) { close $out; unlink $temp; die "Cannot initialize service options key\n" }
    }
    sysopen(my $in, $path, O_RDONLY | O_NOFOLLOW) or die "Cannot read service options key\n";
    _secure_file($in);
    binmode $in;
    my $key = do { local $/; <$in> };
    close $in;
    die "Invalid service options key\n" unless defined($key) && length($key) == 32;
    return $key;
}

sub _has_encrypted_secrets {
    my $self = shift;
    # A missing key must not be replaced when the fresh-storage premise is
    # false. Check only structure; never interpret or convert unknown values.
    my ($encrypted, $unrecognized) = $self->dbh_auto_commit->selectrow_array(q{
        SELECT COALESCE(MAX(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(settings,'$.options.secret')),'') NOT IN ('','null')),0),
            COALESCE(MAX(JSON_TYPE(JSON_EXTRACT(settings,'$.options'))<>'OBJECT'
                OR (JSON_LENGTH(JSON_EXTRACT(settings,'$.options'))>0 AND (
                    NOT JSON_CONTAINS(CAST('["feature","enabled","target","data","secret","status","error"]' AS JSON),
                        JSON_KEYS(JSON_EXTRACT(settings,'$.options')))
                    OR COALESCE(JSON_TYPE(JSON_EXTRACT(settings,'$.options.status')),'')<>'STRING'))),0)
        FROM user_services WHERE JSON_CONTAINS_PATH(settings,'one','$.options')
    });
    _fail(409, 'SERVICE_OPTIONS_CONFIG_INVALID') if $unrecognized;
    return $encrypted;
}

sub _has_encrypted_state {
    my $self = shift;
    my $dir = $self->_directory;
    opendir(my $dh, $dir) or die "Cannot inspect service options state\n";
    my $exists = scalar grep {/\Astate-[a-f0-9]{64}\.json\z/} readdir($dh);
    closedir $dh;
    return $exists ? 1 : 0;
}

sub _aad { 'shm:service-options:' . $_[0]->get_user_id . ':' . $_[0]->id }
sub _encrypt { encrypt_aes256_gcm_base64(_json($_[2]), $_[0]->_key, _aad($_[1])) }
sub _decrypt {
    my ($self, $us, $box) = @_;
    my $secret = $JSON->decode(decrypt_aes256_gcm_base64($box, $self->_key, _aad($us)));
    die "Invalid service options secret\n" unless ref($secret) eq 'HASH' && keys %$secret;
    return $secret;
}

sub _valid_binding {
    my ($binding) = @_;
    return 0 unless ref($binding) eq 'HASH';
    my $feature = $binding->{feature};
    return 0 unless !ref($feature) && ($feature // '') =~ /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
        && length($feature) <= 64;
    my $target = $binding->{target};
    return 0 unless ref($target) eq 'HASH' && keys(%$target) == 2;
    # Regex/string context must not alter numeric JSON scalar flags in the
    # target, task or CAS snapshot. Validate detached scalar values only.
    my ($adapter, $server_id) = @{$target}{qw(adapter server_id)};
    return _adapter_class($adapter) && !ref($server_id) && ($server_id // '') =~ /\A[1-9]\d*\z/;
}

sub _binding {
    my ($config) = @_;
    return undef unless $config->{feature} && $config->{target};
    return {feature => $config->{feature}, target => _copy($config->{target})};
}

sub _config {
    my $settings = $_[0]->res->{settings};
    return {} unless ref($settings) eq 'HASH' && exists($settings->{options});
    my $config = $settings->{options};
    _fail(409, 'SERVICE_OPTIONS_CONFIG_INVALID') unless ref($config) eq 'HASH';
    return {} unless keys %$config;
    $config = _copy($config);
    my %allowed = map {$_ => 1} qw(feature enabled target data secret status error);
    _fail(409, 'SERVICE_OPTIONS_CONFIG_INVALID') if grep {!$allowed{$_}} keys %$config;
    my ($enabled, $status, $secret, $error) = @{$config}{qw(enabled status secret error)};
    _fail(409, 'SERVICE_OPTIONS_CONFIG_INVALID') unless _valid_binding($config)
        && defined($enabled) && (!ref($enabled) || JSON::PP::is_bool($enabled)) && "$enabled" =~ /\A[01]\z/
        && ref($config->{data}) eq 'HASH' && !ref($status)
        && ($status // '') =~ /\A(?:queued|submitted|disabled|waiting_service|cleaned|error)\z/
        && (!exists($config->{secret}) || defined($secret) && !ref($secret) && length($secret))
        && (!exists($config->{error}) || $status eq 'error' && !ref($error)
            && ($error // '') =~ /\A[A-Z][A-Z0-9_]{0,63}\z/);
    return $config;
}

sub _set_status {
    my ($config, $status, $error) = @_;
    $config->{status} = $status;
    delete $config->{error};
    $config->{error} = _error_code($error) if $status eq 'error';
}

sub _sync_error {
    my ($error, $fallback) = @_;
    return $1 if !ref($error) && ($error // '') =~ /\A(SERVICE_OPTIONS_(?:TIMEOUT|KEY_MISSING))\s*\z/;
    return $error->{message} if ref($error) eq 'HASH' && $error->{options_error}
        && ($error->{message} // '') =~ /\ASERVICE_OPTIONS_(?:CONFIG_INVALID|TARGET_INVALID|TARGET_CHANGED)\z/;
    return $fallback;
}

sub _error_code {
    my ($code) = @_;
    return defined($code) && !ref($code) && $code =~ /\A[A-Z][A-Z0-9_]{0,63}\z/
        ? $code : 'SERVICE_OPTIONS_ERROR';
}

sub _public {
    my ($self, $us, $binding) = @_;
    my $stored = _config($us);
    my $state = $stored->{status} // 'disabled';
    return { supported => $binding ? JSON::PP::true : JSON::PP::false,
        feature => $stored->{feature} || ($binding ? $binding->{feature} : undef),
        enabled => $stored->{enabled} ? JSON::PP::true : JSON::PP::false,
        data => ref($stored->{data}) eq 'HASH' ? $stored->{data} : {},
        has_secret => $stored->{secret} ? JSON::PP::true : JSON::PP::false,
        status => $state, $state eq 'error' ? (error => _error_code($stored->{error})) : () };
}

sub get_for_api {
    my ($self, %args) = @_;
    return $self->_api(sub { my $us = $self->_service($args{user_service_id}, 0, 0);
        $self->_public($us, $self->target_for($us)) });
}

sub secret_for_api {
    my ($self, %args) = @_;
    return $self->_api(sub {
        # Deliberately use the owner boundary, even for an administrator. The
        # ordinary read/save responses remain redacted.
        my $us = $self->_service($args{user_service_id}, 0, 0);
        _fail(409, '已移除的服务不能读取机密配置') if $us->get_status eq STATUS_REMOVED;
        my $stored = _config($us);
        return {secret => $stored->{secret} ? $self->_decrypt($us, $stored->{secret}) : {}};
    });
}

sub admin_get_for_api {
    my ($self, %args) = @_;
    return $self->_api(sub { my $us = $self->_service($args{user_service_id}, 1, 0);
        $self->_public($us, $self->target_for($us)) });
}

sub _write {
    my ($self, $us, $config, $expected, $service_status) = @_;
    my $query = q{UPDATE user_services SET settings=JSON_SET(COALESCE(settings,JSON_OBJECT()), '$.options', CAST(? AS JSON)) WHERE user_service_id=? AND user_id=?};
    my @bind = (_json($config), $us->id, $us->get_user_id);
    if (defined $expected) {
        $query .= q{ AND JSON_EXTRACT(settings,'$.options')=CAST(? AS JSON) AND status=?};
        push @bind, _json($expected), $service_status;
    }
    my $result = $self->dbh->do($query, undef, @bind);
    die "Cannot save service options\n" unless defined $result;
    $us->reload;
    return $result + 0;
}

sub _no_secrets_in_data {
    my ($value) = @_;
    if (ref($value) eq 'HASH') {
        for my $key (keys %$value) {
            my $name = lc($key); $name =~ s/[^a-z0-9]//g;
            _fail(400, '机密字段必须放入 secret 对象') if $name =~ /\A(?:password|passwd|pass|privatekey|presharedkey|secret|secretkey|token|apikey|credential|credentials|rawconfig|configuri|configurl)\z/;
            _no_secrets_in_data($value->{$key});
        }
    } elsif (ref($value) eq 'ARRAY') { _no_secrets_in_data($_) for @$value }
    elsif (defined($value) && !ref($value)) {
        _fail(400, '机密字段必须放入 secret 对象')
            if "$value" =~ m{\A[A-Za-z][A-Za-z0-9+.-]*://[^/\s]+@}
            || "$value" =~ /-----BEGIN [^-]*PRIVATE KEY-----/;
    }
}

sub save_for_api { my ($self, %args) = @_; return $self->_save(0, %args) }
sub admin_disable_for_api {
    my ($self, %args) = @_;
    return $self->_api(sub { _fail(403, '管理员接口仅支持停用') if !exists($args{enabled}) || $args{enabled};
        $self->_save_inner(1, user_service_id => $args{user_service_id}, enabled => 0) });
}
sub _save {
    my ($self, $admin, %args) = @_;
    return $self->_api(sub { $self->_save_inner($admin, %args) });
}
sub _save_inner {
    my ($self, $admin, %args) = @_;
    my $us = $self->_service($args{user_service_id}, $admin, 1);
    _fail(409, '已移除的服务不能保存新配置') if $us->get_status eq STATUS_REMOVED;
    _fail(400, '必须提供有效的 enabled 开关') unless exists($args{enabled}) && defined($args{enabled})
        && (!ref($args{enabled}) || JSON::PP::is_bool($args{enabled})) && "$args{enabled}" =~ /\A[01]\z/;
    my $config = _config($us);
    my $old_binding = _binding($config);
    my $current_binding = !$args{enabled} && $old_binding ? undef : $self->target_for($us);
    my $binding = $current_binding;
    # Disabling/removal must retire the target that actually holds the old
    # configuration. A new target is permitted only after that acknowledgment.
    if (!$args{enabled} && $old_binding) { $binding = $old_binding }
    _fail(409, 'SERVICE_OPTIONS_TARGET_CHANGED') if $args{enabled} && $old_binding && $current_binding
        && $old_binding->{feature} ne $current_binding->{feature};
    if ($args{enabled} && $old_binding && $current_binding
        && _group($old_binding) ne _group($current_binding)
        && ($config->{status} // '') !~ /\A(?:disabled|cleaned)\z/) {
        _fail(409, '配置目标已变更，请先停用现有配置并等待同步完成');
    }
    _fail(403, '该套餐不支持服务选项') unless $binding;
    my (undef, undef, $metadata) = $self->_target($binding);
    if (exists $args{data}) {
        _fail(400, 'data 必须为对象且不能超过64KiB') unless ref($args{data}) eq 'HASH' && length(_json($args{data})) <= 65536;
        _no_secrets_in_data($args{data});
        $config->{data} = _copy($args{data});
    }
    $config->{data} ||= {};
    if (exists $args{secret}) {
        _fail(400, 'secret 必须为对象且不能超过64KiB') unless ref($args{secret}) eq 'HASH' && length(_json($args{secret})) <= 65536;
        if (keys %{$args{secret}}) { $config->{secret} = $self->_encrypt($us, $args{secret}) }
        else { delete $config->{secret} }
    }
    if ($args{enabled} && $metadata->{requires_secret}) {
        _fail(400, '启用配置前必须提供机密信息') unless $config->{secret};
        $self->_decrypt($us, $config->{secret});
    }
    $config->{enabled} = $args{enabled} ? 1 : 0;
    $config->{feature} = $binding->{feature};
    $config->{target} = _copy($binding->{target});
    my $waiting = $config->{enabled} && $us->get_status ne STATUS_ACTIVE;
    _set_status($config, $waiting ? 'waiting_service' : 'queued');
    $self->_write($us, $config);
    $self->enqueue($binding, [$us->id]) unless $waiting;
    return $self->_public($us, $binding);
}

sub enqueue {
    my ($self, $binding, $ids) = @_;
    return undef unless @$ids;
    my $id = get_service('spool', user_id => 1)->add(user_id => 1, prio => 100,
        event => {name => 'SERVICE_OPTIONS', kind => 'ServiceOptions', method => 'sync_task', title => '同步服务选项'},
        settings => {user_service_ids => [map {0 + $_} @$ids], feature => $binding->{feature}, target => _copy($binding->{target})});
    die "Cannot enqueue service options synchronization\n" unless $id;
    return $id;
}

sub admin_retry_for_api {
    my ($self, %args) = @_;
    return $self->_api(sub {
        my $us = $self->_service($args{user_service_id}, 1, 1);
        my $config = _config($us);
        _fail(404, '尚未保存服务选项') unless $config->{feature};
        my $current = $config->{enabled} && $us->get_status ne STATUS_REMOVED
            ? $self->target_for($us) : undef;
        my $binding = _binding($config) || $current or _fail(403, '服务选项目标不可用');
        if ($config->{enabled} && $us->get_status ne STATUS_REMOVED
            && (!$current || _group($current) ne _group($binding))) {
            _set_status($config, 'error', 'SERVICE_OPTIONS_TARGET_CHANGED');
            $self->_write($us, $config);
            return $self->_public($us, $current);
        }
        $self->_target($binding);
        my $waiting = $config->{enabled} && $us->get_status ne STATUS_ACTIVE && $us->get_status ne STATUS_REMOVED;
        _set_status($config, $waiting ? 'waiting_service' : 'queued');
        $self->_write($us, $config);
        $self->enqueue($binding, [$us->id]) unless $waiting;
        return $self->_public($us, $binding);
    });
}

sub lifecycle_changed {
    my ($self, $us, $status) = @_;
    return unless $status eq STATUS_REMOVED || $status eq STATUS_ACTIVE;
    my $config = _config($us);
    return unless $config->{feature} && ($config->{status} // '') ne 'cleaned';
    my $binding = _binding($config);
    if ($status eq STATUS_ACTIVE && $config->{enabled}) {
        my $current = eval {$self->target_for($us)};
        if (!$current || !$binding || _group($current) ne _group($binding)) {
            _set_status($config, 'error', 'SERVICE_OPTIONS_TARGET_CHANGED');
            $self->_write($us, $config);
            return;
        }
    }
    return unless $binding;
    _set_status($config, 'queued');
    $self->_write($us, $config);
    $self->enqueue($binding, [$us->id]) unless $status eq STATUS_REMOVED && $self->{_defer_cleanup};
}

sub cleanup {
    my $self = shift;
    die "ServiceOptions cleanup requires admin\n" unless _actor()->is_admin;
    my $rows = $self->dbh->selectall_arrayref(q{SELECT * FROM user_services WHERE status=? AND JSON_EXTRACT(settings,'$.options.feature') IS NOT NULL AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(settings,'$.options.status')),'')<>'cleaned'}, {Slice => {}}, STATUS_REMOVED);
    my %groups;
    for my $row (@$rows) {
        my $us = get_service('us', _id => $row->{user_service_id});
        next unless $us;
        $row->{settings} = decode_json($row->{settings}) || {} unless ref($row->{settings}) eq 'HASH';
        $us->res($row);
        my $config = _config($us);
        my $binding = _binding($config);
        next unless $binding;
        my $key = _group($binding);
        $groups{$key}{binding} = $binding;
        push @{$groups{$key}{ids}}, $us->id;
    }
    for my $group (values %groups) {
        my @ids = @{$group->{ids}};
        while (@ids) { my @batch = splice(@ids, 0, 100); $self->enqueue($group->{binding}, \@batch) }
    }
    return scalar @$rows;
}

sub _results {
    my ($value, $ids) = @_;
    die "Invalid synchronization receipt\n" unless ref($value) eq 'HASH' && ref($value->{items}) eq 'HASH';
    die "Invalid synchronization receipt\n" if length(_json($value)) > 131072;
    my %expected = map { ($_ => 1) } @$ids;
    die "Invalid synchronization receipt\n" unless keys(%{$value->{items}}) == keys(%expected);
    my %safe;
    for my $id (keys %{$value->{items}}) {
        my $item = $value->{items}{$id};
        die "Invalid synchronization receipt\n" unless $expected{$id} && ref($item) eq 'HASH'
            && !ref($item->{state}) && $STATES{$item->{state} // ''};
        $safe{$id} = {state => $item->{state}, exists($item->{error}) ? (error => _error_code($item->{error})) : ()};
    }
    return \%safe;
}

# Queue history needs useful diagnostics without receiving adapter payloads or
# exceptions. Only numeric instance identities and bounded fixed codes survive.
sub _task_diagnostics {
    my ($errors, $fallback, $include_all) = @_;
    my @ids = sort {$a <=> $b} grep {/\A[1-9]\d{0,19}\z/} keys %$errors;
    splice(@ids, 100) if @ids > 100;
    my %safe = map {$_ => _error_code($errors->{$_})} @ids;
    my %codes = map {$_ => 1} values %safe;
    return {error => keys(%codes) == 1 ? (keys %codes)[0] : _error_code($fallback),
        keys(%safe) && ($include_all || keys(%codes) > 1) ? (errors => \%safe) : ()};
}

# The adapter may need to repair a prior partially published operation before
# handling this batch. Only instances still bound to this trusted binding may
# be re-read; a missing item must make the adapter stop recovery, never replay
# an older enabled snapshot from its journal.
sub _current_items {
    my ($self, $binding, $ids) = @_;
    die "Invalid current-item request\n" unless ref($ids) eq 'ARRAY' && @$ids <= 1000
        && !grep {ref($_) || "$_" !~ /\A[1-9]\d*\z/} @$ids;
    my (@items, %seen);
    for my $id (sort {$a <=> $b} grep {!$seen{$_}++} @$ids) {
        my $row = $self->dbh_auto_commit->selectrow_hashref(
            'SELECT * FROM user_services WHERE user_service_id=? FOR UPDATE', undef, $id);
        next unless $row;
        my $us = get_service('us', _id => $id);
        next unless $us;
        $row->{settings} = decode_json($row->{settings}) || {} unless ref($row->{settings}) eq 'HASH';
        $us->res($row);
        my $config = _config($us);
        my $stored_binding = _binding($config);
        next unless $stored_binding && _group($stored_binding) eq _group($binding);
        next if ($config->{status} // '') eq 'cleaned';
        if ($config->{enabled} && $row->{status} ne STATUS_REMOVED) {
            my $current = $self->target_for($us);
            next unless $current && _group($current) eq _group($binding);
        }
        push @items, {user_service_id => 0 + $id, user_id => 0 + $us->get_user_id,
            service_status => $row->{status}, expire => $us->get_expire,
            enabled => $config->{enabled} ? JSON::PP::true : JSON::PP::false,
            data => $config->{data} || {},
            secret => $config->{secret} && $config->{enabled} && $row->{status} eq STATUS_ACTIVE
                ? $self->_decrypt($us, $config->{secret}) : {},
            cleanup => $row->{status} eq STATUS_REMOVED ? JSON::PP::true : JSON::PP::false};
    }
    return \@items;
}

# Called while holding the shared synchronization lock. Populate snapshots as
# each current row is accepted, so an exception can still update those rows by CAS.
sub _collect_sync_items {
    my ($self, $binding, $ids, $snapshots, $services, $service_states) = @_;
    my @items;
    my %seen;
    for my $id (sort {$a <=> $b} grep {!$seen{$_}++} @$ids) {
        # A locking/current read is required even if the worker established
        # a REPEATABLE READ snapshot before waiting for the filesystem lock.
        my $row = $self->dbh_auto_commit->selectrow_hashref('SELECT * FROM user_services WHERE user_service_id=? FOR UPDATE', undef, $id);
        next unless $row;
        my $us = get_service('us', _id => $id);
        next unless $us;
        $row->{settings} = decode_json($row->{settings}) || {} unless ref($row->{settings}) eq 'HASH';
        $us->res($row);
        my $config = _config($us);
        next unless $config->{feature} && ($config->{status} // '') ne 'cleaned';
        my $stored_binding = _binding($config);
        next unless $stored_binding && _group($stored_binding) eq _group($binding);
        my $current = $config->{enabled} && $us->get_status ne STATUS_REMOVED
            ? $self->target_for($us) : undef;
        if ($config->{enabled} && $us->get_status ne STATUS_REMOVED
            && (!$current || _group($current) ne _group($stored_binding))) {
            my $updated = _copy($config);
            _set_status($updated, 'error', 'SERVICE_OPTIONS_TARGET_CHANGED');
            $self->_write($us, $updated, $config, $row->{status});
            next;
        }
        $snapshots->{$id} = $config; $services->{$id} = $us; $service_states->{$id} = $row->{status};
        push @items, {user_service_id => 0 + $id, user_id => 0 + $us->get_user_id,
            service_status => $us->get_status, expire => $us->get_expire,
            enabled => $config->{enabled} ? JSON::PP::true : JSON::PP::false,
            data => $config->{data} || {},
            secret => $config->{secret} && $config->{enabled} && $us->get_status eq STATUS_ACTIVE
                ? $self->_decrypt($us, $config->{secret}) : {},
            cleanup => $us->get_status eq STATUS_REMOVED ? JSON::PP::true : JSON::PP::false};
    }
    return \@items;
}

sub sync_task {
    my ($self, $task) = @_;
    return undef, {error => 'SERVICE_OPTIONS_ADMIN_REQUIRED'} unless _actor()->is_admin;
    my $settings = $task->settings;
    return undef, {error => 'SERVICE_OPTIONS_TASK_INVALID'} unless ref($settings) eq 'HASH';
    $settings = _copy($settings);
    my %allowed = map {$_ => 1} qw(feature target user_service_ids);
    return undef, {error => 'SERVICE_OPTIONS_TASK_INVALID'} if grep {!$allowed{$_}} keys %$settings;
    my $binding = {feature => $settings->{feature}, target => $settings->{target}};
    my $ids = ref($settings->{user_service_ids}) eq 'ARRAY' ? _copy($settings->{user_service_ids}) : undef;
    return undef, {error => 'SERVICE_OPTIONS_TASK_INVALID'} unless ref($ids) eq 'ARRAY'
        && @$ids && @$ids <= 100 && !grep {ref($_) || "$_" !~ /\A[1-9]\d*\z/} @$ids;
    return undef, {error => 'SERVICE_OPTIONS_TARGET_INVALID'} unless _valid_binding($binding);
    $binding = _copy($binding);
    my ($lock, @items, %snapshots, %services, %service_states);
    my $ok = eval {
        $lock = $self->_open_lock('sync-' . _group($binding));
        unless (flock($lock, LOCK_EX | LOCK_NB)) { die "SERVICE_OPTIONS_BUSY\n" }
        @items = @{$self->_collect_sync_items($binding, $ids,
            \%snapshots, \%services, \%service_states)};
        1;
    };
    unless ($ok) {
        my $error = $@;
        my $code = _sync_error($error, 'SERVICE_OPTIONS_SYNC_FAILED');
        for my $id (keys %snapshots) {
            my $updated = _copy($snapshots{$id});
            _set_status($updated, 'error', $code);
            $self->_write($services{$id}, $updated, $snapshots{$id}, $service_states{$id});
        }
        return FAIL, {error => $code};
    }
    return SKIP, {message => 'SERVICE_OPTIONS_NO_PENDING_ITEMS'} unless @items;
    my $original_answer = $task->{answer};
    my ($adapter_success, $receipt, %states, $executed, $adapter_error);
    my $prior_alarm = Time::HiRes::alarm(0);
    my $started = Time::HiRes::time();
    {
    local $SIG{ALRM} = sub {die "SERVICE_OPTIONS_TIMEOUT\n"};
    $executed = eval {
        Time::HiRes::alarm(90);
        my ($server, $adapter) = $self->_target($binding);
        require Core::ServiceOptions::State;
        my $value;
        ($adapter_success, $value) = $adapter->apply(
            payload => {feature => $binding->{feature}, items => \@items},
            settings => _copy($server->get_settings || {}), timeout => 90,
            state_factory => sub {
                my ($scope) = @_;
                die "Invalid service options state scope\n" unless defined($scope) && !ref($scope)
                    && length($scope) && length($scope) <= 4096 && $scope !~ /[\x00-\x1f]/;
                return $states{$scope} ||= Core::ServiceOptions::State->new(
                    controller => $self, scope => _json([$binding->{target}{adapter}, $scope]));
            },
            current_items => sub {$self->_current_items($binding, $_[0])},
        );
        die "Invalid adapter success value\n" unless defined($adapter_success)
            && !ref($adapter_success) && "$adapter_success" =~ /\A[01]\z/;
        $receipt = _results($value, [map {$_->{user_service_id}} @items]);
        for my $id (keys %$receipt) {
            next if $receipt->{$id}{state} eq 'error';
            my $expected = $service_states{$id} eq STATUS_REMOVED ? 'cleaned'
                : !$snapshots{$id}{enabled} ? 'disabled'
                : $service_states{$id} ne STATUS_ACTIVE ? 'waiting_service' : 'submitted';
            die "Invalid synchronization receipt\n" unless $receipt->{$id}{state} eq $expected
                || ($expected eq 'submitted' && $receipt->{$id}{state} eq 'waiting_service');
        }
        1;
    };
    $adapter_error = $@;
    Time::HiRes::alarm(0);
    }
    if ($prior_alarm) {
        my $remaining = $prior_alarm - (Time::HiRes::time() - $started);
        Time::HiRes::alarm($remaining > 0 ? $remaining : 0.001);
    }
    # The adapter receives no task object and plaintext never enters settings,
    # answers or history. Release every scope lock even if it throws midway.
    my $closed = 1;
    for my $state (values %states) { $closed = 0 unless eval {$state->close; 1} }
    %states = ();
    if (defined $original_answer) { $task->{answer} = $original_answer }
    else { delete $task->{answer} }
    @items = ();
    my $failure_code = _sync_error($adapter_error, 'SERVICE_OPTIONS_SYNC_FAILED');
    my $successful = $executed && $closed && $adapter_success;
    my %item_errors;
    for my $id (keys %snapshots) {
        my $us = $services{$id};
        my $snapshot = $snapshots{$id};
        my $result = $receipt ? $receipt->{$id} : undef;
        my $state = $successful && $result ? $result->{state} : 'error';
        # Only a successful, explicit removal confirmation permits erasure.
        $state = 'error' if $state eq 'cleaned' && $service_states{$id} ne STATUS_REMOVED;
        my $updated = _copy($snapshot);
        _set_status($updated, $state, $result && $result->{error} ? $result->{error} : $failure_code);
        $item_errors{$id} = $updated->{error} if $state eq 'error';
        if ($state eq 'cleaned') { $updated->{enabled} = 0; $updated->{data} = {}; delete $updated->{secret} }
        $self->_write($us, $updated, $snapshot, $service_states{$id});
    }
    if ($successful) {
        my $diagnostics = _task_diagnostics(\%item_errors, $failure_code, 1);
        return SUCCESS, {message => 'SERVICE_OPTIONS_SYNC_ACCEPTED',
            $diagnostics->{errors} ? (errors => $diagnostics->{errors}) : ()};
    }
    # A raw exception, invalid receipt or deadline must keep its controller
    # failure code. Provider codes are authoritative only for a completed,
    # validated structured return from the adapter.
    return FAIL, $executed && $closed && defined($adapter_success) && !$adapter_success
        ? _task_diagnostics(\%item_errors, $failure_code) : {error => $failure_code};
}

1;
