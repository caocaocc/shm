package Core::Consumption;

use v5.14;
use utf8;
use strict;
use warnings;
use parent 'Core::Base';
use Core::Base;
use Core::Utils qw(now decode_json encode_json);
use Core::Billing::Consumption qw(normalize_policy decimal decimal_sum decimal_difference money_to_minor epoch quote);

# A non-entity API controller: no structure/table, so ingress cannot accidentally
# use the generic Base add/set APIs to modify a frozen period or a reading.
sub _fail {
    my ($status, $message) = @_;
    die { consumption_error => 1, status => $status, message => $message };
}

sub atomic {
    my ($self, $code) = @_;
    state $sequence = 0;
    my $savepoint = 'consumption_' . ++$sequence;
    my $dbh = $self->dbh;
    my $local_config = get_service('config')->local;
    my $had_callbacks = exists $local_config->{_post_commit_callbacks};
    my @callbacks = @{ $local_config->{_post_commit_callbacks} || [] };
    local $dbh->{RaiseError} = 1;
    $dbh->do("SAVEPOINT $savepoint");
    my (@result, $result);
    my $wantarray = wantarray;
    my $ok = eval {
        $wantarray ? (@result = $code->()) : ($result = $code->());
        $dbh->do("RELEASE SAVEPOINT $savepoint");
        1;
    };
    unless ($ok) {
        my $error = $@;
        eval { $dbh->do("ROLLBACK TO SAVEPOINT $savepoint"); $dbh->do("RELEASE SAVEPOINT $savepoint") };
        if ($had_callbacks) {
            $local_config->{_post_commit_callbacks} = [@callbacks];
        } else {
            delete $local_config->{_post_commit_callbacks};
        }
        die $error;
    }
    return $wantarray ? @result : $result;
}

sub _api {
    my ($self, $code) = @_;
    my $result;
    my $ok = eval { $result = $self->atomic($code); 1 };
    return $result if $ok;
    my $error = $@;
    my $report = get_service('report');
    if (ref($error) eq 'HASH' && $error->{consumption_error}) {
        $report->status($error->{status});
        $report->add_error($error->{message});
    } else {
        logger->warning('Consumption operation failed', "$error");
        my $input_error = !ref($error) && "$error" =~ /\p{Han}/;
        $report->status($input_error ? 400 : 500);
        $report->add_error($input_error ? "$error" : '计量操作失败，请联系管理员');
    }
    return undef;
}

sub _actor { get_service('user')->authenticated }

sub lifecycle {
    my ($self, $us, $code) = @_;
    my $result = $self->_api(sub {
        my $result = $code->();
        my $report = get_service('report');
        unless ($report->is_success) {
            my ($message) = $report->errors;
            _fail($report->status || 400, $message);
        }
        return $result;
    });
    unless (get_service('report')->is_success) {
        # SAVEPOINT rolls back SQL, not the mutable ServiceManager object cache.
        $us->reload;
        $us->withdraw->reload if $us->withdraw;
        $us->user->reload;
    }
    return $result;
}

sub _user_service {
    my ($self, $id, $admin_only) = @_;
    _fail(400, '缺少有效的用户服务编号 user_service_id') unless defined($id) && "$id" =~ /\A[1-9]\d*\z/;
    my $actor = _actor();
    _fail(403, '无权执行此操作') if $admin_only && !$actor->is_admin;
    my $us = get_service('us', _id => $id);
    _fail(404, '用户服务不存在') unless $us;
    _fail(403, '无权执行此操作') unless $actor->is_admin || $us->get_user_id == $actor->id;
    return $us;
}

sub policy_for {
    my ($self, $us) = @_;
    return normalize_policy($us->service->config->{consumption});
}

sub period_for {
    my ($self, $us, $withdraw_id, $lock) = @_;
    $withdraw_id //= $us->get_withdraw_id;
    return undef unless $withdraw_id;
    return $self->dbh->selectrow_hashref(
        'SELECT * FROM consumption_periods WHERE user_service_id=? AND withdraw_id=?' . ($lock ? ' FOR UPDATE' : ''),
        undef, $us->id, $withdraw_id,
    );
}

