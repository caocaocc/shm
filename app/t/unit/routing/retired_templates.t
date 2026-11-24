use v5.14;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(getcwd);
use Template::Constants qw(STATUS_DECLINED);
use Core::Template;
use Core::Events;
use Core::Spool;
use Core::Const;

{
    package FixtureAdmin;
    sub is_admin { 1 }

    package FixtureSpool;
    sub dbh { $_[0]->{db} }
    sub res { $_[0]->{row} = $_[1]; $_[0] }
    sub write_history_start { $_[0]->{history_method} = $_[0]->{row}{event}{method} }
    sub finish_task { my ($self, %result) = @_; $self->{result} = \%result }
    sub make_task { return Core::Const::TASK_SUCCESS(), {} }

    package FixtureDB;
    sub do { my ($self, $sql, undef, @params) = @_; $self->{updated_id} = $params[-1]; 1 }
}

local $ENV{SHM_TEST} = 1;
my $cwd = getcwd();
my $dir = tempdir(CLEANUP => 1);
chdir $dir or die $!;
make_path('data/templates/accounts');
my %rows;
for my $id (qw(routing remnawave_routing remnawave_account accounts/routing)) {
    $rows{$id} = {id => $id, data => "source $id", settings => {allow_public => 1}};
    Core::Template::write_template_to_file($id, $rows{$id}{data}, $rows{$id}{settings}) or die "write $id";
}
symlink 'routing.tpl', 'data/templates/old.tpl' or die $!;

no warnings qw(redefine once);
local *Core::Template::_db_list = sub {
    my ($self, %args) = @_;
    my $row = $rows{lc($args{id} // $args{where}{'templates.id'})};
    return $row ? ($row) : ();
};
local *Core::Template::user = sub { bless {}, 'FixtureAdmin' };
for my $file_mode (0, 1) {
    subtest $file_mode ? 'file templates' : 'database templates' => sub {
        my $templates = Core::Template->new(file_mode => $file_mode, user_id => 1);
        local *Core::Template::Provider::get_service = sub {
            my (undef, %args) = @_;
            return Core::Template->new(id => $args{_id}, file_mode => $file_mode, user_id => 1);
        };
        my $provider = Core::Template::Provider->new;
        for my $id (qw(routing remnawave_routing)) {
            ok(!Core::Template->new(id => $id, file_mode => $file_mode), "$id unavailable to transports");
            is(($provider->_load("./$id.tpl"))[1], STATUS_DECLINED, "TT cannot include $id");
            is($templates->parse_for_api(id => $id, do_not_parse => 1), "source $id", "administrator can read $id");
        }
        for my $id (qw(remnawave_account accounts/routing)) {
            is(($provider->_load($id))[0]{text}, "source $id", "ordinary template $id still available");
        }
        if ($file_mode) {
            for my $id ('old', 'accounts/../routing') {
                ok(!Core::Template->new(id => $id, file_mode => 1), "retired file alias $id is inert");
            }
        }
    };
}
chdir $cwd or die $!;

subtest 'old bindings remain visible only to administrators' => sub {
    my @bindings = (
        {id => 9, kind => 'UserService', name => 'changed', server_gid => 1,
            settings => {category => 'vpn', template_id => 'remnawave_routing'}},
        {id => 10, kind => 'UserService', name => 'changed', server_gid => 1,
            settings => {category => 'vpn', template_id => 'remnawave_account'}},
    );
    local *Core::Events::list = sub { @bindings };
    my $events = bless {}, 'Core::Events';
    is_deeply([map {$_->{id}} $events->get_events(name => 'CHANGED')], [10], 'only account binding is scheduled');
    is_deeply([map {$_->{id}} $events->list], [9,10], 'administrative event list retains both');
};

subtest 'unconverted jobs are held for review before dispatch' => sub {
    my $spool = bless {db => bless({}, 'FixtureDB')}, 'FixtureSpool';
    local *Core::Spool::get_service = sub {
        die "Unexpected dispatch to $_[0]" unless $_[0] eq 'spool';
        return $spool;
    };
    for my $task (
        {id => 21, settings => {template_id => 'routing'}, event => {name => 'CHANGED'}},
        {id => 22, settings => {}, event => {kind => 'Transport::Ssh', method => 'send',
            server_gid => 1, settings => {template_id => 'remnawave_routing'}}},
    ) {
        Core::Spool::process_one($spool, $task);
        is_deeply($spool->{result}, {status => TASK_STUCK, response => {error => 'ROUTING_TEMPLATE_RETIRED'}},
            "old job $task->{id} was retained without running");
    }
};

subtest 'Spool can adopt the original panel receipt before core starts' => sub {
    my $spool = bless {db => bless({}, 'FixtureDB')}, 'FixtureSpool';
    my $panel = 'a' x 64;
    my $job = {id => 23, user_id => 1, event => {name => 'CHANGED'}, settings => {
        template_id => 'remnawave_routing', transport => 'local', routing_panel => $panel,
    }};
    local *Core::Spool::get_service = sub { return $spool if $_[0] eq 'spool' || $_[0] eq 'user'; die "Unexpected dispatch to $_[0]" };
    local *Core::Spool::switch_user = sub { is($_[0], 1, 'uses the publishing worker identity') };
    Core::Spool::process_one($spool, $job);
    is($spool->{db}{updated_id}, 23, 'updates the locked job with the ID referenced by the receipt');
    is($spool->{history_method}, 'publish_task', 'history records the native publisher');
    is_deeply($job->{settings}, {routing_panel => $panel}, 'preserves the intended panel');
    is($spool->{result}{status}, TASK_SUCCESS, 'native task dispatched normally');
};
done_testing();
