use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    package Core::Base;
    use Exporter 'import';
    our @EXPORT = qw(get_service cfg);
    sub get_service { die 'Unexpected application service lookup in topology unit test' }
    sub cfg { die 'Unexpected application configuration lookup in topology unit test' }
    $INC{'Core/Base.pm'} = __FILE__;

    package Core::Utils;
    use Exporter 'import';
    our @EXPORT_OK = qw(decode_json encode_json);
    sub decode_json { die 'Unexpected JSON decoding in topology unit test' }
    sub encode_json { die 'Unexpected JSON encoding in topology unit test' }
    $INC{'Core/Utils.pm'} = __FILE__;
}

use Core::Topology;

{
    package TopologyFixture;
    our @ISA = ('Core::Topology');
    sub new { bless {}, shift }
    sub library { {} }
    sub events {
        return { id => 8, name => 'CREATE', kind => 'UserService', server_gid => 2,
            settings => { category => 'vpn', template_id => 'deploy' } };
    }
    sub services { return { service_id => 4, name => 'Example tariff', category => 'vpn' } }
    sub server_groups { return { 2 => { name => 'Pool', transport => 'ssh', type => 'random' } } }
    sub servers {
        return { server_id => 3, server_gid => 2, name => '', transport => 'ssh',
            host => 'root@192.0.2.10', enabled => 0, settings => { template_id => 'bootstrap' } };
    }
    sub _cache { undef }
}

my $topology = TopologyFixture->new;
my $graph = $topology->graph(event => 'create');
my %nodes = map { $_->{uid} => $_ } @{$graph->{nodes}};
is($nodes{'ev:UserService:create'}{subtitle}, '创建服务', 'event display text is Chinese');
is($nodes{'ev:UserService:create'}{key}, 'create', 'event machine name is preserved');
is($nodes{'cat:vpn'}{key}, 'vpn', 'category identifier is preserved');
is($nodes{'cat:vpn'}{subtitle}, '1 项服务', 'service count has a Chinese unit');
is($nodes{'grp:2'}{title}, 'Pool', 'operator-defined group name is preserved');
is($nodes{'srv:3'}{title}, '服务器 #3', 'server fallback title is Chinese');
is($nodes{'srv:3'}{meta}{host}, 'root@192.0.2.10', 'SSH host is not translated');
is($nodes{'srv:3'}{meta}{enabled}, 0, 'server enablement metadata is unchanged');
is($nodes{'tpl:deploy'}{subtitle}, 'SHM 中不存在此模板', 'missing template message is Chinese');
ok(scalar(grep { $_->{source} eq 'grp:2' && $_->{target} eq 'srv:3'
        && $_->{kind} eq 'route' && $_->{label} eq '已禁用' } @{$graph->{edges}}),
    'routing edge preserves its identifiers and localizes its display label');
ok(scalar(grep { $_->{source} eq 'srv:3' && $_->{target} eq 'tpl:bootstrap'
        && $_->{kind} eq 'calls' && $_->{label} eq '默认模板' } @{$graph->{edges}}),
    'default template edge keeps the machine relationship');
is_deeply($topology->clear_cache, {success => 0, message => 'Redis 不可用'},
    'missing cache returns a localized result without external access');

done_testing();
