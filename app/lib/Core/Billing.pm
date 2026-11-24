package Core::Billing;

use v5.14;

use base qw(
    Core::Pay
    Core::User
);

use base qw(Exporter);

our @EXPORT = qw(
    create_service
    process_service_recursive
    money_back
    calc_withdraw
    switch_to_next_service
);

use Core::Const;
use Core::Utils qw(now string_to_utime utime_to_string start_of_month end_of_month parse_date days_in_months round);
use Time::Local 'timelocal_nocheck';

use base qw( Core::System::Service );
use Core::System::ServiceManager qw( get_service logger );

use Core::Billing::Traffic qw(quota reading period_usage used_bytes);
use POSIX qw(strftime);
use Core::Billing::Honest;
use Core::Billing::Simpler;

# Keep the account, service and withdrawal under the same SHM transaction.
our $in_metered_write;
sub metered_write {
    my ($us, $action) = @_;
    return $action->() if $in_metered_write;
    local $in_metered_write = 1;
    my $dbh = $us->dbh;
    local $dbh->{RaiseError} = 1;
    my $bill = $us->get_withdraw_id || 0;
    my $callbacks = get_service('config')->local->{_post_commit_callbacks} ||= [];
    my $count = @$callbacks;
    $dbh->do('SAVEPOINT measured_term');
    my ($result, @locked);
    my $ok = eval {
        $us->user->reload(extra => 'FOR UPDATE');
        my @pending = ($us);
        while (@pending) {
            my $item = shift @pending;
            my $record = $item->id($item->id);
            my $fresh = $record->reload(extra => 'FOR UPDATE') or die 'service missing';
            $item->res($fresh);
            my $withdraw = $item->withdraw;
            if ($withdraw) {
                $withdraw->reload(extra => 'FOR UPDATE') or die 'withdraw missing';
            }
            push @locked, [$item, $record, $withdraw];
            push @pending, @{$item->children};
        }
        die "service changed" if ($us->get_withdraw_id || 0) != $bill;
        $result = $action->();
        1;
    };
    if (!$ok || !defined $result) {
        $dbh->do('ROLLBACK TO SAVEPOINT measured_term');
        splice @$callbacks, $count;
        $us->user->reload(extra => 'FOR UPDATE');
        for my $entry (@locked) {
            my ($item, $record, $withdraw) = @$entry;
            $item->res(scalar $record->reload(extra => 'FOR UPDATE'));
            $withdraw->reload(extra => 'FOR UPDATE') if $withdraw;
        }
    }
    $dbh->do('RELEASE SAVEPOINT measured_term');
    die "计量账务更新失败，请刷新后重试。\n" unless $ok;
    return $result;
}

# Quote each due item in the same order as process_service_recursive. A mixed
# package needs enough real cash for all charges after each plan's bonus cap.
sub composite_cash_required {
    my ($root, $tariff, $price, $bonus) = @_;
    my $cash = 0;
    my $measured = 0;
    my @work = ([$root, $tariff, $price]);
    while (my $entry = shift @work) {
        my ($item, $plan, $amount) = @$entry;
        unless (defined $amount) {
            $plan = $item->service;
            $amount = 0;
            if (my $bill = $item->withdraw) {
                if ($bill->unpaid) {
                    $amount = $bill->get_total;
                } else {
                    next unless $item->has_expired && !$plan->no_auto_renew && $item->get_next >= 0;
                    my %invoice;
                    if ($item->get_next) {
                        $plan = get_service('service', _id => $item->get_next) or next;
                        %invoice = calc_withdraw($item->billing, $plan->get);
                    } else {
                        %invoice = $bill->next;
                        %invoice = calc_withdraw($item->billing, $bill->get, months => $plan->get_period, bonus => 0)
                            unless %invoice;
                    }
                    $amount = $invoice{total};
                }
            }
        }
        $measured ||= quota($plan) ? 1 : 0;
        my $part = calc_available_bonuses($plan, $bonus, $amount);
        $part = $amount if $part > $amount;
        $bonus = round($bonus - $part);
        $cash = round($cash + $amount - $part);
        unshift @work, map { [$_] } @{$item->children};
    }
    return $measured ? $cash : undef;
}

