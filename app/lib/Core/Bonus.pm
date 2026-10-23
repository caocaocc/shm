package Core::Bonus;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Const;

sub table { return 'bonus_history' };

sub structure {
    return {
        id => {
            type => 'number',
            key => 1,
            title => '奖励 ID',
        },
        user_id => {
            type => 'number',
            auto_fill => 1,
            title => '用户 ID',
        },
        date => {
            type => 'now',
            title => '奖励创建时间',
        },
        bonus => {
            type => 'number',
            required => 1,
            title => '奖励数量',
            use_for_stats => 1,
            stats_use_when_add => 1,
        },
        comment => {
            type => 'json',
            value => undef,
            title => '备注',
        },
    }
}

sub amount {
    my $self = shift;
    return $self->get_bonus;
}

sub api_add {
    my $self = shift;
    my %args = (
        @_,
    );

    my $bonus_id = $self->user->set_bonus( %args );

    return $self->id( $bonus_id )->get;
}

1;
