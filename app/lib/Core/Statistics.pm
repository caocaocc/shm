package Core::Statistics;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Utils qw(
    now
);
use Core::System::ServiceManager qw( logger );

sub table { return 'statistics' };

sub structure {
    return {
        date => {
            type => 'date',
            key => 1,
            title => '日期',
        },
        kind => {
            type => 'text',
            title => '控制器',
        },
        field => {
            type => 'text',
            title => '类型',
        },
        count => {
            type => 'number',
            title => '数量',
        },
        sum => {
            type => 'number',
            title => '金额',
        },
        min => {
            type => 'number',
            title => '最小金额',
        },
        max => {
            type => 'number',
            title => '最大金额',
        },
        avg => {
            type => 'number',
            title => '平均金额',
        },
    };
}

sub add {
    my ($self, $kind, $field, $value) = @_;
    return unless defined $value;

    return $self->do(q{
        INSERT INTO statistics
        (`date`,`kind`,`field`,`count`,`sum`,`min`,`max`,`avg`)
        VALUES (?, ?, ?, 1, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            count = count + 1,
            sum = sum + VALUES(sum),
            min = LEAST(min, VALUES(min)),
            max = GREATEST(max, VALUES(max)),
            avg = (sum + VALUES(sum)) / (count + 1)
    },
        now(),
        lc $kind,
        lc $field,
        $value + 0,
        $value + 0,
        $value + 0,
        $value + 0,
    );
}

sub cleanup {
    my $self = shift;
    my $days = cfg('billing')->{cleanup}->{Statistics} // 30;
    return $self unless $days;

    $self->_delete( where => {
        date => { '<', \[ 'NOW() - INTERVAL ? DAY', $days ] },
    });

    return $self;
}

1;