sub awaiting_payment {
    my $self = shift;

    return 1 if (   $self->get_status eq STATUS_BLOCK ||
                    $self->get_status eq STATUS_WAIT_FOR_PAY );
    return 0;
}

sub create_service {
    my %args = (
        service_id => undef,
        @_,
    );

    my $us = create_service_recursive( %args ) || return undef;

    return $us->get_auto_bill ? process_service_recursive( $us, EVENT_CREATE ) : $us;
}

sub create_service_recursive {
    my %args = (
        service_id => undef,
        @_,
    );

    unless ( $args{ service_id } ) {
        logger->fatal( "Not exists service_id in args" );
    }

    my $service = get_service('service', _id => $args{service_id} );
    unless ( $service ) {
        logger->error( "Service not exists: $args{service_id}" );
        return undef;
    }

    if ( $service->get_period ) {
        $args{months} ||= $service->get_period;
    }

    $args{next} = $service->get_next;

    my $us = get_service('us')->add( %args );

    if ( $service->get_pay_always || !$args{parent} ) {
        my %srv = $service->get;
        my $wd_id = add_withdraw(
            $us,
            calc_withdraw( $us->billing, %srv, %args ),
        );
        unless ( $wd_id ) {
            logger->error( "Failed to add withdraw for user service: " . $us->id );
            return undef;
        }
        $us->set( withdraw_id => $wd_id );
    }

    my $ss = $service->subservices;
    for ( @{ $ss } ) {
        create_service_recursive( %{ $_ }, parent => $us->id );
    }

    return $us;
}

sub process_service_recursive {
    my $service = shift;
    my $event = shift || EVENT_PROLONGATE;
    my %args = @_;

    return undef unless ref $service;
    unless ($in_metered_write) {
        my $plan = $service->service;
        my $next_plan = $service->get_next > 0 ? get_service('service', _id => $service->get_next) : undef;
        if (quota($plan) || $plan->get_is_composite || ($next_plan && quota($next_plan))
            || ($service->withdraw && $service->withdraw->get_usage)) {
            return metered_write($service, sub { process_service_recursive($service, $event, %args) });
        }
    }

    if ( $event = process_service( $service, $event, %args ) ) {
        logger->info('Process service: '. $service->id . ", Result: [$event]" );
        for my $child ( @{$service->children} ) {
            process_service_recursive(
                $service->id( $child->id ),
                $event,
                %args,
            );
        }
        $service->event( $event );
    }
    return $service;
}

# Просмотр/обработка услуг:
# Обработка новой услуги
# Выход из ф-ии если услуга не истекла
# Уже заблокированная услуга проверяется на предмет поступления средств и делается попытка продлить услугу
# Для истекшей, но активной услуги, создается акт
# Попытка продить услугу
# ф-я возвращает event (на вход пришел prolongate, а на выходе может быть block, если не хватило денег)
sub process_service {
    my $self = shift;
    my $event = shift;
    my %args = @_;

    logger->info('Process service: '. $self->id . ", Event: [$event]" );

    if ( $self->get_status eq STATUS_PROGRESS ) {
        logger->info('Service in progress. Skipping...');
        return undef;
    }

    if ( $self->get_status eq STATUS_REMOVED ) {
        logger->warning('Service is removed. Skipping...');
        return undef;
    }

    unless ( $self->get_withdraw_id ) {
        # Бесплатная услуга
        return $event;
    }

    if ( $event eq EVENT_BLOCK_FORCE ) {
        return block( $self );
    } elsif ( $event eq EVENT_ACTIVATE_FORCE ) {
        return activate( $self );
    } elsif ( $event eq EVENT_REMOVE ) {
        return remove( $self );
    }

    unless ( $self->get_expire ) {
        # Новая услуга
        logger->info('New service');
        return create( $self );
    }

    unless ( $self->has_expired ) {
        # Услуга не истекла
        # Ничего не делаем с этой услугой
        logger->info('Service is not expired. Skipping...');
        return undef;
    }

    return prolongate( $self, %args );
}

sub add_withdraw {
    my $us = shift;
    my %wd = @_;

    delete @wd{ qw/ withdraw_id create_date end_date withdraw_date user_service_id usage / };
    return $us->srv('wd', usi => $us->id )->add( %wd );
}

