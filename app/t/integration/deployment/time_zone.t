use v5.14;
use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";

plan skip_all => 'Set SHM_SQL_CONFIG_TEST=1 with an isolated test database'
    unless $ENV{SHM_SQL_CONFIG_TEST};

require DBI;
require Core::Sql::Data;

my $database = $ENV{DB_NAME} // die "DB_NAME is required for the isolated database test\n";
my $host = $ENV{DB_HOST} // '127.0.0.1';
my $port = $ENV{DB_PORT} // 3306;
my $dbh = DBI->connect(
    "DBI:mysql:database=$database;host=$host;port=$port",
    $ENV{DB_USER},
    $ENV{DB_PASS},
    { RaiseError => 0, PrintError => 0, AutoCommit => 1, mysql_enable_utf8mb4 => 1 },
) or die "Isolated test database connection failed\n";

local $ENV{TZ} = 'Asia/Shanghai';
local $ENV{DB_TZ} = '';
ok(Core::Sql::Data::configure($dbh), 'named Shanghai time zone configures a real MySQL session');
is($dbh->selectrow_array('SELECT @@session.time_zone'), 'Asia/Shanghai',
    'MySQL session has the named time zone');
is($dbh->selectrow_array(q{
    SELECT CONVERT_TZ('2026-10-12 00:00:00', '+00:00', 'Asia/Shanghai')
}), '2026-10-12 08:00:00', 'named time zone data is loaded');

$ENV{DB_TZ} = '+08:00';
ok(Core::Sql::Data::configure($dbh), 'explicit offset configures the same connection');
is($dbh->selectrow_array('SELECT @@session.time_zone'), '+08:00', 'offset is bound correctly');
is($ENV{TZ}, 'Asia/Shanghai', 'application time zone is unchanged');

$ENV{DB_TZ} = 'Asia/NotARealTimeZone';
my $success = eval { Core::Sql::Data::configure($dbh); 1 };
ok(!$success, 'unknown named time zone fails against the real driver');
like($@, qr/数据库时区设置失败/, 'failure is explicit');
is($dbh->selectrow_array('SELECT @@session.time_zone'), '+08:00',
    'failed statement did not silently change time zones');

$dbh->disconnect;
done_testing();
