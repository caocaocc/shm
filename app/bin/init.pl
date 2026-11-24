#!/usr/bin/perl

use v5.14;
use SHM;
use Core::System::ServiceManager qw( get_service );
use Core::Utils qw(
    read_file
    switch_user
);
use Core::Sql::Data;
use version;
use JSON::PP;

my $sql = Core::Sql::Data->new;
my $migration_boundary_version = version->parse('0.2.17');

my $version;
my $version_prefix;
if ( -f "$ENV{SHM_ROOT_DIR}/version.json" ) {
    my $version_json_str = read_file( "$ENV{SHM_ROOT_DIR}/version.json" );
    my $version_data = decode_json( $version_json_str );
    $version = $ENV{SHM_VERSION_OVERRIDE} || $version_data->{version};
    $version_prefix = "-" . $version_data->{commitSha};
    $version =~s/-.+$//;
    say "SHM 版本： $version$version_prefix";
}

my $logger = get_service('logger');
my $config = get_service('config');
my $dbh = db_connect( %{ $config->file->{config}{database} } ) or die "无法连接数据库";
$config->local('dbh', $dbh );
switch_user( 1 );

require Core::Routing::Install;
Core::Routing::Install::prepare_volume($ENV{SHM_ROOT_DIR});

my $tables_count = $sql->do("SHOW TABLES");

