use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use File::Basename qw(dirname);
use FindBin;
use Cwd qw(abs_path);
use Encode qw(decode);

# Exercise the real CGI in a child process. Its dependencies are isolated, so
# this test never opens the host log FIFO, database, credentials, or data volume.
my $app = $ENV{SHM_ROOT_DIR} || File::Spec->catdir($FindBin::Bin, '..', '..', '..');
my $cgi = abs_path(File::Spec->catfile($app, 'pay_systems', 'epay.cgi'));
BAIL_OUT('Cannot locate the real payment CGI') unless $cgi && -f $cgi;
my $fixture = tempdir(CLEANUP => 1);
my $lib = "$fixture/lib";

sub write_file {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open(my $fh, '>:raw', $path) or die "Cannot write fixture: $!";
    print {$fh} $bytes or die "Cannot write fixture: $!";
    close($fh) or die "Cannot close fixture: $!";
}

write_file("$lib/InstallFixture.pm", <<'MODULE');
package InstallFixture;
use strict;
use warnings;
sub event {
    open(my $fh, '>>', $ENV{EPAY_INSTALL_TEST_TRACE}) or die "Cannot open fixture trace";
    print {$fh} "$_[0]\n"; close($fh) or die "Cannot close fixture trace";
}
sub scenario { $ENV{EPAY_INSTALL_TEST_SCENARIO} // '' }
sub sensitive_error { die "fixture-private-token https://fixture.invalid/private-key\n" }
1;
MODULE

write_file("$lib/SHM.pm", <<'MODULE');
package SHM;
use strict;
use warnings;
use Exporter 'import';
use InstallFixture;
use JSON::PP ();
our @EXPORT_OK = qw(print_header print_json);
sub new {
    InstallFixture::event('shm:new');
    die "SHM constructor is forbidden during installer bootstrap\n";
}
sub print_header {
    my %args = @_;
    print "Status: " . ($args{status} // 200) . "\n\n";
}
sub print_json { print JSON::PP->new->utf8->encode($_[0]) }
1;
MODULE

write_file("$lib/Core/System/ServiceManager.pm", <<'MODULE');
package Core::System::ServiceManager;
use strict;
use warnings;
use Exporter 'import';
use InstallFixture;
our @EXPORT_OK = qw(get_service);
my $config = bless {local => {}}, 'InstallFixture::Config';
sub get_service {
    return $config if $_[0] eq 'config';
    return bless {}, 'InstallFixture::Report' if $_[0] eq 'report';
    die "Unexpected service";
}
package InstallFixture::Config;
sub file {
    InstallFixture::event('config:file');
    return {config => {database => {db_name => 'installer-fixture'}}};
}
sub local {
    my ($self, $key, $value) = @_;
    return $self->{local} unless defined $key;
    if (@_ == 3) {
        $self->{local}{$key} = $value;
        InstallFixture::event('bind:dbh') if $key eq 'dbh';
    }
    return $self->{local}{$key};
}
package InstallFixture::Report;
sub errors { 'HTTP authentication required' }
1;
MODULE

write_file("$lib/Core/Sql/Data.pm", <<'MODULE');
package Core::Sql::Data;
use strict;
use warnings;
use InstallFixture;
sub db_connect {
    my %args = @_;
    InstallFixture::event('connect');
    die "Unexpected database config" unless ($args{db_name} // '') eq 'installer-fixture';
    InstallFixture::sensitive_error() if InstallFixture::scenario() eq 'connect_die';
    return undef if InstallFixture::scenario() eq 'connect_empty';
    return bless {}, 'InstallFixture::DB';
}
package InstallFixture::DB;
sub commit {
    InstallFixture::event('commit');
    InstallFixture::sensitive_error() if InstallFixture::scenario() eq 'commit_die';
    return 0 if InstallFixture::scenario() eq 'commit_false';
    return 1;
}
sub rollback { InstallFixture::event('rollback'); return 1 }
sub disconnect { InstallFixture::event('disconnect'); return 1 }
1;
MODULE

write_file("$lib/Core/Utils.pm", <<'MODULE');
package Core::Utils;
use strict;
use warnings;
use Exporter 'import';
use InstallFixture;
our @EXPORT_OK = qw(parse_args html_escape encode_utf8 qrencode random_bytes switch_user);
our %response_headers;
sub parse_args {
    InstallFixture::event('http:parse');
    return (action => 'status', out_trade_no => 'fixture');
}
sub switch_user {
    InstallFixture::event("switch:$_[0]");
    Core::System::ServiceManager::get_service('config')->local('user_id', $_[0]);
}
sub html_escape { $_[0] }
sub encode_utf8 { $_[0] }
sub qrencode { die "Unexpected QR generation" }
sub random_bytes { 'x' x $_[0] }
1;
MODULE

write_file("$fixture/pay_systems/lib/SHM/Pay/Epay.pm", <<'MODULE');
package SHM::Pay::Epay;
use strict;
use warnings;
use InstallFixture;
sub new { InstallFixture::event('module:new'); return bless {}, shift }
sub initialize {
    InstallFixture::event('initialize');
    my $config = Core::System::ServiceManager::get_service('config');
    die "Installer did not bind its database" unless ref($config->local('dbh')) eq 'InstallFixture::DB';
    die "Installer did not select the system user" unless ($config->local('user_id') // 0) == 1;
    InstallFixture::sensitive_error() if InstallFixture::scenario() eq 'initialize_die';
    return {ready => 1};
}
1;
MODULE

sub read_file {
    my ($path) = @_;
    return '' unless -e $path;
    open(my $fh, '<:raw', $path) or die "Cannot read fixture: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return $bytes // '';
}

my $case = 0;
sub run_cgi {
    my (%args) = @_;
    my $path = "$fixture/run-" . ++$case;
    local %ENV = %ENV;
    delete @ENV{grep { /\A(?:HTTP_|REQUEST_|CONTENT_|QUERY_STRING\z|SCRIPT_|PATH_INFO\z|DB_|PERL5OPT\z)/ } keys %ENV};
    $ENV{PERL5LIB} = $lib;
    $ENV{SHM_ROOT_DIR} = $fixture;
    $ENV{EPAY_INSTALL_TEST_TRACE} = "$path.trace";
    $ENV{EPAY_INSTALL_TEST_SCENARIO} = $args{scenario} // '';
    $ENV{REQUEST_METHOD} = $args{method} if defined $args{method};
    my $pid = fork();
    die "Cannot fork fixture: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', File::Spec->devnull) or die $!;
        open(STDOUT, '>:raw', "$path.stdout") or die $!;
        open(STDERR, '>:raw', "$path.stderr") or die $!;
        exec {$^X} $^X, $cgi, @{ $args{argv} // ['--install'] };
        die "Cannot execute fixture: $!";
    }
    my $timeout;
    {
        local $SIG{ALRM} = sub { die "Fixture timed out\n" };
        eval { alarm 10; waitpid($pid, 0); alarm 0; 1 } or do { $timeout = $@; alarm 0; };
    }
    if ($timeout) { kill 'KILL', $pid; waitpid($pid, 0); BAIL_OUT('Payment installer child timed out') }
    my $status = $?;
    my @events = grep { length } split /\n/, read_file("$path.trace");
    return {
        exit => $status >> 8, signal => $status & 127, events => \@events,
        stdout => decode('UTF-8', read_file("$path.stdout")),
        stderr => decode('UTF-8', read_file("$path.stderr")),
    };
}

my @start = qw(config:file connect bind:dbh switch:1 module:new initialize);
subtest 'trusted CLI bootstraps without an HTTP constructor' => sub {
    my $run = run_cgi();
    is($run->{exit}, 0, 'successful installation exits zero');
    is($run->{signal}, 0, 'child is not killed by a signal');
    is_deeply($run->{events}, [@start, qw(commit disconnect)], 'database context, initialization and durable commit complete in order');
    is($run->{stdout}, '', 'installer emits no CGI response');
    is($run->{stderr}, '', 'successful installation has no diagnostics');
};

for my $scenario (qw(connect_empty connect_die initialize_die commit_false commit_die)) {
    subtest "$scenario fails without acknowledging installation" => sub {
        my $run = run_cgi(scenario => $scenario);
        isnt($run->{exit}, 0, 'failed installation exits nonzero');
        is($run->{signal}, 0, 'failure returns normally rather than crashing');
        my @expected = $scenario =~ /\Aconnect/ ? qw(config:file connect)
            : (@start, ($scenario =~ /\Acommit/ ? ('commit') : ()), qw(rollback disconnect));
        is_deeply($run->{events}, \@expected, 'failure stops further work and closes an established database');
        is($run->{stdout}, '', 'failed installer emits no HTTP success response');
        like($run->{stderr}, qr/本地支付模块初始化失败/, 'failure reports the fixed installation diagnostic');
        unlike($run->{stderr}, qr/fixture-private-token|fixture\.invalid|private-key/, 'internal exception details are not disclosed');
    };
}

for my $method (qw(GET POST)) {
    subtest "$method cannot activate installer through CGI arguments" => sub {
        my $run = run_cgi(method => $method);
        is_deeply($run->{events}, [qw(http:parse shm:new)], 'HTTP request uses authentication and never bootstraps the database');
        like($run->{stdout}, qr/Status: 400/, 'ordinary HTTP error handling runs');
        unlike($run->{stdout} . $run->{stderr}, qr/本地支付模块初始化失败/, 'HTTP request does not enter the CLI error handler');
    };
}

subtest 'CLI installer accepts exactly its dedicated argument' => sub {
    my $run = run_cgi(argv => ['--install', 'user_id=1']);
    is_deeply($run->{events}, [qw(http:parse shm:new)], 'extra arguments cannot bypass the dedicated installer gate');
    unlike($run->{stdout} . $run->{stderr}, qr/本地支付模块初始化失败/, 'extra arguments do not invoke initialization');
};

done_testing;
