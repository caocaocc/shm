package Core::Routing::Publish;
use v5.14;
use strict;
use warnings;
use Core::Const;
use Core::Routing::Store ();
use Digest::SHA qw(sha256_hex);
use HTTP::Request ();
use LWP::UserAgent ();
use List::Util qw(min max);
use Time::HiRes ();

my @snippets = ('Out Users', 'Routing Users');
my %tag = ('Out Users' => 'tag', 'Routing Users' => 'ruleTag');
# LWP's inactivity timeout alone does not limit a slow streaming response or DNS lookup.
# Keep the enclosing Spool alarm when temporarily installing a shorter operation deadline.
sub within_deadline {
    my ($deadline, $operation) = @_;
    my $started = Time::HiRes::time();
    my $available = $deadline - $started;
    die "REMOTE_HTTP\n" if $available <= 0;
    my $outer = Time::HiRes::alarm(0);
    my $limit = min(15, $available, ($outer > 0 ? $outer : ()));
    my ($result, $error);
    {
        local $SIG{ALRM} = sub { die "REMOTE_HTTP\n" };
        Time::HiRes::alarm($limit);
        $result = eval { $operation->() };
        $error = $@;
        Time::HiRes::alarm(0);
    }
    my $elapsed = Time::HiRes::time() - $started;
    Time::HiRes::alarm(max(0.01, $outer - $elapsed)) if $outer > 0;
    die "REMOTE_HTTP\n" if $elapsed >= $limit;
    die $error if length $error;
    return $result;
}

sub request {
    my ($client, $panel, $method, $path, $body) = @_;
    my $req = HTTP::Request->new($method, $panel->{url} . $path);
    $req->header(Authorization => 'Bearer ' . $panel->{token}, Accept => 'application/json');
    if (defined $body) {
        $req->header('Content-Type' => 'application/json');
        $req->content($Core::Routing::Store::JSON->encode($body));
    }
    my $result = within_deadline($client->{deadline}, sub { $client->{http}->request($req) });
    return if $result->code == 404 && $path =~ m{^/api/users/};
    die "REMOTE_HTTP\n" unless $result->is_success && !$result->header('Client-Aborted');
    if ($method eq 'POST') {
        die "REMOTE_RESPONSE\n" unless $result->code == 202;
        return 1;
    }
    return 1 if $method ne 'GET';
    my $parsed = eval { Core::Routing::Store::decode($result->content) };
    die "REMOTE_RESPONSE\n" unless ref($parsed) eq 'HASH' && ref($parsed->{response}) eq 'HASH';
    return $parsed->{response};
}