# Создание следущего платежа на основе текущего
sub add_withdraw_next {
    my $self = shift;

    my $wd = $self->withdraw->get;

    my %wd = calc_withdraw(
        $self->billing,
        %{ $wd },
        months => $self->service->get_period,
        bonus => 0,
    );

    # Если денег не хватает и установлен флаг продления на всю сумму, то вычисляем wd здесь
    if ( $self->service->settings->{allow_partial_period} ) {
        apply_partial_period( $self, \%wd, $self->service->get_period );
    }

    return add_withdraw( $self, %wd );
}

# Вычисляет итоговую стоимость услуги
# на вход принимает все аргументы списания
sub calc_withdraw {
    my $billing = shift;
    my %wd = (
        cost => undef,
        months => undef,
        discount => 0,
        qnt => 1,
        @_,
    );

    $wd{qnt} = 1 if $wd{qnt} < 1;

    my %service = get_service( 'service', _id => $wd{service_id} )->get;
    $wd{months} ||= $wd{period};
    %wd = ( %service, %wd );

    $wd{withdraw_date}||= now;
    $wd{end_date} = calc_end_date_by_months( $billing, $wd{withdraw_date}, $wd{months} );

    if ( $wd{months} == $wd{period} ) {
        $wd{total} = $wd{cost};
    } else {
        $wd{total} = calc_total_by_date_range( $billing, %wd )->{total};
    }

    $wd{discount}||= get_service_discount( %wd );
    $wd{discount} = 0 if $service{no_discount};

    $wd{total} = round( ( $wd{total} - $wd{total} * $wd{discount} / 100 ) * $wd{qnt} );

    $wd{total} -= $wd{bonus};

    return %wd;
}

# принимает сумму в качестве аргумента
# вычисляет доступные бонусы
# проверяет возможность оплаты списания (баланс, бонусы, скидки и т.п.)
# возвращает структуру в случае успеха: деньги и бонусы, 0 - в случае нехватки средств
sub calc_payment {
    my $self  = shift;
    my $total = shift;
    # тариф, по которому платим: при переходе на следующий тариф он ещё не записан в услугу
    my $service = shift || $self->service;

    my $user  = $self->user;
    my $bonus = calc_available_bonuses( $service, $user->get_bonus, $total );

    return if quota($service) && $total > $bonus && $user->get_balance + $bonus < $total;

    my $check_total = $total;
    my $root = $self->top_parent;
    if ( $root->service->get_is_composite ) {
        if ( $self->id == $root->id ) {
            # I'm a root
            my $cash = composite_cash_required($self, $service, $total, $user->get_bonus);
            if (defined $cash) {
                return 0 if $cash > 0 && $cash > $user->get_balance;
            } else {
                $check_total = $self->wd_total_composite;
            }
        } else {
            # I'm a child
            return 0 unless $root->is_paid;
        }
    }

    # Not enough money
    return 0 if (
                    $check_total > 0 &&
                    $user->get_balance + $user->get_credit + $bonus < $check_total &&
                    !$user->get_can_overdraft &&
                    # флаг «списывать даже в минус» хранится у тарифа (services), а не у услуги пользователя
                    !$service->get_pay_in_credit );

    if ( $bonus >= $total ) {
        $bonus = $total;
        $total = 0;
    } else {
        $total -= $bonus;
    }

    return {
        bonus => $bonus,
        total => $total,
    };
}

# метод пробует оплатить списание
# списывает деньги и бонусы с баланса и возвращает статус
sub is_pay {
    my $self = shift;

    return undef unless $self->get_withdraw_id;
    unless ( $self->withdraw ) {
        logger->warning(
            sprintf( "Withdraw not exists: %d", $self->get_withdraw_id ),
        );
        return undef;
    }

    my $sample = shift;
    my $limit = quota($self->service);
    return metered_write($self, sub { is_pay($self, $sample) }) if $limit && !$in_metered_write;
    my $wd = $self->withdraw;
    return 1 if $wd->get_withdraw_date;
    my $pay = calc_payment( $self, $wd->get_total ) or return 0;
    my ( $bonus, $total ) = @{$pay}{qw( bonus total )};

    $self->user->set_bonus( bonus => -$bonus, comment => { withdraw_id => $wd->id } );
    $self->user->set_balance( balance => -$total );

    $wd->set(
        bonus         => $bonus,
        total         => $total,
        withdraw_date => now,
        ($limit ? (usage => period_usage($limit, $sample ? $$sample : reading($self))) : ()),
    );

    $wd->reload if $limit;
    return 1;
}

