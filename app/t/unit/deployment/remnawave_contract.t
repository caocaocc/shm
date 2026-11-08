use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use Text::Balanced qw(extract_codeblock);
use lib "$FindBin::Bin/../../../lib";
use Core::Const;

# Exercise existing API contracts without bootstrapping SHM, SQL or SSH.
my $app = "$FindBin::Bin/../../..";
sub read_text {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
    return do { local $/; <$fh> };
}
my $cgi = read_text("$app/public_html/shm/v1.cgi");
sub block_after {
    my ($source, $anchor) = @_;
    my ($tail) = $source =~ /$anchor(\{.*)\z/s;
    BAIL_OUT('Cannot locate source block') unless defined $tail;
    my ($block) = extract_codeblock($tail, '{}');
    BAIL_OUT('Cannot extract source block') unless $block;
    return $block;
}
sub route {
    my ($path) = @_;
    my $block = block_after($cgi, qr/'\Q$path\E'\s*=>\s*/);
    my $route = eval "+$block";
    BAIL_OUT("Cannot load route $path: $@") unless ref $route eq 'HASH';
    return $route;
}
sub structure {
    my ($controller) = @_;
    my $text = read_text("$app/lib/Core/$controller.pm");
    my $body = block_after($text, qr/sub\s+structure\s*/);
    my $getter = eval "sub $body";
    BAIL_OUT("Cannot load structure $controller: $@") unless ref $getter eq 'CODE';
    return $getter->();
}
my $validator = eval 'sub ' . block_after($cgi, qr/sub\s+validate_params\s*/);
BAIL_OUT("Cannot load validator: $@") unless ref $validator eq 'CODE';

for my $pair (
    ['/admin/template', 'Template'],
    ['/admin/server', 'Server'],
    ['/admin/server/group', 'ServerGroups'],
    ['/admin/service/event', 'Events'],
) {
    my ($path, $controller) = @$pair;
    my $route = route($path);
    is($route->{GET}{controller}, $controller, "$path retains existing reads");
    is($route->{PUT}{controller}, $controller, "$path retains standard creation");
    is($route->{POST}{controller}, $controller, "$path retains standard updates");
    ok(!$route->{PUT}{method} && !$route->{POST}{method}, "$path uses existing create/update dispatch");
}
is(route('/admin/template')->{GET}{method}, 'list', 'Dashboard can list existing templates');
my $source_route = route('/admin/template/*');
is($source_route->{splat_to}, 'id', 'template source route accepts the chosen name');
is($source_route->{GET}{method}, 'parse_for_api', 'existing template read handler is preserved');
is($source_route->{GET}{args}{do_not_parse}, 1, 'Dashboard can read unrendered source for editing');

sub validate_model {
    my ($controller, $args) = @_;
    my $structure = structure($controller);
    my %schema;
    for my $field (keys %$structure) {
        my $type = $structure->{$field}{type} // 'string';
        $type = 'string' if $type =~ /^(?:text|now|date)$/;
        $schema{$field} = {type => $type};
    }
    my %allowed = map { $_ => 1 } keys %schema;
    for my $field (keys %$args) {
        return "Unknown field: $field" unless $allowed{$field};
    }
    return $validator->(\%schema, $args, \%allowed);
}

for my $name ('vpn_rmw', 'existing-vpn-template') {
    is(validate_model('Template', {
        id => $name,
        data => '#!/bin/bash',
        settings => {},
    }), undef, "manual template name $name conforms to existing API types");
}
is(validate_model('Server', {
    server_id => 17,
    server_gid => 4,
    transport => 'ssh',
    host => 'existing-ssh.example.test',
    settings => {
        template_id => 'existing-vpn-template',
        key_id => 9,
        remnawave => {
            api => 'https://panel.example.test',
            token => 'non-sensitive-test-fixture',
            shm_tz => 'Asia/Shanghai',
        },
    },
}), undef, 'existing server accepts nested template settings without a new group');
like(validate_model('Server', {settings => 'not-json'}), qr/must be an object/,
    'server settings rejects a scalar');
is(validate_model('Server', {settings => []}), undef,
    'upstream generic JSON accepts arrays without narrowing unrelated routes');

my $events = structure('Events');
my %names = map { $_ => 1 } @{$events->{name}{enum}};
for my $name (qw(CREATE ACTIVATE BLOCK REMOVE PROLONGATE CHANGED CHANGED_TARIFF)) {
    ok($names{$name}, "current core supports $name");
}
ok(!$names{UPDATE}, 'legacy UPDATE is a template alias, not a new core event');
is(validate_model('Events', {
    name => 'CHANGED_TARIFF',
    title => '同步现有套餐',
    server_gid => 4,
    settings => {
        template_id => 'existing-vpn-template',
        category => 'existing-category',
    },
}), undef, 'optional tariff event reuses existing group, template name and category');

done_testing();
