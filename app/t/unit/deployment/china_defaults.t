use v5.14;
use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use POSIX ();

# Test the real deployment methods without loading unrelated application
# services or connecting to MySQL/Redis. Every unused stub fails if called.
BEGIN {
    package Core::Utils;
    use Exporter 'import';
    our @EXPORT_OK = qw(now decode_json dots_str_to_sql encode_json round round_up round_down);
    for my $name (@EXPORT_OK) {
        no strict 'refs';
        *{$name} = sub { die 'Unexpected utility call in deployment test' };
    }
    $INC{'Core/Utils.pm'} = __FILE__;

    package Core::Base;
    use Exporter 'import';
    our @EXPORT = qw(get_service cfg logger report cache get_smart_args first_item stats confess);
    for my $name (@EXPORT) {
        no strict 'refs';
        *{$name} = sub { die 'Unexpected application service call in deployment test' };
    }
    $INC{'Core/Base.pm'} = __FILE__;

    package Core::System::ServiceManager;
    use Exporter 'import';
    our @EXPORT_OK = qw(get_service logger);
    sub get_service { die 'Unexpected service lookup in deployment test' }
    sub logger { die 'Unexpected logger call in deployment test' }
    $INC{'Core/System/ServiceManager.pm'} = __FILE__;

    package Core::Cloud;
    $INC{'Core/Cloud.pm'} = __FILE__;
}

use Core::Sql::Data ();
use Core::Cloud::Currency ();

{
    package DeploymentDatabase;
    sub new {
        my $class = shift;
        return bless { calls => [], @_ }, $class;
    }
    sub do {
        my ($self, $query, $attributes, @bindings) = @_;
        push @{$self->{calls}}, [$query, $attributes, @bindings];
        return undef if $self->{reject_timezone} && $query eq 'SET time_zone = ?';
        return '0E0';
    }
    sub errstr { 'Unknown or incorrect time zone' }
}

sub configured_database {
    my ($timezone, $database_timezone) = @_;
    local $ENV{TZ} = $timezone;
    local $ENV{DB_TZ} = $database_timezone;
    my $database = DeploymentDatabase->new;
    Core::Sql::Data::configure($database);
    return $database;
}

subtest 'default and explicit database time zones are bound parameters' => sub {
    for my $case (
        [undef, undef, 'Asia/Shanghai'],
        ['', '', 'Asia/Shanghai'],
        ['Asia/Shanghai', '', 'Asia/Shanghai'],
        ['Europe/London', undef, 'Europe/London'],
        ['Asia/Shanghai', '+08:00', '+08:00'],
        ['Asia/Shanghai', '+14:00', '+14:00'],
        ['Asia/Shanghai', '-13:59', '-13:59'],
        ['Asia/Shanghai', 'Etc/GMT-8', 'Etc/GMT-8'],
    ) {
        my $database = configured_database(@$case[0, 1]);
        is_deeply($database->{calls}[-1], ['SET time_zone = ?', undef, $case->[2]],
            "time zone $case->[2] is passed as data");
    }

    local $ENV{TZ} = 'Asia/Shanghai';
    local $ENV{DB_TZ} = '+08:00';
    Core::Sql::Data::configure(DeploymentDatabase->new);
    is($ENV{TZ}, 'Asia/Shanghai', 'DB_TZ does not change the application time zone');
};

subtest 'invalid names, SQL injection and offset ranges fail before SQL' => sub {
    for my $timezone (
        "Asia/Shanghai'; DROP TABLE users; --",
        "Asia/Shanghai\n",
        "Asia/Shanghai\0",
        'Asia/Shanghai ' , '+14:01', '-14:00', '+08:60', '+99:00', '+08',
    ) {
        local $ENV{TZ} = 'Asia/Shanghai';
        local $ENV{DB_TZ} = $timezone;
        my $database = DeploymentDatabase->new;
        my $success = eval { Core::Sql::Data::configure($database); 1 };
        ok(!$success, 'invalid environment value is rejected');
        like($@, qr/无效的数据库时区/, 'failure identifies invalid configuration');
        is(scalar @{$database->{calls}}, 0, 'no SQL runs for invalid configuration');
    }
};

subtest 'missing MySQL named time zone stops configuration without a fallback' => sub {
    local $ENV{TZ} = 'Asia/Shanghai';
    local $ENV{DB_TZ} = '';
    my $database = DeploymentDatabase->new(reject_timezone => 1);
    my $success = eval { Core::Sql::Data::configure($database); 1 };
    ok(!$success, 'a failed SET is fatal even when the driver returns undef');
    like($@, qr/数据库时区设置失败.*Asia\/Shanghai/, 'error identifies the rejected time zone');
    like($@, qr/DB_TZ/, 'error describes the explicit override');
    is_deeply($database->{calls}[-1], ['SET time_zone = ?', undef, 'Asia/Shanghai'],
        'failure never retries with a different time zone');
};

{
    package DeploymentBillingConfig;
    sub get_data { shift->{data} }
}

sub currency_in_fresh_process {
    my $configured_currency = shift;
    pipe(my $reader, my $writer) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        close $reader;
        no warnings 'redefine';
        local *Core::Cloud::Currency::get_service = sub {
            return bless { data => { currency => $configured_currency } }, 'DeploymentBillingConfig';
        };
        my $currency = bless {}, 'Core::Cloud::Currency';
        print $writer $currency->system_currency;
        close $writer;
        POSIX::_exit(0);
    }
    close $writer;
    local $/;
    my $currency = <$reader>;
    close $reader;
    waitpid($pid, 0);
    is($?, 0, 'currency lookup finished without connecting to application services');
    return $currency;
}

subtest 'new deployment defaults to CNY and keeps an explicit legacy currency' => sub {
    is(currency_in_fresh_process(undef), 'CNY', 'missing billing currency defaults to CNY');
    is(currency_in_fresh_process('RUB'), 'RUB', 'configured legacy RUB is retained');
    my $currency = bless {}, 'Core::Cloud::Currency';
    is($currency->get_value('RUB'), 1, 'RUB remains the exchange-rate base');
};

subtest 'payment currency follows the current billing configuration' => sub {
    my $config = bless { data => { currency => 'CNY' } }, 'DeploymentBillingConfig';
    no warnings 'redefine';
    local *Core::Cloud::Currency::get_service = sub { $config };
    my $currency = bless {}, 'Core::Cloud::Currency';
    is($currency->system_currency, 'CNY', 'initial accounting unit');
    $config->{data}{currency} = 'USD';
    is($currency->system_currency, 'USD', 'a persistent worker cannot authorize using a stale unit');
};

done_testing();