sub set_service_expire {
    my $self = shift;

    my $wd = $self->withdraw->get;
    my $now = now;

    if ( $self->has_expired && $self->get_status ne STATUS_BLOCK ) {
        # Услуга истекла (не новая) и не заблокирована ранее
        # Будем продлять с момента истечения
        $now = $self->get_expire;
    }

    my $expire_date = calc_end_date_by_months( $self->billing, $now, $wd->{months} );

    #if ( $config->{child_expire_by_parent} {
    #if ( my $parent_expire_date = parent_has_expired( $self ) ) {
    #     if ( $expire_date gt $parent_expire_date ) {
    #        # дата истечения услуги не должна быть больше чем дата истечения родителя
    #        $expire_date = $parent_expire_date;
    #        # TODO: cacl and set real months
    #    }
    #}}

    $self->withdraw->set( end_date => $expire_date );

    return $self->set( expire => $expire_date );
}

sub create {
    my $self = shift;
    my %args = (
        children_free => 0,
        @_,
    );

    unless ( is_pay( $self ) ) {
        logger->debug('Not enough money');
        return EVENT_NOT_ENOUGH_MONEY;
    }

    set_service_expire( $self ) unless $args{children_free};

    return EVENT_CREATE;
}

sub prolongate {
    my $self = shift;
    my %args = (
        force => 0,
        allow_partial_period => 0,
        @_,
    );

    logger->info('Trying to prolong the service: ' . $self->id );

    unless (    $self->get_status eq STATUS_ACTIVE ||
                $self->get_status eq STATUS_WAIT_FOR_PAY ||
                $self->get_status eq STATUS_BLOCK
    ) {
        logger->warning( sprintf "Can't prolongate service %d with status: %s . Skipped", $self->id, $self->get_status );
        return undef;
    }

    my $wd = $self->withdraw;
    my $usage = $wd && $wd->get_usage;
    my $boundary;
    if ($usage && !exists $usage->{used_bytes} && $self->has_expired) {
        return metered_write($self, sub { prolongate($self, %args) }) unless $in_metered_write;
        my $sample = reading($self);
        $boundary = \$sample;
        $wd->set(usage => {%$usage, used_bytes => scalar bill_usage($wd, $usage, $sample)});
    }
    if ( $self->service->no_auto_renew && !$args{force} ) {
        logger->debug( sprintf "Block service because of `no_auto_renew` is set for usi %d", $self->id );
        return block( $self );
    }

    unless ( $self->has_expired ) {
        logger->info("Service has not expired. Skipped");
        return undef;
    }

    if ( $self->parent_has_expired ) {
        # Не продлеваем услугу если родитель истек
        logger->info('Parent has expired. Skipped');
        return block( $self );
    }

    if ( $self->withdraw->paid && $self->get_next == -1 ) {
        return remove( $self );
    } elsif ( $self->withdraw->paid && $self->get_next ) {
        unless (switch_to_next_service( $self, %args )) {
            logger->error( "Failed to switch to next service for user service: " . $self->id );
            return undef;
        }
    } elsif ( $self->withdraw->paid ) {
        # Для существующей услуги используем текущее/следующее/новое списание
        my $wd = $self->withdraw;
        if ( $wd && $wd->get_withdraw_date ) {
            my $wd_id;
            if ( my %next = $self->withdraw->next ) {
                $wd_id = $next{withdraw_id};
            } else {
                $wd_id = add_withdraw_next( $self );
                unless ( $wd_id ) {
                    logger->error( "Failed to add withdraw for user service: " . $self->id );
                    return undef;
                }
            }
            $self->set( withdraw_id => $wd_id );
        }
    }

    unless ( is_pay( $self, $boundary ) ) {
        logger->info('Not enough money');
        return $self->get_status eq STATUS_BLOCK ? undef : block( $self );
    }

    set_service_expire( $self );

    return EVENT_ACTIVATE if $self->get_status eq STATUS_WAIT_FOR_PAY || $self->get_status eq STATUS_BLOCK;
    return EVENT_PROLONGATE if $self->get_status eq STATUS_ACTIVE;
    return undef;
}