sub freeze_period {
    my ($self, $us) = @_;
    my $wd = $us->withdraw or return undef;
    return undef unless $wd->paid && $wd->get_end_date;
    return $self->period_for($us) if $self->period_for($us);
    my $policy = $self->policy_for($us) or return undef;
    my $cash = $wd->get_total;
    my $bonus = $wd->get_bonus // 0;
    money_to_minor($cash); money_to_minor($bonus);
    my $start = epoch($wd->get_withdraw_date);
    my $end = epoch($wd->get_end_date) + 1;
    die "计费期间无效\n" unless $end > $start;
    my $currency = cfg('billing')->{currency} || 'CNY';
    die "计费币种必须为三位大写代码\n" unless $currency =~ /\A[A-Z]{3}\z/;
    $self->dbh->do(
        'INSERT INTO consumption_periods (withdraw_id,user_service_id,user_id,service_id,policy,currency,starts_at,ends_at,starts_epoch,ends_epoch,timezone,paid_cash,paid_bonus,refund_allowed) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        undef, $wd->id, $us->id, $us->get_user_id, $us->get_service_id,
        encode_json($policy), $currency, $wd->get_withdraw_date, $wd->get_end_date, $start, $end,
        $ENV{TZ} || 'SYSTEM', $cash, $bonus, $us->service->settings->{no_money_back} ? 0 : 1,
    );
    return $self->period_for($us);
}

sub _totals {
    my ($self, $period) = @_;
    my %totals;
    my $rows = $self->dbh->selectall_arrayref(
        'SELECT meter,baseline,cumulative FROM consumption_generations WHERE period_id=?',
        { Slice => {} }, $period->{id},
    );
    for my $row (@$rows) {
        $totals{$row->{meter}} = decimal_sum($totals{$row->{meter}} // '0',
            decimal_difference($row->{cumulative}, $row->{baseline}));
    }
    return \%totals;
}

