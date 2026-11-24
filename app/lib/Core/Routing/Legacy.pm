package Core::Routing::Legacy;

use v5.14;
use utf8;
use JSON::PP ();
use File::Spec;
use Cwd qw(realpath);

# The two former templates remain visible as source in the administration UI.
sub retired {
    my ($id, $directory) = @_;
    return unless defined $id && !ref $id;
    return 1 if $id =~ m{\A(?:\./)*(?:routing|remnawave_routing)(?:\.tpl)?\z}i;
    return unless defined $directory;
    my $file = realpath("$directory/$id.tpl") or return;
    return retired(File::Spec->abs2rel($file, realpath($directory)));
}

sub binding {
    for my $settings (@_) {
        return 1 if ref($settings) eq 'HASH' && retired($settings->{template_id});
    }
    return;
}

# Spool holds the row lock. Preserve the receipt's task ID and schedule.
sub adopt {
    my ($dbh, $job) = @_;
    my ($event, $args) = @$job{qw(event settings)};
    return unless ref $event eq 'HASH' && ref $args eq 'HASH';
    return unless uc($event->{name} // '') eq 'CHANGED' && !$event->{method} && !$event->{period};
    return if defined $event->{kind} && $event->{kind} ne 'UserService';
    my $binding = $event->{settings} // {};
    return unless ref $binding eq 'HASH';
    my @templates = grep { defined } ($binding->{template_id}, $args->{template_id});
    return if !@templates || grep { $_ ne 'remnawave_routing' } @templates;

    my ($method, $title, $settings);
    if (exists $args->{routing_panel}) {
        return unless $job->{user_id} == 1 && !$job->{user_service_id} && !$args->{user_service_id}
            && !$event->{server_gid} && ($args->{transport} // '') eq 'local'
            && ($args->{routing_panel} // '') =~ /\A[0-9a-f]{64}\z/;
        $method = 'publish_task';
        $title = '同步面板分流配置';
        $settings = {routing_panel => $args->{routing_panel}};
    } else {
        my $id = $args->{user_service_id};
        return unless ($id // '') =~ /\A[1-9][0-9]*\z/ && ($job->{user_id} // '') =~ /\A[1-9][0-9]*\z/;
        return if $job->{user_service_id} && $job->{user_service_id} != $id;
        $method = 'lifecycle_task';
        $title = '同步服务分流配置';
        $settings = {routing_user_id => 0+$job->{user_id}, routing_service_id => 0+$id};
    }
    my $native = {kind => 'Routing', name => 'SYSTEM', method => $method, title => $title};
    my $codec = JSON::PP->new;
    $dbh->do('UPDATE spool SET event=?,settings=?,user_id=1,user_service_id=NULL WHERE id=?', undef,
        $codec->encode($native), $codec->encode($settings), $job->{id}) or die "Cannot adopt routing task\n";
    @$job{qw(event settings user_id user_service_id)} = ($native, $settings, 1, undef);
    return 1;
}

1;