sub switch_to_next_service {
        my $us = shift;
        my %args = (
            allow_partial_period => 0,
            @_,
        );

        my $new_service_id = $us->get_next;
        unless ( $new_service_id ) {
            logger->warning( "Next service not exists for user service: " . $us->id );
            return;
        }

        my $service = get_service('service', _id => $new_service_id );
        unless ( $service ) {
            logger->warning( "Service not exists: $new_service_id" );
            return;
        }

        my %wd = calc_withdraw( $us->billing, $service->get );
        delete @wd{ qw/ create_date end_date withdraw_date user_service_id / };

        if ( $args{allow_partial_period} || $service->settings->{allow_partial_period} ) {
            apply_partial_period( $us, \%wd, $service->get_period, $service );
        }

        my $wd_id;
        my $wd = $us->withdraw;
        if ( $wd->unpaid ) {
            $wd->set( %wd );
        } else {
            $wd_id = add_withdraw(
                $us,
                %wd,
            );
            unless ($wd_id) {
                logger->error( "Failed to add withdraw for user service: " . $us->id );
                return;
            }
        }

        $us->set(
            service_id => $service->id,
            next => $service->get_next,
            $wd_id ? ( withdraw_id => $wd_id ) : (),
        );
        $us->make_commands_by_event( EVENT_CHANGED_TARIFF );
        return 1;
}

sub block {
    my $self = shift;
    return 0 if $self->get_status ne STATUS_ACTIVE;

    return EVENT_BLOCK;
}

sub activate {
    my $self = shift;
    return 0 unless $self->get_status eq STATUS_BLOCK;

    return EVENT_ACTIVATE;
}

sub remove {
    my $self = shift;
    return 0 if $self->get_status eq STATUS_REMOVED;

    money_back( $self );

    return EVENT_REMOVE;
}

# Анализируем услугу и решаем какую скидку давать (доменам не давать)
sub get_service_discount {
    my %args = (
        months => undef,
        service_id => undef,
        @_,
    );

    my $service = $args{service_id} ? get_service( 'service', _id => $args{service_id} )->get : {};

    $args{period} ||= $service->{period} // undef;
    $args{months} ||= $service->{period} || 1;

    my $percent = get_service('user')->get_discount || 0;

    if ( $args{period} < 2 ) {
        # Вычисляем скидку за кол-во месяцев
        my $discount_info = get_service('discounts')->get_by_period( months => $args{months} );
        if ( $discount_info ) {
            $percent += $discount_info->{percent};
        }
    }

    $percent = 100 if $percent > 100;
    return $percent;
}

sub bill_usage {
    my ($wd, $usage, $sample) = @_;
    my $opening = strftime('%Y-%m-%dT%H:%M:%S.000Z', gmtime(string_to_utime($wd->get_withdraw_date)));
    return scalar used_bytes($usage, $sample, $opening);
}