sub _snapshot {
    my ($self, $period, $at_epoch) = @_;
    my $policy = decode_json($period->{policy});
    my $closed = defined $period->{closed_epoch};
    my $finalized = defined $period->{finalized_epoch};
    my $valuation_epoch = $closed ? $period->{closed_epoch}
        : $finalized ? $period->{finalized_epoch} : ($at_epoch // time);
    my $calc = quote(
        policy => $policy, cash => $period->{paid_cash}, bonus => $period->{paid_bonus},
        starts_epoch => $period->{starts_epoch}, ends_epoch => $period->{ends_epoch},
        at_epoch => $valuation_epoch,
        totals => $self->_totals($period),
    );
    my $active = $self->dbh->selectall_arrayref(
        'SELECT meter,generation,observed_epoch FROM consumption_generations WHERE period_id=? AND active=1',
        { Slice => {} }, $period->{id},
    );
    my %generations = map { $_->{meter} => $_->{generation} } @$active;
    my %observed = map { $_->{meter} => 0 + $_->{observed_epoch} } @$active;
    my $ready = !grep { !exists($observed{$_}) || $observed{$_} < $valuation_epoch } keys %{ $policy->{quotas} };
    return {
        %$calc, period_id => 0 + $period->{id}, withdraw_id => 0 + $period->{withdraw_id},
        user_service_id => 0 + $period->{user_service_id}, currency => $period->{currency},
        starts_at => $period->{starts_at}, ends_at => $period->{ends_at},
        starts_epoch => 0 + $period->{starts_epoch}, ends_epoch => 0 + $period->{ends_epoch},
        timezone => $period->{timezone}, quotas => $policy->{quotas}, generations => \%generations,
        meter_observed_epoch => \%observed,
        finalized => $finalized ? 1 : 0, finalized_at => $period->{finalized_at},
        refund_ready => (!$closed && $period->{refund_allowed} && (($finalized && $ready) || $calc->{consumed} eq Core::Billing::Consumption::minor_to_money(
            money_to_minor($period->{paid_cash}) + money_to_minor($period->{paid_bonus})))) ? 1 : 0,
        closed => $closed ? 1 : 0, refund_allowed => 0 + $period->{refund_allowed},
        paid_cash => $period->{paid_cash}, paid_bonus => $period->{paid_bonus},
        refunded_cash => $period->{refunded_cash}, refunded_bonus => $period->{refunded_bonus},
        $closed ? (
            retained_cash => Core::Billing::Consumption::minor_to_money(money_to_minor($period->{paid_cash}) - money_to_minor($period->{refunded_cash})),
            retained_bonus => Core::Billing::Consumption::minor_to_money(money_to_minor($period->{paid_bonus}) - money_to_minor($period->{refunded_bonus})),
        ) : (),
        ($closed || !$period->{refund_allowed}) ? (refundable_cash => '0.00', refundable_bonus => '0.00') : (),
    };
}

sub snapshot_for_api {
    my ($self, @args) = @_;
    my %args = get_smart_args(@args);
    return $self->_api(sub {
        my $us = $self->_user_service($args{user_service_id});
        my $period = $self->period_for($us, $args{withdraw_id}, 1);
        return { enabled => 0, user_service_id => 0 + $us->id } unless $period;
        return { enabled => 1, %{ $self->_snapshot($period) } };
    });
}

sub _ingress {
    my ($self, $kind, %args) = @_;
    my $us = $self->_user_service($args{user_service_id}, 1);
    _fail(400, '缺少有效的扣费编号 withdraw_id') unless defined($args{withdraw_id}) && "$args{withdraw_id}" =~ /\A[1-9]\d*\z/;
    my $period = $self->period_for($us, $args{withdraw_id}, 1);
    _fail(404, '计费期间不存在') unless $period;
    my $policy = decode_json($period->{policy});
    my $meter = $args{meter} // '';
    _fail(400, '计量项目不存在') unless exists $policy->{quotas}{$meter};
    for my $field (qw(generation record_id)) {
        _fail(400, "字段 $field 无效") unless defined($args{$field}) && !ref($args{$field})
            && length($args{$field}) >= 1 && length($args{$field}) <= 128 && $args{$field} !~ /[\x00-\x1f]/;
    }
    my $value = decimal($args{ $kind eq 'BASELINE' ? 'baseline' : 'cumulative' });
    my $old = $self->dbh->selectrow_hashref(
        'SELECT * FROM consumption_readings WHERE period_id=? AND meter=? AND record_id=?',
        undef, $period->{id}, $meter, $args{record_id},
    );
    if ($old) {
        _fail(409, '相同计量记录编号的内容不一致') unless $old->{kind} eq $kind
            && $old->{generation} eq $args{generation} && decimal($old->{cumulative}) eq $value
            && ($old->{source_observed_at} // '') eq ($args{observed_at} // '');
        return { duplicate => 1, %{ $self->_snapshot($period) } };
    }
    _fail(409, '计费期间已关闭，不能继续上报') if defined $period->{closed_epoch};
    _fail(409, '计费期间已确认最终读数，不能继续上报') if defined $period->{finalized_epoch};
    my $observed = defined($args{observed_at}) ? epoch($args{observed_at}) : time;
    _fail(400, '观测时间超出计费期间或晚于当前时间') if $observed < $period->{starts_epoch}
        || $observed > $period->{ends_epoch} || $observed > time;
    my $generation = $self->dbh->selectrow_hashref(
        'SELECT * FROM consumption_generations WHERE period_id=? AND meter=? AND generation=?',
        undef, $period->{id}, $meter, $args{generation},
    );
    if ($kind eq 'BASELINE') {
        _fail(409, '计数世代已存在') if $generation;
        my $active = $self->dbh->selectrow_hashref(
            'SELECT * FROM consumption_generations WHERE period_id=? AND meter=? AND active=1',
            undef, $period->{id}, $meter,
        );
        _fail(409, '观测时间早于当前计数世代') if $active && $observed < $active->{observed_epoch};
        $self->dbh->do('UPDATE consumption_generations SET active=0 WHERE period_id=? AND meter=?', undef, $period->{id}, $meter);
        $self->dbh->do('INSERT INTO consumption_generations (period_id,meter,generation,baseline,cumulative,observed_epoch) VALUES (?,?,?,?,?,?)',
            undef, $period->{id}, $meter, $args{generation}, $value, $value, $observed);
    } else {
        _fail(409, '请先提交明确基线并创建计数世代') unless $generation;
        _fail(409, '计数世代已结束') unless $generation->{active};
        _fail(409, '观测时间早于上一条读数') if $observed < $generation->{observed_epoch};
        my $valid = eval { decimal_difference($value, $generation->{cumulative}); 1 };
        _fail(409, '同一计数世代的累计用量不能倒退') unless $valid;
        $self->dbh->do('UPDATE consumption_generations SET cumulative=?,observed_epoch=? WHERE id=?',
            undef, $value, $observed, $generation->{id});
    }
    $self->dbh->do('INSERT INTO consumption_readings (period_id,meter,generation,record_id,kind,cumulative,source_observed_at,observed_epoch) VALUES (?,?,?,?,?,?,?,?)',
        undef, $period->{id}, $meter, $args{generation}, $args{record_id}, $kind, $value, $args{observed_at}, $observed);
    my $snapshot = $self->_snapshot($period);
    $self->_notify_exhausted($us, $period, $snapshot);
    return { duplicate => 0, %$snapshot };
}

sub admin_start_generation {
    my ($self, @args) = @_;
    my %args = get_smart_args(@args);
    return $self->_api(sub { $self->_ingress('BASELINE', %args) });
}

sub admin_ingest {
    my ($self, @args) = @_;
    my %args = get_smart_args(@args);
    return $self->_api(sub { $self->_ingress('READING', %args) });
}

sub admin_finalize {
    my ($self, @args) = @_;
    my %args = get_smart_args(@args);
    return $self->_api(sub {
        my $us = $self->_user_service($args{user_service_id}, 1);
        _fail(400, '缺少有效的扣费编号 withdraw_id') unless defined($args{withdraw_id}) && "$args{withdraw_id}" =~ /\A[1-9]\d*\z/;
        my $period = $self->period_for($us, $args{withdraw_id}, 1);
        _fail(404, '计费期间不存在') unless $period;
        my $cutoff = epoch($args{cutoff});
        if (defined $period->{finalized_epoch}) {
            _fail(409, '计费期间已使用不同截止时间确认最终读数') if $period->{finalized_epoch} != $cutoff;
            return { duplicate => 1, %{ $self->_snapshot($period) } };
        }
        _fail(409, '计费期间已关闭') if defined $period->{closed_epoch};
        _fail(400, '最终截止时间超出计费期间或晚于当前时间')
            if $cutoff < $period->{starts_epoch} || $cutoff > $period->{ends_epoch} || $cutoff > time;
        my $observed = $self->dbh->selectall_arrayref(
            'SELECT meter,observed_epoch FROM consumption_generations WHERE period_id=? AND active=1',
            { Slice => {} }, $period->{id});
        my %covered = map { $_->{meter} => $_->{observed_epoch} } @$observed;
        my $policy = decode_json($period->{policy});
        _fail(409, '每个计量项目的最终读数必须覆盖截止时间')
            if grep { !exists($covered{$_}) || $covered{$_} < $cutoff } keys %{ $policy->{quotas} };
        $self->dbh->do('UPDATE consumption_periods SET finalized_at=?,finalized_epoch=? WHERE id=?',
            undef, $args{cutoff}, $cutoff, $period->{id});
        $period->{finalized_at} = $args{cutoff};
        $period->{finalized_epoch} = $cutoff;
        return { duplicate => 0, %{ $self->_snapshot($period) } };
    });
}

sub _notify_exhausted {
    my ($self, $us, $period, $snapshot) = @_;
    return unless $snapshot->{exhausted} && !$period->{exhausted_notified};
    for my $event ($us->commands_by_event('CONSUMPTION_EXHAUSTED')) {
        $us->spool->add(
            user_id => $us->get_user_id, user_service_id => $us->id, event => $event, prio => $event->{settings}{prio} // 10,
            settings => { user_service_id => $us->id, withdraw_id => $period->{withdraw_id}, consumption_period_id => $period->{id}, consumption => $snapshot },
        );
    }
    $self->dbh->do('UPDATE consumption_periods SET exhausted_notified=1 WHERE id=?', undef, $period->{id});
    # No SHM BLOCK transition: billing time/renewal and quota exhaustion differ.
}

sub refund {
    my ($self, $us, $date, %options) = @_;
    my $withdraw_id = $us->get_withdraw_id;
    return $self->atomic(sub {
        # Match the normal API lock order: service -> wallet -> period.
        $self->dbh->selectrow_array('SELECT user_service_id FROM user_services WHERE user_service_id=? FOR UPDATE', undef, $us->id);
        $us->reload;
        _fail(409, '服务已切换计费期间，请重新读取快照') if ($us->get_withdraw_id // 0) != $withdraw_id;
        $self->dbh->selectrow_array('SELECT user_id FROM users WHERE user_id=? FOR UPDATE', undef, $us->get_user_id);
        $us->user->reload;
        my $period = $self->period_for($us, $withdraw_id, 1) or return undef;
        return (0, 0) if defined $period->{closed_epoch};
        my $currency_config = get_service('config', _id => 'billing');
        $currency_config->reload;
        my $currency = $currency_config->get_data->{currency} || 'CNY';
        _fail(409, '当前账本币种与已支付期间不同，请先完成币种迁移') if $currency ne $period->{currency};
        my $at = defined($period->{finalized_epoch}) ? $period->{finalized_epoch} : epoch($date);
        $date = $period->{finalized_at} if defined $period->{finalized_epoch};
        _fail(400, '退款截止时间早于已支付期间') if $at < $period->{starts_epoch};
        my $calc = $self->_snapshot($period, $at);
        my ($cash, $bonus) = @{$calc}{qw(refundable_cash refundable_bonus)};
        if (!$period->{refund_allowed} || $options{waive_refund}) {
            ($cash, $bonus) = ('0.00', '0.00');
            @{$calc}{qw(retained_cash retained_bonus)} = @{$period}{qw(paid_cash paid_bonus)};
        }
        _fail(409, '退款前需停用外部资源、上报最终读数并确认固定截止时间')
            if (money_to_minor($cash) || money_to_minor($bonus)) && !$calc->{refund_ready};
        my $wd = $us->withdraw;
        _fail(409, '已冻结的支付金额被修改，不能自动退款')
            unless money_to_minor($wd->get_total) == money_to_minor($period->{paid_cash})
                && money_to_minor($wd->get_bonus // 0) == money_to_minor($period->{paid_bonus});
        my $end_date = $at >= $period->{ends_epoch} ? $period->{ends_at} : $date;
        $wd->set(total => $calc->{retained_cash}, bonus => $calc->{retained_bonus}, end_date => $end_date);
        $us->user->set_balance(balance => $cash, bonus => $bonus);
        $us->user->bonus->add(bonus => $bonus, comment => { withdraw_id => $wd->id, consumption_period_id => $period->{id} })
            if money_to_minor($bonus);
        $self->dbh->do('UPDATE consumption_periods SET closed_at=?,closed_epoch=?,refunded_cash=?,refunded_bonus=? WHERE id=?',
            undef, $date, $at, $cash, $bonus, $period->{id});
        $us->set(expire => $end_date) if defined $period->{finalized_epoch};
        return ($cash, $bonus);
    });
}

1;
