package Core::Routing;
use v5.14;
use utf8;
use strict;
use warnings;
use parent 'Core::Base';
use Core::Base;
use Core::Const;
use Core::Routing::Store ();
use Digest::SHA qw(sha256_hex);
use List::Util qw(max);
use JSON::PP ();

# Shared by the customer catalogue and the configure endpoint.
use constant SCOPE_SQL => q{EXISTS (SELECT 1 FROM servers routing_server
    WHERE routing_server.server_id = user_services.settings->>'$.server_id'
    AND JSON_TYPE(routing_server.settings->'$.remnawave.api')='STRING'
    AND LENGTH(routing_server.settings->>'$.remnawave.api')>0
    AND JSON_TYPE(routing_server.settings->'$.remnawave.token')='STRING'
    AND LENGTH(routing_server.settings->>'$.remnawave.token')>0)};
sub found_rows { 1 }

sub timing {
    my $config = get_service('config')->data_by_name('routing') || {};
    my @seconds = ($config->{batch_window_seconds} // 3, $config->{min_publish_interval_seconds} // 3600);
    for (@seconds) {
        die "ROUTING_SETTINGS_INVALID\n" if ref($_) || !/\A[0-9]{1,10}\z/ || $_ > 2147483647;
    }
    die "ROUTING_SETTINGS_INVALID\n" unless $seconds[1] > 0;
    return @seconds;
}

sub enqueue {
    my ($self, $method, $settings, $delay) = @_;
    my $id = get_service('spool', user_id => 1)->add(user_id => 1, status => TASK_NEW, prio => 100,
        delayed => max(0, $delay || 0), event => {kind => 'Routing', method => $method, name => 'SYSTEM', title => '同步分流配置'},
        settings => $settings);
    return $id || die "QUEUE_FAILED\n";
}

sub schedule {
    my ($self, $url, $owner, $id) = @_;
    my $db = $self->dbh;
    my $scope = sha256_hex($url);
    my $name = Core::Routing::Store::control_name($scope);
    my $new = {scope => $scope, pending => {}};
    $db->do(q{INSERT INTO storage (user_id,name,data) VALUES(0,?,?) ON DUPLICATE KEY UPDATE name=VALUES(name)},
        undef, $name, $Core::Routing::Store::JSON->encode($new)) or die "STORAGE_FAILED\n";
    my $control = Core::Routing::Store::control($db, $scope, 1);
    my ($window, $interval) = timing();
    my $time = time;
    my $previous = $control->{pending}{$id};
    $control->{pending}{$id} = [0 + $owner, 1 + ($previous ? $previous->[1] : 0)];
    my $exists = $control->{job} && $db->selectrow_array('SELECT id FROM spool WHERE id=?', undef, $control->{job});
    my $due = max($time + $window, ($control->{last_sync} // 0) + $interval);
    if (!$exists) {
        $control->{due} = $due;
        $control->{job} = $self->enqueue('publish_task', {routing_panel => $scope}, $due - $time);
    } elsif ($due < $control->{due}) {
        # A shorter site interval can advance an idle task. Do not wait for an
        # executing worker while holding its receipt and the caller's service row.
        my ($idle) = $db->selectrow_array(
            'SELECT id FROM spool WHERE id=? FOR UPDATE SKIP LOCKED', undef, $control->{job}
        );
        die "STORAGE_FAILED\n" if $db->err;
        if ($idle) {
            $db->do('UPDATE spool SET executed=NOW(), `delayed`=? WHERE id=?', undef, $due - $time, $idle)
                or die "QUEUE_FAILED\n";
            my $spool = get_service('spool', user_id => 1);
            $spool->add_post_commit_callback(sub { $spool->wake_workers });
        }
        $control->{due} = $due;
    }
    Core::Routing::Store::update_control($db, $control);
}

sub service_in_scope {
    my ($self, $db, $id) = @_;
    return scalar $db->selectrow_array('SELECT ' . SCOPE_SQL . ' FROM user_services WHERE user_service_id=?', undef, $id);
}

sub configure {
    my ($self, %arg) = @_;
    my $actor = get_service('user');
    my $method = $arg{action} || 'read';
    my $response = eval {
        my $db = $actor->dbh;
        my ($owner, $id) = ($actor->id, $arg{user_service_id});
        my $svc = Core::Routing::Store::service($db, $id, $method ne 'read');
        die "SERVICE_UNAVAILABLE\n" unless $svc && $svc->{user_id} == $owner && $svc->{status} ne 'REMOVED';
        my $panel = $svc->{status} eq 'ACTIVE' ? Core::Routing::Store::panel($db, $svc->{server_id}) : undef;
        die "SERVICE_UNAVAILABLE\n" unless $panel || $method eq 'disable';
        my ($record) = Core::Routing::Store::record($db, $owner, $id, $method ne 'read');
        if ($method eq 'disable') {
            die "SERVICE_UNAVAILABLE\n" unless $record;
            if ($record->{enabled} || $record->{status} ne 'disabled') {
                $record->{enabled} = 0;
                $record->{status} = 'queued';
                delete $record->{error};
                Core::Routing::Store::write_record($db, $owner, $id, $record);
                $self->schedule($record->{panel}, $owner, $id);
            }
        } elsif ($method eq 'save' || $method eq 'enable') {
            my ($text, $rules) = @arg{qw(outbound_text rules)};
            if ($method eq 'enable') {
                die "INVALID_OUTBOUND\n" unless $record;
                ($text, $rules) = @$record{qw(outbound_text rules)};
            }
            die "INVALID_OUTBOUND\n" unless defined $text && !ref($text) && length($text) <= 65536 && index($text, "\0") < 0;
            die "INVALID_RULES\n" unless ref($rules) eq 'ARRAY' && !grep { !defined($_) || ref($_) || /[\r\n\0]/ } @$rules;
            if ($record && ($svc->{server_id} != $record->{target} || $panel->{url} ne $record->{panel})) {
                die "TARGET_CHANGED\n" unless $method eq 'save' && defined($record->{published}) && !$record->{published} &&
                    ($record->{status} eq 'disabled' || ($record->{error} // '') eq 'TARGET_CHANGED');
            }
            require Core::Routing::Input;
            my $compiled = Core::Routing::Input::compile($text, $rules, $panel->{url});
            $record = {published => 0} unless $record;
            my $match = $record->{enabled} && ($record->{status} // '') eq 'submitted' && $record->{target} == $svc->{server_id}
                && $record->{panel} eq $panel->{url} && $record->{outbound_text} eq $text &&
                $Core::Routing::Store::JSON->encode($record->{rules}) eq $Core::Routing::Store::JSON->encode($rules);
            $record = {
                %$record,
                %$compiled,
                enabled       => 1,
                outbound_text => $text,
                target        => 0 + $svc->{server_id},
                panel         => $panel->{url},
            };
            delete $record->{error};
            $record->{status} = 'queued' unless $match;
            Core::Routing::Store::write_record($db, $owner, $id, $record);
            $self->schedule($record->{panel}, $owner, $id) unless $match;
        } elsif ($method ne 'read') {
            die "INVALID_OUTBOUND\n";
        }
        my $view = {status => 'unconfigured', rules => [], outbound_text => '', enabled => JSON::PP::false};
        if ($record) {
            $view->{status} = $record->{status};
            $view->{enabled} = $record->{enabled} ? JSON::PP::true : JSON::PP::false;
            $view->{error} = $record->{error} if $record->{error};
            @$view{qw(outbound_text rules)} = @$record{qw(outbound_text rules)} if $panel;
            my $control = Core::Routing::Store::control($db, sha256_hex($record->{panel}));
            $view->{publish_at} = 0 + $control->{due} if $control && $control->{pending}{$id};
        }
        if ($method ne 'read') {
            $actor->commit or die "QUEUE_FAILED\n";
        }
        $view;
    };
    return $response if $response;
    my ($reason) = $@ =~ /\A(INVALID_(?:OUTBOUND|RULES)|ENDPOINT_DENIED|SERVICE_UNAVAILABLE|TARGET_CHANGED|TARGET_UNAVAILABLE|KEY_UNAVAILABLE|QUEUE_FAILED|STORAGE_FAILED|ROUTING_SETTINGS_INVALID)\s*\z/;
    $reason ||= 'SYNC_FAILED';
    $actor->rollback if $method ne 'read';
    my %http = (SERVICE_UNAVAILABLE => 404, TARGET_CHANGED => 409, INVALID_OUTBOUND => 400, INVALID_RULES => 400, ENDPOINT_DENIED => 400);
    my $status = $http{$reason} || 503;
    $self->report->status($status);
    $self->report->add_error($reason);
    return;
}

sub queue_change {
    my ($self, $owner, $id) = @_;
    my $db = $self->dbh;
    my $services = $db->selectall_arrayref(q{SELECT user_services.user_service_id, private.name
        FROM user_services LEFT JOIN storage private ON private.user_id=0 AND private.name=CONCAT('routing:',user_services.user_service_id)
        WHERE user_services.user_id=?} . (defined $id ? ' AND user_services.user_service_id=?' : '') . ' FOR UPDATE', undef, $owner, defined $id ? ($id) : ());
    die "STORAGE_FAILED\n" unless defined $services;
    for my $svc (@$services) {
        next unless defined $svc->[1];
        $self->enqueue('lifecycle_task', {routing_user_id => 0 + $owner, routing_service_id => 0 + $svc->[0]}, 0);
    }
}

sub lifecycle_task {
    my ($self, $task) = @_;
    my ($owner, $id) = @{$task->settings}{qw(routing_user_id routing_service_id)};
    return FAIL, {error => 'SERVICE_UNAVAILABLE'} unless $task->user_id == 1 && $owner && $id;
    my $db = $self->dbh;
    $db->do('SAVEPOINT routing_check') or return FAIL, {error => 'STORAGE_FAILED'};
    my $ok = eval {
        my ($record) = Core::Routing::Store::record($db, $owner, $id);
        $self->schedule($record->{panel}, $owner, $id) if $record;
        1;
    };
    return SUCCESS, {} if $ok;
    $db->do('ROLLBACK TO SAVEPOINT routing_check');
    return FAIL, {error => 'QUEUE_FAILED'};
}

sub publish_task {
    my ($self, $task) = @_;
    return FAIL, {error => 'SERVICE_UNAVAILABLE'} unless $task->user_id == 1 && ($task->settings->{routing_panel} // '') =~ /\A[a-f0-9]{64}\z/;
    require Core::Routing::Publish;
    return Core::Routing::Publish::run($self, $task);
}
1;