# Mark a measured bill closed once, before replacing its service or expiry.
sub close_meter {
    my ($us, $date, $refund) = @_;
    my $wd = $us->withdraw or return 1;
    my $usage = $wd->get_usage or return 1;
    return 1 if exists $usage->{used_bytes};
    my ($cash, $bonus) = ($wd->get_total, $wd->get_bonus);
    my $paid = round($cash + $bonus);
    my $options = $us->service->settings;
    my $early = $refund && $wd->get_end_date && $date lt $wd->get_end_date;
    my $used = $early && !$paid ? undef : bill_usage($wd, $usage, scalar reading($us));
    if ($early && $paid > 0 && !$options->{allow_return_full_wd} && !$options->{no_money_back} && !defined $used) {
        get_service('report')->status(503);
        get_service('report')->add_error('流量读数暂不可用，请重试。');
        return;
    }
    $wd->set(usage => {%$usage, used_bytes => $used});
    return 1 unless $early;
    my %range = (withdraw_date => $wd->get_withdraw_date, end_date => $wd->get_end_date,
                 cost => 1_000_000, period => $wd->get_months, discount => 0, qnt => 1);
    my $elapsed = calc_total_by_date_range($us->billing, %range, end_date => $date);
    my $full = calc_total_by_date_range($us->billing, %range);
    my $ratio = $full->{total} ? $elapsed->{total} / $full->{total} : 0;
    my $traffic = ($used || 0) / $usage->{limit_bytes};
    $ratio = $traffic if $traffic > $ratio;
    $ratio = 0 if $ratio < 0 || $options->{allow_return_full_wd};
    $ratio = 1 if $ratio > 1 || $options->{no_money_back};
    # Allocate the rounded charge between the two original payment sources.
    my $consumed = round($paid * $ratio);
    my $kept = $paid > 0 ? round($consumed * $cash / $paid) : 0;
    my $points = round($consumed - $kept);
    $wd->set(total => $kept, bonus => $points, months => $elapsed->{months}, end_date => $date);
    my $credit = round($bonus - $points);
    $us->user->set_balance(balance => round($cash - $kept), bonus => $credit);
    $us->user->bonus->add(bonus => $credit, comment => {withdraw_id => $wd->id}) if $credit;
    return 1;
}

sub money_back {
    my $self = shift;
    my $date = shift || $self->get_expire;
    if ($self->withdraw && $self->withdraw->get_usage) {
        return metered_write($self, sub { close_meter($self, $date, 1) });
    }

    return undef unless $self->get_withdraw_id;

    my $service = get_service('service', _id => $self->get_service_id );
    return undef unless $service;
    return undef if $service->settings->{no_money_back};

    my $wd = $self->withdraw;
    return undef unless $wd;

    my %wd = $wd->get;
    return undef unless $wd{end_date};
    return undef if $wd{end_date} le $date;
    return undef if $wd{create_date} gt $date;

    # Return full refund on removal if flag is set
    if ( $service->settings->{allow_return_full_wd} ) {
        $self->user->set_balance(
            balance => $wd{total},
            bonus   => $wd{bonus},
        );
        $self->user->bonus->add( bonus => $wd{bonus}, comment => { withdraw_id => $wd->id } ) if $wd{bonus};
        return ($wd{total}, $wd{bonus});
    }

    my $calc = calc_total_by_date_range(
        $self->billing,
        %{ $service->get },
        %wd,
        end_date => $date,
    );

    my ($delta_money, $delta_bonus) = (0, 0);

    if ($calc->{total} > $wd{total}) {
        my $paid_money = $wd{total};
        my $paid_bonus = $wd{bonus};

        $delta_money = $wd{total};
        $wd{total} = 0;

        if ( $paid_money <= 0 ) {
            # If payment was only with bonuses, keep only the used part in bonus
            # and return the rest to the user.
            my $used_bonus = $calc->{total} > $paid_bonus ? $paid_bonus : $calc->{total};
            $wd{bonus} = $used_bonus;
            $delta_bonus = $paid_bonus - $used_bonus;
        } else {
            # Бонусы в приоритете: сохраняем столько бонусов, чтобы покрыть стоимость использованного периода, остаток — деньгами.
            # delta_bonus = излишек бонусов сверх стоимости использованного периода.
            my $bonus_to_keep = $paid_bonus < $calc->{total} ? $paid_bonus : $calc->{total};
            my $cash_to_keep  = $calc->{total} - $bonus_to_keep;

            $delta_money      = $paid_money - $cash_to_keep;
            $delta_bonus      = $paid_bonus - $bonus_to_keep;

            $wd{total} = $cash_to_keep;
            $wd{bonus} = $bonus_to_keep;
        }
    } else {
        $delta_money = $wd{total} - $calc->{total};
        $wd{total} = $calc->{total};
        $delta_bonus = $wd{bonus};
        $wd{bonus} = 0;
    }

    $wd{months}   = $calc->{months};
    $wd{end_date} = $date;

    $wd->set(
        months   => $wd{months},
        end_date => $wd{end_date},
        total    => $wd{total},
        bonus    => $wd{bonus},
    );

    $self->user->set_balance(
        balance => $delta_money,
        bonus   => $delta_bonus,
    );

    $self->user->bonus->add( bonus => $delta_bonus, comment => { withdraw_id => $wd->id } ) if $delta_bonus;

    return $delta_money, $delta_bonus;
}