# A development reset must never discard real payment orders or measured bills.
sub has_column {
    my ($table, $column) = @_;
    return $dbh->selectrow_array('SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=? AND column_name=?', undef, $table, $column);
}
my ($old_ledger) = $dbh->selectrow_array("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='consumption_periods'");
defined $old_ledger or die "无法核对既有计量账本。\n";
if ($old_ledger && $dbh->selectrow_array('SELECT 1 FROM consumption_periods LIMIT 1')) {
    die "历史计量账期仍有数据，请核对后再升级。\n";
}
if ($ENV{DEV} && $ENV{DEV_DB_CLEANUP} && $tables_count) {
    die "开发库含有分流记录，已停止清理。\n" if has_column('storage','name') && $dbh->selectrow_array("SELECT 1 FROM storage WHERE user_id=0 AND (name LIKE 'routing:%' OR name LIKE 'routingp:%') LIMIT 1");
    die "开发库含有支付订单，已停止清理。\n" if has_column('epay_orders','out_trade_no') && $dbh->selectrow_array('SELECT 1 FROM epay_orders LIMIT 1');
    die "开发库含有计量账单，已停止清理。\n" if has_column('withdraw_history','usage') && $dbh->selectrow_array('SELECT 1 FROM withdraw_history WHERE `usage` IS NOT NULL LIMIT 1');
}
if ( $ENV{DEV} || $tables_count == 0 ) {
    if ( $ENV{DEV} && $ENV{DEV_DB_CLEANUP} && $tables_count ) {
        print "正在清理开发数据库… ";
        import_sql_file( $dbh, "$ENV{SHM_ROOT_DIR}/sql/shm/shm_dev_cleanup.sql" );
        say "完成";
    }

    print "正在创建数据库结构… ";
    import_sql_file( $dbh, "$ENV{SHM_ROOT_DIR}/sql/shm/shm_structure.sql" );
    say "完成";

    if ( $ENV{DEV} ) {
        print "正在载入开发测试数据… ";
        import_sql_file( $dbh, "$ENV{SHM_ROOT_DIR}/sql/shm/shm_dev_test_data.sql" );
    } else {
        print "正在载入初始数据… ";
        import_sql_file( $dbh, "$ENV{SHM_ROOT_DIR}/sql/shm/shm_data.sql" );
    }
    $config->id( '_shm' )->set_value( { version => $version . $version_prefix } ) if $version;
    say "完成";
} elsif ( $version ) {
    # Start migrations
    chdir "$ENV{SHM_ROOT_DIR}/bin/migrations";

    my $config = $config->id( '_shm' );
    my $cur_version = $ENV{SHM_VERSION_OVERRIDE_DB} || $config->get_data->{version};
    say "数据库版本： $cur_version";

    # Check version format (should be like 1.2.3-abcd)
    unless ( $cur_version && $cur_version =~ /^\d+\.\d+\.\d+-.+$/ ) {
        say "Invalid version format '$cur_version', using current version '$version'";
        $cur_version = $version . $version_prefix;
        $config->set_value( { version => $cur_version } );
    }

    $cur_version =~s/-.+$//;

    my @migrations = `ls`;
    for ( @migrations ) {
        chomp;
        ~s/\.sql$//;
    }

    my @versions = sort { version->parse( $a ) <=> version->parse( $b ) } @migrations;

    for my $nv ( @versions ) {
        next if version->parse( $nv ) <= version->parse( $cur_version );
        next if version->parse( $nv ) > version->parse( $version );

        say "Applying migration for version: $nv ...";
        eval {
            if ( version->parse( $nv ) > $migration_boundary_version ) {
                import_sql_file( $dbh, "$nv.sql" );
            } else {
                run_legacy_migration( $nv );
            }
            1;
        } or do {
            my $error = $@ || "Unknown migration error";
            chomp $error;
            eval { $dbh->rollback(); };
            die "Migration for version '$nv' failed: $error\n";
        };

        $config->set_value( { version => $nv . $version_prefix } );
        $dbh->commit() or die "Commit failed after migration '$nv': " . ( $dbh->errstr // 'unknown error' ) . "\n";
        say "完成"
    }

    $config->set_value( { version => $version . $version_prefix } );
}

$dbh->do('ALTER TABLE withdraw_history ADD COLUMN `usage` JSON DEFAULT NULL')
    unless has_column('withdraw_history','usage');

use lib "$ENV{SHM_ROOT_DIR}/pay_systems/epay/lib";
require SHM::Pay::Epay::Install;
SHM::Pay::Epay::Install::bootstrap($dbh, $ENV{SHM_ROOT_DIR},
    !$tables_count || ($ENV{DEV} && $ENV{DEV_DB_CLEANUP}));

Core::Routing::Install::install($dbh);

# Load cloud and download paysystems and templates
get_service('Cloud::Jobs')->startup();

$dbh->commit();
$dbh->disconnect();

exit 0;

sub import_sql_file {
    my $dbh = shift;
    my $file = shift;

    my $data = read_file( $file ) or die "Can't read file: $file";

    my @sql = sql_split( $data );

    for my $statement ( @sql ) {
        my $res = $dbh->do( $statement );
        die "SQL execution failed in '$file': " . ( $dbh->errstr // 'unknown error' ) . "\nStatement: $statement\n"
            unless defined $res;
    }
}

sub run_legacy_migration {
    my $file = shift;

    my $legacy_code = read_file( $file )
        or die "Can't read legacy migration file: $file\n";

    my $ok = eval $legacy_code;
    die "Legacy migration '$file' failed: $@\n" if $@;

    return $ok;
}

sub sql_split {
    my $sql       = shift;
    my $delimiter = ';';
    my @statements;

    while ( length $sql ) {
        # Handle DELIMITER directive (case-insensitive, at start of current position)
        if ( $sql =~ /\A\s*DELIMITER[ \t]+(\S+)[^\n]*(?:\n|\z)/si ) {
            $delimiter = $1;
            $sql = substr( $sql, $+[0] );
            next;
        }

        my $pos = _sql_find_delimiter( $sql, $delimiter );
        if ( defined $pos ) {
            my $stmt = substr( $sql, 0, $pos );
            push @statements, $stmt if $stmt =~ /\S/;
            $sql = substr( $sql, $pos + length($delimiter) );
        }
        else {
            push @statements, $sql if $sql =~ /\S/;
            last;
        }
    }

    return @statements;
}

sub _sql_find_delimiter {
    my ( $sql, $delim ) = @_;
    my $len       = length $sql;
    my $dlen      = length $delim;
    my $in_string = 0;
    my $escape    = 0;
    my $i         = 0;

    while ( $i < $len ) {
        my $c = substr( $sql, $i, 1 );
        if ( $in_string ) {
            if    ( $escape )        { $escape = 0 }
            elsif ( $c eq '\\' )     { $escape = 1 }
            elsif ( $c eq "'" )      { $in_string = 0 }
            $i++;
        }
        else {
            if ( $c eq "'" ) {
                $in_string = 1;
                $i++;
            }
            elsif ( $dlen <= $len - $i && substr( $sql, $i, $dlen ) eq $delim ) {
                return $i;
            }
            else { $i++ }
        }
    }
    return undef;
}

sub do_sql {
    my $data = shift;

    my @sql = sql_split( $data );

    my $report = get_service('report');

    for ( @sql ) {
        say $_;
        $sql->do( $_ );
        unless ( $report->is_success ) {
            say $_ for ( $report->errors );
            exit 1;
        }
    }
}

