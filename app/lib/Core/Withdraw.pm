package Core::Withdraw;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Const;

sub table { return 'withdraw_history' };

sub structure {
    return {
        withdraw_id => {
            type => 'number',
            key => 1,
            title => '扣费 ID',
        },
        user_id => {
            type => 'number',
            auto_fill => 1,
            title => '用户 ID',
        },
        create_date => {
            type => 'now',
            title => '扣费创建时间',
            readOnly => 1,
        },
        withdraw_date => {
            type => 'date',
            title => '扣费时间',
            readOnly => 1,
        },
        end_date => {
            type => 'date',
            title => '结束时间',
            readOnly => 1,
        },
        cost => {
            type => 'number',
            required => 1,
            title => '价格',
            use_for_stats => 1,
        },
        discount => {
            type => 'number',
            default => 0,
            title => '折扣',
        },
        bonus => {
            type => 'number',
            default => 0,
            title => '奖励数量',
            use_for_stats => 1,
        },
        months => {
            type => 'number',
            default => 1,
            title => '周期',
        },
        total => {
            type => 'number',
            title => '总金额',
            use_for_stats => 1,
        },
        service_id => {
            type => 'number',
            required => 1,
            title => '服务 ID',
        },
        qnt => {
            type => 'number',
            default => 1,
            title => '数量',
        },
        user_service_id => {
            type => 'number',
            required => 1,
            title => '用户服务 ID',
        },
    }
}

sub stats {
    my ($self, $action, $args) = @_;
    return if $action ne 'set';
    return $self->SUPER::stats( $action, $args ) if $args->{withdraw_date};
}

sub usi {
    my $self = shift;
    return $self->{usi} || $self->get_user_service_id;
}

# Получаем предоплаченные списания (будущие периоды)
sub next {
    my $self = shift;

    my @list;

    if ( my $usi = $self->usi ) {
        @list = $self->list(
            where => {
                user_service_id => $usi,
                withdraw_id => { '>' => $self->id },
            },
            order => [ 'withdraw_id' => 'asc' ],
        );
    }

    if ( wantarray ) {
        return %{ $list[0] || {} }; # Возвращаем следующий объект в виде хеша
    }

    return \@list; # Возвращаем все следующие объекты
}

sub add {
    my $self = shift;
    my %args = (
        user_service_id => $self->usi,
        @_,
    );

    unless ( $args{user_service_id} ) {
        get_service('report')->add_error( "Can't create withdraw without user_service_id" );
        return undef;
    }

    delete $args{ $self->get_table_key };

    my $service = $self->srv('service', _id => $args{service_id} );
    unless ( $service ) {
        get_service('report')->add_error( "Can't create for not existed service" );
        return undef;
    }

    # Заполняем структуру из данных услуги, если параметр не передан явно
    my $srv = $service->get;
    for ( keys %{ $srv } ) {
        $args{ $_ }//= $srv->{ $_ };
    }

    return $self->SUPER::add( %args );
}

sub list {
    my $self = shift;
    my %args = @_;

    if ( $self->usi ) {
        $args{where}->{user_service_id} = $self->usi;
    }

    return $self->SUPER::list( order => [ $self->get_table_key => 'asc' ], %args );
}

sub list_for_api {
    my $self = shift;
    my @arr = $self->SUPER::list_for_api( field => 'withdraw_date', @_ );
    $self->found_rows( $self->SUPER::found_rows() );

    for ( @arr ) {
        if ( my $service = get_service('service', _id => $_->{service_id} ) ) {
            $_->{name} = $service->get_name;
        } else {
            $_->{name} = '';
        }
    }
    return @arr;
}

sub last {
    my $self = shift;

    my $pay = first_item $self->rsort('withdraw_date')->items(
        limit => 1,
    );

    return $pay;
}

sub found_rows {
    my $self = shift;
    my $count = shift;

    if ( defined $count ) {
        $self->{found_rows} = $count;
    }

    return $self->{found_rows};
}

sub paid {
    my $self = shift;
    return $self->get_withdraw_date ? 1 : 0;
}
sub unpaid { $_[0]->paid ? 0 : 1 };

*delete = \&delete_unpaid;

sub delete_unpaid {
    my $self = shift;
    my $usi = shift || $self->usi;

    return undef unless $usi;

    return $self->SUPER::_delete(
        where => {
            user_id => $self->user_id,
            user_service_id => $usi,
            withdraw_date => undef,
        },
    );
}

sub api_set {
    my $self = shift;
    my %args = (
        @_,
    );

    my $us = $self->srv('us', _id => $args{user_service_id} );
    unless ( $us ) {
        get_service('report')->add_error( "User service not exists" );
        return \%args;
    }

    my $service = $self->srv('service', _id => $args{service_id} );
    unless ( $service ) {
        get_service('report')->add_error( "Service not exists" );
        return \%args;
    }

    if ( $us->get_withdraw_id != $self->id && $us->get_expire ) {
        get_service('report')->add_error( "This item cannot be edited because it is from the past" );
        return \%args;
    }

    use Core::Billing;
    my %wd = $self->get;
    my %new_wd = calc_withdraw( $us->billing, $service->get, %wd, %args );

    # Always forbid set/change withdraw_date because of it makes by spool
    delete $new_wd{withdraw_date};

    if ( $us->get_withdraw_id == $self->id && $us->get_status eq STATUS_ACTIVE ) {
        $us->set( expire => $new_wd{end_date} );
    } else {
        # Forbid set end_date for non active user service
        delete $new_wd{end_date};
    }

    if ( $wd{total} != $new_wd{total} ) {
        unless ( $self->unpaid ) {
            $self->user->set_balance(
                balance => ($wd{total} - $wd{bonus}) - ($new_wd{total} - $new_wd{bonus}),
            );
        }
    }

    if ( $wd{bonus} != $new_wd{bonus} ) {
        unless ( $self->unpaid ) {
            $self->user->set_bonus(
                bonus => $wd{bonus} - $new_wd{bonus},
                comment => { comment => sprintf("changed withdraw %d by admin", $self->id) },
            );
        }
    }

    my $ret = $self->set( %new_wd );
    $us->touch;

    return scalar $self->get;
}

sub sum {
    my $self = shift;
    my %args = (
        where => {},
        @_,
    );

    $args{where}{withdraw_date} ||= {'!=' => undef };

    return $self->SUPER::sum( %args );
}

1;