sub calc_end_date_by_months {
    my $billing = shift || 'Simpler';

    no strict 'refs';
    return &{"Core::Billing::${billing}::calc_end_date_by_months"}( @_ );
}

sub calc_total_by_date_range {
    my $billing = shift || 'Simpler';

    no strict 'refs';
    return &{"Core::Billing::${billing}::calc_total_by_date_range"}( @_ );
}

sub calc_period_by_total {
    my $billing = shift || 'Simpler';

    no strict 'refs';
    return &{"Core::Billing::${billing}::calc_period_by_total"}( @_ );
}

sub apply_partial_period {
    my $us     = shift;
    my $wd_ref = shift;
    my $period = shift;
    my $service = shift || $us->service;

    return if quota($service);
    my $pay = calc_payment( $us, $wd_ref->{total}, $service );
    return if $pay;

    my $user  = $us->user;
    # деньги = баланс + кредит, как в calc_payment.
    # Баланс может быть отрицательным: долг уменьшает доступную сумму
    my $money = $user->get_balance + ( $user->get_credit || 0 );
    my $bonus = $user->get_bonus;
    $bonus = 0 if $bonus < 0;

    # Сколько можно оплатить: лимит бонусов (limit_bonus_percent) считается от суммы списания,
    # а не от баланса. С лимитом p% сумма T такая, что бонусы = p% от T, а деньги покрывают остальное
    my $total = $money + $bonus;
    my $limit = $service->config->{limit_bonus_percent};
    if ( length $limit && int($limit) < 100 ) {
        my $percent = int($limit) > 0 ? int($limit) : 0;
        my $by_limit = $money * 100 / ( 100 - $percent );
        $total = $by_limit if $by_limit < $total;
    }
    # вниз до копеек, чтобы деньгами не пришлось доплачивать больше баланса и кредита
    $total = int( $total * 100 + 1e-6 ) / 100;

    # платить нечем (или долг больше кредита и бонусов)
    return if $total <= 0;

    my $months = calc_period_by_total(
        $us->billing,
        total  => $total,
        cost   => $wd_ref->{cost},
        period => $period,
    );

    # Денег и бонусов нет, неполный период разрешён.
    # calc_period_by_total у Honest в этом случае возвращает '0.00'
    # Старая проверка ne '0.0000' принимала это за ненулевой период.
    # В итоге создавалось списание на 0 ₽ и 0 месяцев, оплата нуля проходила, услуга становилась активной со сроком «сейчас».
    if ( $months > 0 ) {
        $wd_ref->{total}  = $total;
        $wd_ref->{months} = $months;
    }
}


# Calculates the bonus amount available for payment, subject to limit_bonus_percent.
#
# | limit_bonus_percent | total  | Result                       |
# |---------------------|--------|------------------------------|
# | not set             | any    | $bonus (full bonuses)        |
# | 100                 | any    | $bonus (full bonuses)        |
# | < 100               | <= 0   | 0  (no base for percentage)  |
# | < 100               | > 0    | $total * percent / 100       |
sub calc_available_bonuses {
    my $service = shift;
    my $bonus = shift;
    my $total = shift;

    return 0 unless ref $service;
    return 0 if $bonus <= 0;

    my $limit_bonus_percent = $service->config->{limit_bonus_percent};

    # Without a limit (or with a full 100% limit), bonuses are available regardless of total.
    return $bonus unless length $limit_bonus_percent;
    return $bonus if int($limit_bonus_percent) >= 100;

    # With a partial limit, bonuses are capped as a percentage of total.
    # A zero or negative total means nothing to cover, so no bonuses apply.
    return 0 if $total <= 0;

    my $max_bonus_amount = $total * int($limit_bonus_percent) / 100;
    $bonus = $max_bonus_amount if $bonus > $max_bonus_amount;

    return round( $bonus );
}

1;