sub load_snippets {
    my ($client, $panel) = @_;
    my $list = request($client, $panel, 'GET', '/api/snippets')->{snippets};
    die "SNIPPETS_NOT_READY\n" unless ref($list) eq 'ARRAY';
    my %result;
    for my $item (@$list) {
        next unless ref($item) eq 'HASH' && exists $tag{$item->{name} // ''};
        die "SNIPPETS_NOT_READY\n" if exists $result{$item->{name}} || ref($item->{snippet}) ne 'ARRAY'
            || !@{$item->{snippet}} || grep {ref($_) ne 'HASH'} @{$item->{snippet}};
        $result{$item->{name}} = $item->{snippet};
    }
    die "SNIPPETS_NOT_READY\n" unless keys(%result) == 2;
    return \%result;
}

sub scope_tag {
    my ($site, $id, $suffix) = @_;
    return $site . $id . '_' . $suffix;
}
# Preserve the order and complete contents of entries owned by the platform and other services.
sub merge {
    my ($original, $selected, $site) = @_;
    my %merged;
    for my $name (@snippets) {
        my %wanted;
        for my $entry (@$selected) {
            my $id = $entry->{id};
            my @owned = $name eq 'Out Users' ? ('out') : ('domain', 'ip');
            $wanted{scope_tag($site, $id, $_)} = undef for @owned;
            $wanted{$_->{$tag{$name}}} = $_ for @{$entry->{entries}{$name} || []};
        }
        my (@rows, %seen);
        for my $row (@{$original->{$name}}) {
            my $label = $row->{$tag{$name}} // '';
            if (exists $wanted{$label}) {
                die "SNIPPETS_NOT_READY\n" if $seen{$label}++;
                push @rows, $wanted{$label} if defined $wanted{$label};
            } else {
                push @rows, $row;
            }
        }
        push @rows, @wanted{grep {defined($wanted{$_}) && !$seen{$_}} sort keys %wanted};
        die "SNIPPETS_NOT_READY\n" unless grep {index(($_->{$tag{$name}} // ''), $site) != 0} @rows;
        die "SNIPPETS_NOT_READY\n" if $name eq 'Out Users' && index(($rows[0]{tag} // ''), $site) == 0;
        $merged{$name} = \@rows;
    }
    my %out = map {($_->{tag} // '') => 1} @{$merged{'Out Users'}};
    for my $rule (@{$merged{'Routing Users'}}) {
        my $target = $rule->{outboundTag} // '';
        die "SNIPPETS_NOT_READY\n" if index($target, $site) == 0 && !$out{$target};
    }
    return \%merged;
}

sub equal { $Core::Routing::Store::JSON->encode($_[0]) eq $Core::Routing::Store::JSON->encode($_[1]) }

sub code {
    my ($error) = @_;
    return $1 if $error =~ /\A(REMOTE_HTTP|REMOTE_RESPONSE|REMOTE_USER_PENDING|SNIPPETS_NOT_READY|TARGET_CHANGED|TARGET_UNAVAILABLE|KEY_UNAVAILABLE|INVALID_OUTBOUND|ENDPOINT_DENIED|ENDPOINT_UNRESOLVED|STORAGE_FAILED)\s*\z/;
    return 'SYNC_FAILED';
}

sub load_member {
    my ($live, $client, $scope, $site, $entry) = @_;
    my ($id, $owner) = @$entry{qw(id owner)};
    my ($record, $box) = Core::Routing::Store::record($live, $owner, $id);
    unless ($record) {
        $entry->{complete} = 1;
        return;
    }
    @$entry{qw(record box)} = ($record, $box);
    return if sha256_hex($record->{panel}) ne $scope;
    my $svc = Core::Routing::Store::service($live, $id);
    return if $svc && $svc->{user_id} != $owner;
    my $status = $svc ? $svc->{status} : 'REMOVED';
    my $target = $svc ? ($svc->{server_id} // '') : '';
    $entry->{service} = $svc;
    if ($record->{enabled} && $status =~ /^(?:INIT|PROGRESS|ERROR)$/) {
        $entry->{status} = 'waiting';
        $entry->{complete} = 1 if $status eq 'INIT';
        return;
    }
    my $panel = Core::Routing::Store::panel($live, $record->{target});
    die "TARGET_UNAVAILABLE\n" unless $panel;
    die "TARGET_CHANGED\n" unless $panel->{url} eq $record->{panel};
    $entry->{panel} = $panel;
    $entry->{entries} = {};
    if ($status eq 'REMOVED') {
        $entry->{remove} = 1;
        $entry->{status} = 'disabled';
        return;
    }
    if ($status eq 'ACTIVE' && $target ne $record->{target}) {
        $entry->{status} = 'error';
        $entry->{error} = 'TARGET_CHANGED';
        return;
    }
    unless ($status eq 'ACTIVE' && $record->{enabled}) {
        $entry->{status} = $record->{enabled} ? 'waiting' : 'disabled';
        $entry->{settled} = 1;
        return;
    }
    my $user = request($client, $panel, 'GET', "/api/users/by-username/us_$id");
    unless ($user) {
        $entry->{status} = 'waiting';
        $entry->{error} = 'REMOTE_USER_PENDING';
        return;
    }
    die "REMOTE_RESPONSE\n" unless ($user->{username} // '') eq "us_$id" && ($user->{id} // '') =~ /\A[1-9][0-9]*\z/;
    require Core::Routing::Input;
    my $out = within_deadline($client->{deadline}, sub {
        return Core::Routing::Input::pin($record->{outbound}, $panel->{url});
    });
    my $out_tag = scope_tag($site, $id, 'out');
    $entry->{entries}{'Out Users'} = [{%$out, tag => $out_tag}];
    my @rules;
    for my $kind (qw(domain ip)) {
        my $values = $record->{$kind eq 'domain' ? 'domains' : 'ips'};
        next unless @$values;
        push @rules, {
            type        => 'field',
            user        => ["$user->{id}"],
            outboundTag => $out_tag,
            ruleTag     => scope_tag($site, $id, $kind),
            $kind       => [sort @$values],
        };
    }
    $entry->{entries}{'Routing Users'} = \@rules;
    $entry->{status} = 'submitted';
}

sub still_current {
    my ($live, $entry) = @_;
    my $now = Core::Routing::Store::service($live, $entry->{id});
    return unless equal($now, $entry->{service});
    my ($latest) = $live->selectrow_array('SELECT data FROM storage WHERE user_id=0 AND name=?', undef, 'routing:' . $entry->{id});
    return defined $latest && $latest eq $entry->{box};
}

sub mark {
    my ($db, $scope, $sync) = @_;
    my $value = $sync ? q{JSON_SET(CONVERT(data USING utf8mb4),'$.uncertain',1,'$.last_sync',UNIX_TIMESTAMP())}
        : q{JSON_SET(CONVERT(data USING utf8mb4),'$.uncertain',1)};
    my $rows = $db->do("UPDATE storage SET data=$value WHERE user_id=0 AND name=?", undef, Core::Routing::Store::control_name($scope));
    die "STORAGE_FAILED\n" unless $rows;
}

sub publish {
    my ($live, $scope, $state, $entries) = @_;
    my $site = Core::Routing::Store::tag_prefix($live);
    my $budget = max(1, min(150, ($ENV{TASK_TIMEOUT} || 300) * 0.8));
    my $start = Time::HiRes::time();
    my $client = {
        deadline => $start + $budget,
        http => LWP::UserAgent->new(
            timeout => 15,
            max_size => 8 * 1024 * 1024,
            max_redirect => 0,
            protocols_allowed => [qw(https http)],
        ),
    };
    # Leave part of the batch for PATCH, read-back and sync. Resume at the next
    # service on the following job so one slow member cannot starve its peers.
    my $last;
    for my $entry (@$entries) {
        if (defined $last && Time::HiRes::time() >= $start + $budget * 0.6) {
            $state->{resume_after} = $last;
            last;
        }
        $last = $entry->{id};
        my $prepared = eval {
            load_member($live, $client, $scope, $site, $entry);
            1;
        };
        next if $prepared;
        my $fault = code($@);
        delete $entry->{entries};
        $entry->{error} = $fault;
        $entry->{status} = 'error';
        $entry->{complete} = 1 if $fault eq 'ENDPOINT_DENIED' || $fault eq 'INVALID_OUTBOUND';
    }
    my @eligible = grep {defined $_->{entries}} @$entries;
    return 0 unless @eligible;
    my $panel = $eligible[0]{panel};
    my $remote = load_snippets($client, $panel);
    my @apply;
    for my $entry (@eligible) {
        if (still_current($live, $entry)) { push @apply, $entry }
        else { delete @$entry{qw(status error entries)} }
    }
    return 0 unless @apply;
    my $updated = merge($remote, \@apply, $site);
    my @different = grep {!equal($remote->{$_}, $updated->{$_})} @snippets;
    my $missing_receipt = grep {
        !defined($_->{record}{published}) || ($_->{remove} && $_->{record}{published})
    } @apply;
    if (@different || $state->{uncertain} || $missing_receipt) {
        # Persist a recovery marker before the first remote write. A crash or a
        # failed second PATCH will reconcile both lists before attempting sync.
        mark($live, $scope, 0);
        for my $name (@different) {
            request($client, $panel, 'PATCH', '/api/snippets', {name => $name, snippet => $updated->{$name}});
        }
        my $stored = load_snippets($client, $panel);
        my $check = merge($stored, \@apply, $site);
        die "REMOTE_RESPONSE\n" if grep {!equal($stored->{$_}, $check->{$_})} @snippets;
        # Record the attempt before the request: even a lost response counts
        # towards the shared panel's cooldown.
        mark($live, $scope, 1);
        request($client, $panel, 'POST', '/api/snippets/actions/sync', {});
    }
    for my $entry (@apply) {
        $entry->{published} = $entry->{status} eq 'submitted' ? 1 : 0;
        $entry->{complete} = 1 if $entry->{settled} || $entry->{status} ne 'waiting';
    }
    return 1;
}

sub finish {
    my ($self, $scope, $job, $entries, $confirmed, $interval, $resume_after) = @_;
    my $db = $self->dbh;
    # Every user edit takes the service record before the panel receipt. Use that same order.
    my %complete;
    for my $entry (sort { $a->{id} <=> $b->{id} } @$entries) {
        my $id = $entry->{id};
        if ($entry->{box} && $entry->{status}) {
            my ($record, $box) = Core::Routing::Store::record($db, $entry->{owner}, $id, 1);
            # Save completion only if concurrent edits left this exact ciphertext intact.
            next unless defined $box && $box eq $entry->{box};
            if ($entry->{remove} && $entry->{complete}) {
                $db->do('DELETE FROM storage WHERE user_id=0 AND name=?', undef, "routing:$id") or die "STORAGE_FAILED\n";
            } else {
                $record->{status} = $entry->{status};
                if (defined $entry->{error}) {
                    $record->{error} = $entry->{error};
                } else {
                    delete $record->{error};
                }
                $record->{published} = $entry->{published} if defined $entry->{published};
                Core::Routing::Store::write_record($db, $entry->{owner}, $id, $record);
            }
        }
        $complete{$id} = $entry->{version} if $entry->{complete};
    }
    my $current = Core::Routing::Store::control($db, $scope, 1);
    return unless $current && ($current->{job} // 0) == $job;
    delete $current->{uncertain} if $confirmed;
    if (defined $resume_after) {
        $current->{cursor} = $resume_after;
    } else {
        delete $current->{cursor};
    }
    for my $id (keys %complete) {
        my $p = $current->{pending}{$id};
        delete $current->{pending}{$id} if $p && $p->[1] == $complete{$id};
    }
    if (keys %{$current->{pending}}) {
        my $wait = grep { $_->{error} || ($_->{status} // '') eq 'waiting' } @$entries;
        my $now = time;
        $current->{due} = max($now + ($wait ? min_retry($interval) : 1), ($current->{last_sync} // 0) + $interval);
        $current->{job} = $self->enqueue('publish_task', {routing_panel => $scope}, $current->{due} - $now);
    } else {
        delete @$current{qw(job due cursor)};
    }
    Core::Routing::Store::update_control($db, $current);
}

sub min_retry { $_[0] < 30 ? max(1, $_[0]) : 30 }

sub run {
    my ($self, $task) = @_;
    my $scope = $task->settings->{routing_panel};
    my $db = $self->dbh;
    my $live = $self->dbh_auto_commit;
    my $lock = 'routing-' . substr($scope, 0, 48);
    my ($acquired) = $live->selectrow_array('SELECT GET_LOCK(?,0)', undef, $lock);
    return FAIL, {error => 'PANEL_BUSY'} unless $acquired;
    my $ok = eval {
        $db->do('SAVEPOINT publish_routes') or die "STORAGE_FAILED\n";
        my $state = Core::Routing::Store::control($live, $scope);
        if ($state && ($state->{job} // 0) == $task->id) {
            my (undef, $interval) = Core::Routing::timing();
            my $due = max($state->{due} // 0, ($state->{last_sync} // 0) + $interval);
            if ($due > time) {
                my $latest = Core::Routing::Store::control($db, $scope, 1);
                $latest->{job} = $self->enqueue('publish_task', {routing_panel => $scope}, $due - time);
                $latest->{due} = $due;
                Core::Routing::Store::update_control($db, $latest);
            } else {
                my @ids = sort { $a <=> $b } keys %{$state->{pending}};
                my $cursor = $state->{cursor} || 0;
                my @order = ((grep { $_ > $cursor } @ids), (grep { $_ <= $cursor } @ids));
                my @entries;
                for my $id (@order) {
                    my ($owner, $version) = @{$state->{pending}{$id}};
                    push @entries, { id => $id, owner => $owner, version => $version };
                }
                my $confirmed = eval { publish($live, $scope, $state, \@entries) };
                if ($@) {
                    my $error = code($@);
                    for my $entry (@entries) {
                        next unless defined $entry->{entries};
                        $entry->{error} = $error;
                        $entry->{status} = 'error';
                        delete @$entry{qw(complete published)};
                    }
                }
                finish($self, $scope, $task->id, \@entries, $confirmed, $interval, $state->{resume_after});
            }
        }
        1;
    };
    my $error = $@;
    $db->do('ROLLBACK TO SAVEPOINT publish_routes') unless $ok;
    $live->selectrow_array('SELECT RELEASE_LOCK(?)', undef, $lock);
    return $ok ? (SUCCESS, {}) : (FAIL, {error => code($error)});
}
1;
