use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use HTTP::Response;
use MIME::Base64 qw(encode_base64);
use Core::Integrations::Remnawave;

our $JSON=JSON::PP->new->canonical->utf8;
sub clone {$JSON->decode($JSON->encode($_[0]))}
sub outbound {return {protocol=>'shadowsocks',settings=>{servers=>[{address=>'8.8.8.8',port=>443,method=>'aes-256-gcm',password=>$_[0]//'SYNTHETIC-SECRET'}]}}}
sub item {my ($id,%args)=@_;$id//=101;return {user_service_id=>0+$id,user_id=>0+$id+200,service_status=>'ACTIVE',expire=>undef,enabled=>JSON::PP::true,data=>{rules=>['Example.COM.','1.1.1.7/24'],outbound=>{protocol=>'shadowsocks',server=>'8.8.8.8',port=>443}},secret=>{outbound=>outbound()},%args}}
{
    package RoutingState;
    sub new {bless {held=>0,closed=>0},shift}
    sub load {die 'lock not held' unless $_[0]{held};main::clone($_[0]{pending})}
    sub save {die 'lock not held' unless $_[0]{held};$_[0]{pending}=main::clone($_[1]);$_[0]{saves}++}
    sub clear {die 'lock not held' unless $_[0]{held};delete $_[0]{pending};$_[0]{clears}++}
    sub close {$_[0]{held}=0;$_[0]{closed}++}
    package RoutingPanel;
    sub new {bless {
        requests=>[],rows=>{'Out Users'=>[{tag=>'platform-unrelated',protocol=>'freedom',settings=>{}}],'Routing Users'=>[{type=>'field',user=>['999'],domain=>['domain:other.test'],outboundTag=>'platform-unrelated'}],'Other Secret'=>[{password=>'DO-NOT-RETURN-OTHER-USERS-SECRET'}]},
        profiles=>[{uuid=>'profile-1',config=>{outbounds=>[{tag=>'direct',protocol=>'freedom',settings=>{}},{snippet=>'Out Users'}],routing=>{rules=>[{type=>'field',ip=>['geoip:private'],outboundTag=>'block'},{snippet=>'Routing Users'}]}}}],
    },shift}
    sub request {
        my ($self,$state,%args)=@_;die 'HTTP before scope lock' unless $state->{held};
        die 'unsafe HTTP flags' unless $args{sensitive} && $args{verify_hostname} && $args{no_redirect} && $args{no_proxy};
        my ($path)=$args{url}=~m{https?://[^/]+(/.*)\z};
        my $body=length($args{content}//'')?$main::JSON->decode($args{content}):undef;
        push @{$self->{requests}},[$args{method},$path,main::clone($body),{map {$_=>$args{$_}} qw(sensitive verify_hostname no_redirect no_proxy timeout)}];
        my $key=$args{method}.':'.($body->{name}//'');
        if (($self->{fail}//'') eq $key) {delete $self->{fail};return HTTP::Response->new(503,'synthetic HTTP failure',[],'DO-NOT-RETURN-TOKEN')}
        if ($self->{raw}) {return HTTP::Response->new(200,'OK',[],delete $self->{raw})}
        my $data;
        if ($path eq '/api/snippets' && $args{method} eq 'GET') {$data={response=>{snippets=>[(map {{name=>$_,snippet=>main::clone($self->{rows}{$_})}} sort keys %{$self->{rows}}),@{$self->{extra_snippet_rows}||[]}]}}}
        elsif ($path =~ m{\A/api/config-profiles(?:/|\z)}) {die 'Profile API must not be requested'}
        elsif ($path =~ m{/api/users/by-username/us_([0-9]+)\z}) {my $id=0+$1;return HTTP::Response->new(404,'missing',[],'') if $self->{missing}{$id};$data={response=>{id=>exists($self->{numeric})?$self->{numeric}:$id+1000,username=>'us_'.$id}}}
        elsif ($path eq '/api/snippets' && $args{method} eq 'PATCH') {$self->{rows}{$body->{name}}=main::clone($body->{snippet});$data={response=>{snippets=>[values %{$self->{rows}}]}}}
        elsif ($path eq '/api/snippets/actions/sync') {return HTTP::Response->new(202,'accepted',[],'')}
        else {die 'unexpected synthetic request'}
        return HTTP::Response->new(200,'OK',['Content-Type'=>'application/json'],$main::JSON->encode($data));
    }
    sub writes {[grep {$_->[0] eq 'PATCH' || $_->[0] eq 'POST'} @{$_[0]{requests}}]}
}
sub fixture {
    my $state=RoutingState->new;my $panel=RoutingPanel->new;
    my $settings={remnawave=>{api=>'https://9.9.9.9',token=>'SYNTHETIC-PANEL-TOKEN'}};
    my @scopes;
    my $factory=sub {die 'recursive scope lock' if $state->{held};$state->{held}=1;push @scopes,$_[0];return $state};
    my $adapter=Core::Integrations::Remnawave->new(http=>sub {$panel->request($state,@_)},clock=>sub {1_700_000_000});
    return {state=>$state,panel=>$panel,settings=>$settings,factory=>$factory,adapter=>$adapter,scopes=>\@scopes};
}
sub run {
    my ($f,$items,%args)=@_;
    return $f->{adapter}->apply(payload=>{feature=>'routing',items=>$items},settings=>$f->{settings},timeout=>90,state_factory=>$f->{factory},%args);
}
sub fresh {my @items=@_;return sub {my %items=map {($_->{user_service_id}=>$_)} @items;return [map {$items{$_}} grep {exists $items{$_}} @{$_[0]}]}}
sub owned {my ($rows,$id,$route)=@_;return [grep {($_->{$route?'ruleTag':'tag'}//'') =~ /_us_${id}_/} @$rows]}
sub syncs {my $f=shift;return scalar grep {$_->[0] eq 'POST'} @{$f->{panel}->writes}}
sub platform_preset {
    my ($f)=@_;
    my @out= ('Out Direct','Out Block','Out Nodes','Out VPN','Out Users');
    my @route=('Routing Private','Routing Secure','Routing Direct','Routing Services','Routing Locator','Routing Users','Routing vlessRoute');
    my %platform=(
        'Out Direct'=>[{protocol=>'freedom',tag=>'direct'}],
        'Out Block'=>[{protocol=>'blackhole',tag=>'block',settings=>{}}],
        'Out Nodes'=>[{protocol=>'freedom',tag=>'nodes',settings=>{}}],
        'Out VPN'=>[{protocol=>'freedom',tag=>'vpn',settings=>{}}],
        'Routing Private'=>[{type=>'field',ip=>['geoip:private'],outboundTag=>'block'}],
        'Routing Secure'=>[{type=>'field',protocol=>['bittorrent'],outboundTag=>'block'}],
        'Routing Direct'=>[{type=>'field',domain=>['domain:platform.test'],outboundTag=>'direct'}],
        'Routing Services'=>[{type=>'field',port=>'25',outboundTag=>'block'}],
        'Routing Locator'=>[{type=>'field',domain=>['geosite:cn'],outboundTag=>'direct'}],
        'Routing vlessRoute'=>[{type=>'field',inboundTag=>['vless-default'],outboundTag=>'nodes'}],
    );
    $f->{panel}{rows}{$_}=clone($platform{$_}) for keys %platform;
    $f->{panel}{profiles}=[{uuid=>'profile-1',config=>{outbounds=>[map {{snippet=>$_}} @out],routing=>{rules=>[map {{snippet=>$_}} @route]}}}];
    return $f;
}

subtest 'owned merge, numeric identity, OR rules and quiet HTTP' => sub {
    my $f=fixture();my $before=clone($f->{panel}{rows});my ($ok,$result)=run($f,[item()]);
    ok($ok,'publication accepted');is($result->{items}{101}{state},'submitted','acceptance is not runtime effectiveness');
    my $rules=owned($f->{panel}{rows}{'Routing Users'},101,1);
    like($rules->[0]{ruleTag},qr/\ASHM_ROUTING_[a-f0-9]{20}_us_101_domain\z/,'managed namespace belongs to this routing feature');
    is(scalar @$rules,2,'domain/IP produce separate OR rules');is_deeply($rules->[0]{user},['1101'],'actual numeric panel identity');
    is_deeply($rules->[0]{domain},['domain:example.com'],'domain suffix normalization');is_deeply($rules->[1]{ip},['1.1.1.0/24'],'network host bits masked');
    is_deeply($f->{panel}{rows}{'Other Secret'},$before->{'Other Secret'},'other named snippet untouched');
    is_deeply($f->{panel}{rows}{'Out Users'}[0],$before->{'Out Users'}[0],'first unrelated outbound preserved');
    is(syncs($f),1,'one sync');ok(!$f->{state}{held},'scope lock released');ok(!$f->{state}{pending},'journal cleared');
    unlike($JSON->encode($result),qr/SYNTHETIC|DO-NOT-RETURN/,'receipt never contains secrets');
    $f->{panel}{requests}=[];($ok,$result)=run($f,[item()]);ok($ok,'idempotent retry succeeds');is_deeply($f->{panel}->writes,[],'no changed content means no PATCH/sync');
};
subtest 'partial publication requires current pending sources before any sync' => sub {
    my $f=fixture();$f->{panel}{fail}='PATCH:Routing Users';my ($ok,$result)=run($f,[item()]);
    ok(!$ok,'second PATCH failed');is($result->{items}{101}{error},'REMOTE_HTTP','fixed error');ok($f->{state}{pending},'recovery journal retained');
    $f->{panel}{requests}=[];($ok,$result)=run($f,[item(102)]);
    ok(!$ok,'missing fresh callback fails closed');is($result->{items}{102}{error},'PENDING_SOURCE_UNAVAILABLE','fixed missing source error');is_deeply($f->{panel}->writes,[],'no mixed-state publication');
    ($ok,$result)=run($f,[item(102)],current_items=>fresh(item(),item(102)));
    ok($ok,'repair and next user merge');is_deeply([sort keys %{$result->{items}}],[102],'receipt contains current request IDs only');
    is(scalar @{owned($f->{panel}{rows}{'Routing Users'},101,1)},2,'pending user repaired');is(syncs($f),1,'one combined sync');
};
subtest 'BLOCK from a later task restores original baseline, never stale enable' => sub {
    for my $prior (0,1) {
        my $f=fixture();run($f,[item()]) if $prior;my $before=clone($f->{panel}{rows});
        $f->{panel}{fail}='PATCH:Routing Users';run($f,[item(101,data=>{rules=>['new.example']},secret=>{outbound=>outbound('NEW-SECRET')})]);
        $f->{panel}{requests}=[];my ($ok,$result)=run($f,[item(102)],current_items=>fresh(item(101,service_status=>'BLOCK',secret=>{}),item(102)));
        ok($ok,'blocked pending repaired');
        for my $name ('Out Users','Routing Users') {is_deeply(owned($f->{panel}{rows}{$name},101,$name eq 'Routing Users'),owned($before->{$name},101,$name eq 'Routing Users'),'published baseline restored')}
        is(syncs($f),1,'only final consistent state synchronized');unlike($JSON->encode($f->{panel}{rows}),qr/NEW-SECRET/,'new draft not published while BLOCK');
    }
};
subtest 'stop/remove overrides pending and cleans absent panel account' => sub {
    for my $remove (0,1) {
        my $f=fixture();$f->{panel}{fail}='PATCH:Routing Users';run($f,[item()]);$f->{panel}{missing}{101}=1;$f->{panel}{requests}=[];
        my $stop=item(101,enabled=>JSON::PP::false,service_status=>$remove?'REMOVED':'BLOCK',secret=>{});
        my ($ok,$result)=run($f,[$stop],current_items=>fresh($stop));ok($ok,'cleanup accepted');is($result->{items}{101}{state},$remove?'cleaned':'disabled','correct lifecycle receipt');
        is_deeply(owned($f->{panel}{rows}{'Out Users'},101,0),[],'owned outbound removed');is_deeply(owned($f->{panel}{rows}{'Routing Users'},101,1),[],'owned routing removed');is(syncs($f),1,'one cleanup sync');
    }
};
subtest 'trusted bulk cleanup does not remove unrelated pending users' => sub {
    my $f=fixture();$f->{panel}{fail}='PATCH:Routing Users';run($f,[item()]);
    my ($ok,$result)=run($f,[item(102)],payload=>{feature=>'routing',cleanup=>JSON::PP::true,items=>[item(102)]},current_items=>fresh(item(),item(102)));
    ok($ok,'bulk cleanup and recovery complete together');is($result->{items}{102}{state},'cleaned','only requested cleanup ID acknowledged');
    is(scalar @{owned($f->{panel}{rows}{'Routing Users'},101,1)},2,'unrelated active pending user stays active');is_deeply(owned($f->{panel}{rows}{'Routing Users'},102,1),[],'requested item cleaned');
};
subtest 'permanent invalid draft preserves validated pending and other users proceed' => sub {
    my $f=fixture();$f->{panel}{fail}='PATCH:Routing Users';run($f,[item()]);
    my $bad=item();$bad->{secret}{outbound}{tag}='INJECTED';my ($ok,$result)=run($f,[$bad,item(102)],current_items=>fresh($bad,item(102)));
    ok($ok,'per-user validation is terminal, not transport retry');is($result->{items}{101}{state},'error','invalid draft marked error');is($result->{items}{102}{state},'submitted','other user succeeds');is(scalar @{owned($f->{panel}{rows}{'Routing Users'},101,1)},2,'old validated pending completed');
};
subtest 'sync timeout retains state and retry does not duplicate PATCH' => sub {
    my $f=fixture();$f->{panel}{fail}='POST:Out Users';my ($ok)=run($f,[item()]);ok(!$ok,'sync failed');$f->{panel}{requests}=[];
    ($ok)=run($f,[item()],current_items=>fresh(item()));ok($ok,'retry accepted');is(scalar @{$f->{panel}->writes},1,'only sync needed');is(syncs($f),1,'retry may repeat accepted sync');
};
subtest 'combined journal capacity is checked before replacing recoverable state' => sub {
    my $f=fixture();run($f,[]);my $scope=$f->{scopes}[0];
    $f->{state}{pending}={scope=>$scope,operations=>[map {{usi=>0+$_,outbound=>undef,rules=>[],before=>{outbounds=>[],rules=>[]}}} 101..600]};
    my $before=clone($f->{state}{pending});my @fresh=map {item($_,enabled=>JSON::PP::false)} 101..600;
    my ($ok,$result)=run($f,[item(601)],current_items=>fresh(@fresh,item(601)));
    ok(!$ok,'501 combined operations rejected');is($result->{items}{601}{error},'PENDING_LIMIT','fixed capacity error');
    is_deeply($f->{state}{pending},$before,'original 500-operation pending is unchanged');
    is($f->{state}{saves}//0,0,'oversized journal never written');is_deeply($f->{panel}->writes,[],'no PATCH or sync before capacity failure');
    ($ok,$result)=run($f,[$fresh[0]],current_items=>fresh(@fresh));
    ok($ok,'original journal can still be loaded and completed');is($result->{items}{101}{state},'disabled','old ID remains recoverable');
    ok(!$f->{state}{pending},'journal cleared only after bounded recovery');
};
subtest 'safe nonempty final placeholders and no rule for empty group' => sub {
    my $f=fixture();$f->{panel}{rows}{'Out Users'}=[];$f->{panel}{rows}{'Routing Users'}=[];run($f,[item()]);my $stop=item(101,service_status=>'REMOVED');my ($ok)=run($f,[$stop]);ok($ok,'last user cleaned');
    my $rule=$f->{panel}{rows}{'Routing Users'}[0];like($rule->{user}[0],qr/^__shm_no_numeric_user_/,'placeholder can never match numeric panel user');ok(@{$f->{panel}{rows}{'Out Users'}},'outbound snippet stays nonempty');
    ($ok)=run($f,[item(102,data=>{rules=>[]})]);ok($ok,'empty rule list valid');is_deeply(owned($f->{panel}{rows}{'Routing Users'},102,1),[],'empty groups cannot become catchall');
};
subtest 'profile layouts are administrator-owned and never requested' => sub {
    for my $mutate (
        sub {$_[0]{panel}{profiles}[0]{config}{outbounds}=[{snippet=>'Out Users'}]},
        sub {unshift @{$_[0]{panel}{profiles}[0]{config}{outbounds}},{snippet=>'Out Users'}},
        sub {delete $_[0]{panel}{profiles}[0]{config}{outbounds}[0]{tag}},
        sub {unshift @{$_[0]{panel}{profiles}[0]{config}{routing}{rules}},{type=>'field',network=>'tcp',outboundTag=>'direct'}},
        sub {unshift @{$_[0]{panel}{profiles}[0]{config}{routing}{rules}},{type=>'field',network=>'udp',outboundTag=>'direct'}},
        sub {unshift @{$_[0]{panel}{profiles}[0]{config}{routing}{rules}},{type=>'field',network=>'tcp,udp',port=>'1-65535',outboundTag=>'direct'}},
        sub {push @{$_[0]{panel}{profiles}[0]{config}{routing}{rules}},{type=>'field',ip=>['geoip:private'],outboundTag=>'block'}},
        sub {$_[0]{panel}{profiles}[0]{config}{routing}{rules}=[{snippet=>'Not Installed Here'}]},
        sub {$_[0]{panel}{profiles}=[]},
        sub {$_[0]{panel}{profiles}=[undef,'not-a-profile',{uuid=>'unrelated',config=>{snippets=>['Out Users']}}]},
    ) {
        my $f=fixture();$mutate->($f);my $profiles=clone($f->{panel}{profiles});my ($ok,$result)=run($f,[item()]);
        ok($ok,'preset order, default and references do not block snippet publication');
        is($result->{items}{101}{state},'submitted','receipt represents snippet acceptance only');
        is_deeply($f->{panel}{profiles},$profiles,'administrator Profile bytes remain unchanged');
        is(scalar(grep {$_->[1]=~m{\A/api/config-profiles(?:/|\z)}} @{$f->{panel}{requests}}),0,'no Profile request');
        is_deeply([map {[$_->[0],$_->[1],$_->[2]{name}]} @{$f->{panel}->writes}],[['PATCH','/api/snippets','Out Users'],['PATCH','/api/snippets','Routing Users'],['POST','/api/snippets/actions/sync','Out Users']],'only fixed snippets and sync are written');
    }
};
subtest 'fixed snippet publisher preserves platform fragments and other owners' => sub {
    my $f=platform_preset(fixture());run($f,[]);my $scope=$f->{scopes}[0];
    my $foreign=outbound('OTHER-OWNER-SECRET');$foreign->{tag}="SHM_ROUTING_${scope}_us_909_out";
    push @{$f->{panel}{rows}{'Out Users'}},$foreign;
    my $foreign_rule={type=>'field',ruleTag=>"SHM_ROUTING_${scope}_us_909_domain",user=>['1909'],domain=>['domain:other.test'],outboundTag=>$foreign->{tag}};
    push @{$f->{panel}{rows}{'Routing Users'}},$foreign_rule;
    my $before=clone($f->{panel}{rows});my $profiles=clone($f->{panel}{profiles});my ($ok,$result)=run($f,[item()]);
    ok($ok,'existing platform presets do not block managed snippet publication');is($result->{items}{101}{state},'submitted','snippet publication accepted');
    is_deeply($f->{panel}{profiles},$profiles,'raw profile layout remains unchanged');
    for my $name (grep {$_ ne 'Out Users' && $_ ne 'Routing Users'} keys %$before) {is_deeply($f->{panel}{rows}{$name},$before->{$name},'platform snippet preserved')}
    is_deeply(owned($f->{panel}{rows}{'Out Users'},909,0),[$foreign],'other owner outbound preserved exactly');
    is_deeply(owned($f->{panel}{rows}{'Routing Users'},909,1),[$foreign_rule],'other owner route preserved exactly');
    is_deeply([map {[$_->[0],$_->[1],$_->[2]{name}]} @{$f->{panel}->writes}],[['PATCH','/api/snippets','Out Users'],['PATCH','/api/snippets','Routing Users'],['POST','/api/snippets/actions/sync','Out Users']],'only the managed snippets are written and synchronized');
};
subtest 'unrelated snippet content and duplicate platform names are ignored' => sub {
    my $f=platform_preset(fixture());
    delete $f->{panel}{rows}{'Out Direct'};
    $f->{panel}{rows}{'Out Nodes'}=undef;
    $f->{panel}{rows}{'Out VPN'}='not-an-array';
    $f->{panel}{rows}{'Routing Direct'}=[{snippet=>'Nested Platform Reference'}];
    $f->{panel}{extra_snippet_rows}=[undef,'unrelated-row',{}, {name=>[]},
        {name=>'Out Nodes',snippet=>{snippet=>'Another Platform Reference'}},
        {name=>'Out Nodes'}, {name=>'Unrelated',snippet=>1}, {name=>'Unrelated',snippet=>2}];
    my $before=clone($f->{panel}{rows});my $extra=clone($f->{panel}{extra_snippet_rows});
    my ($ok,$result)=run($f,[item()]);ok($ok,'publisher does not interpret other fragments');
    is($result->{items}{101}{state},'submitted','unrelated shapes cannot reject a valid target pair');
    for my $name (grep {$_ ne 'Out Users' && $_ ne 'Routing Users'} keys %$before) {is_deeply($f->{panel}{rows}{$name},$before->{$name},'other fragment unchanged')}
    is_deeply($f->{panel}{extra_snippet_rows},$extra,'duplicate and malformed unrelated rows unchanged');
    is(scalar @{$f->{panel}->writes},3,'two target PATCH operations and one sync');
};
subtest 'the two fixed snippet targets must exist uniquely as arrays' => sub {
    for my $case (
        ['SNIPPETS_NOT_READY',sub {delete $_[0]{panel}{rows}{'Out Users'}}],
        ['SNIPPETS_NOT_READY',sub {delete $_[0]{panel}{rows}{'Routing Users'}}],
        ['REMOTE_RESPONSE',sub {$_[0]{panel}{rows}{'Out Users'}={}}],
        ['REMOTE_RESPONSE',sub {$_[0]{panel}{rows}{'Routing Users'}='not-an-array'}],
        ['REMOTE_RESPONSE',sub {$_[0]{panel}{rows}{'Out Users'}=undef}],
        ['REMOTE_RESPONSE',sub {$_[0]{panel}{rows}{'Routing Users'}=0}],
        ['REMOTE_RESPONSE',sub {$_[0]{panel}{extra_snippet_rows}=[{name=>'Out Users',snippet=>[]}]}],
        ['REMOTE_RESPONSE',sub {$_[0]{panel}{extra_snippet_rows}=[{name=>'Routing Users',snippet=>[]}]}],
    ) {
        my $f=fixture();$case->[1]->($f);my $before=clone($f->{panel}{rows});my ($ok,$result)=run($f,[item()]);
        ok(!$ok,'missing, duplicate or non-array managed target rejected');
        is($result->{items}{101}{error},$case->[0],'fixed target error');
        is_deeply($f->{panel}->writes,[],'invalid target pair causes no PATCH or sync');
        is_deeply($f->{panel}{rows},$before,'no existing snippet changed');
        ok(!$f->{state}{pending},'no recovery record saved for an invalid target pair');
    }
};
subtest 'the snippet endpoint retains finite response bounds' => sub {
    my $f=fixture();$f->{panel}{extra_snippet_rows}=[map {{name=>'unused-'.$_,snippet=>[]}} 1..10_001];
    my ($ok,$result)=run($f,[item()]);ok(!$ok,'oversized snippet count rejected');is($result->{items}{101}{error},'REMOTE_RESPONSE','fixed bounded response error');is_deeply($f->{panel}->writes,[],'no writes for oversized endpoint response');
    $f=fixture();$f->{panel}{rows}{'Unrelated Large Fragment'}='X' x (16*1024*1024);
    ($ok,$result)=run($f,[item()]);ok(!$ok,'oversized response body rejected without interpreting other fragments');is($result->{items}{101}{error},'REMOTE_RESPONSE','fixed response-size error');is_deeply($f->{panel}->writes,[],'no writes for oversized response body');
};
subtest 'private/mapped/management addresses and all DNS answers fail closed' => sub {
    for my $address (qw(127.0.0.1 10.1.2.3 100.64.0.1 169.254.169.254 192.0.2.1 ::1 fc00::1 fe80::1 ::ffff:9.9.9.9 9.9.9.9)) {
        my $f=fixture();my $value=item();$value->{secret}{outbound}{settings}{servers}[0]{address}=$address;my ($ok,$result)=run($f,[$value]);ok($ok,'invalid endpoint local to user');is($result->{items}{101}{error},'ENDPOINT_DENIED',"address $address denied");is_deeply($f->{panel}->writes,[],'no writes');
    }
    my $f=fixture();$f->{settings}{remnawave}{api}='https://[::ffff:8.8.8.8]';my ($ok,$result)=run($f,[item()]);is($result->{items}{101}{error},'ENDPOINT_DENIED','mapped panel management address protected');
    $f=fixture();$f->{adapter}{resolver}=sub {die 'DNS before lock' unless $f->{state}{held};return ['8.8.8.8','10.0.0.1']};my $value=item();$value->{secret}{outbound}{settings}{servers}[0]{address}='provider.example';($ok,$result)=run($f,[$value]);is($result->{items}{101}{error},'ENDPOINT_DENIED','one unsafe DNS answer rejects all');
    $f->{adapter}{resolver}=sub {['8.8.8.8','1.1.1.1']};($ok,$result)=run($f,[$value]);ok($ok,'all public DNS accepted');is(owned($f->{panel}{rows}{'Out Users'},101,0)->[0]{settings}{servers}[0]{address},'1.1.1.1','deterministic numeric pin');
};
subtest 'geo recovery and BLOCK need no runtime catalog' => sub {
    for my $restore (0,1) {
        my $f=fixture();my $geo=item(101,data=>{rules=>['GEOSITE:Operator-Provided']});run($f,[$geo]) if $restore;my $before=clone($f->{panel}{rows});
        $f->{panel}{fail}='PATCH:Routing Users';my $draft=$restore?item(101,data=>{rules=>['new.example']},secret=>{outbound=>outbound('NEW')}):$geo;run($f,[$draft]);
        $f->{panel}{requests}=[];my $next=$restore?item(101,service_status=>'BLOCK'):$geo;my ($ok,$result)=run($f,[$next],current_items=>fresh($next));
        ok($ok,'format-valid geo recovery accepted without resource lookup');is($result->{items}{101}{state},$restore?'waiting_service':'submitted','lifecycle state retained');
        if ($restore) {is_deeply($f->{panel}{rows},$before,'BLOCK restores the geo baseline')}
        else {is_deeply(owned($f->{panel}{rows}{'Routing Users'},101,1)->[0]{domain},['geosite:operator-provided'],'recovered geo normalized')}
        ok(!$f->{state}{pending},'recovery journal cleared after consistent sync');is(syncs($f),1,'one final sync');
    }
};
subtest 'SS/WG/SOCKS whitelist, keys, limits and numeric types' => sub {
    my $adapter=Core::Integrations::Remnawave->new;
    for my $method (qw(aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305)) {
        my $psk=encode_base64('K' x ($method=~/aes-128/?16:32),'');my $value=outbound($method=~/^2022/?$psk:'TEST');$value->{settings}{servers}[0]{method}=$method;ok(eval {$adapter->normalize_outbound($value);1},"$method accepted");
        if ($method=~/^2022/) {$value->{settings}{servers}[0]{password}="$psk:$psk";is(!!eval {$adapter->normalize_outbound($value);1},$method=~/chacha/?'':1,'only AES2022 accepts PSK chains')}
    }
    my $key=encode_base64('K' x 32,'');my $wg={protocol=>'wireguard',settings=>{secretKey=>$key,address=>[map {"10.2.0.$_/24"} 1..8],mtu=>1420,peers=>[{publicKey=>$key,preSharedKey=>$key,endpoint=>'[2606:4700:4700::1111]:51820',allowedIPs=>['0.0.0.0/0','1.1.1.1','::/0'],keepAlive=>25}]}};
    my $normal=$adapter->normalize_outbound($wg);is($normal->{settings}{address}[0],'10.2.0.1/24','interface preserves host bits');is($normal->{settings}{peers}[0]{allowedIPs}[1],'1.1.1.1/32','bare allowed IP normalized');
    for my $mutate (sub {$_[0]{tag}='bad'},sub {$_[0]{settings}{reserved}=[1,2,3]},sub {$_[0]{settings}{peers}[0]{email}='other'},sub {push @{$_[0]{settings}{address}},'10.3.0.1/32'},sub {$_[0]{settings}{mtu}=1420.5},sub {$_[0]{settings}{peers}[0]{allowedIPs}=[('1.1.1.1/32') x 65]}) {my $bad=clone($wg);$mutate->($bad);ok(!eval {$adapter->normalize_outbound($bad);1},'unknown or malformed WG values rejected')}
    for my $port ('443',443.5,JSON::PP::true,0,65536) {my $bad=outbound();$bad->{settings}{servers}[0]{port}=$port;ok(!eval {$adapter->normalize_outbound($bad);1},'port must be a real JSON integer in range')}
    my $socks={protocol=>'socks',settings=>{servers=>[{address=>'8.8.8.8',port=>1080,users=>[{user=>'account',pass=>'SECRET'}]}]}};is_deeply($adapter->normalize_outbound($socks),$socks,'canonical SOCKS servers accepted');$socks->{settings}{servers}[0]{users}[0]{level}=10;ok(!eval {$adapter->normalize_outbound($socks);1},'SOCKS machine-field injection rejected');
};
subtest 'WireGuard remote DNS stays inside the canonical per-user outbound' => sub {
    my $key=encode_base64('K' x 32,'');
    my $wg={protocol=>'wireguard',settings=>{secretKey=>$key,address=>['10.64.0.2/32','fd00::2/128'],
        remoteDNS=>['10.64.0.1','FD00:0:0:0:0:0:0:53','10.64.0.1'],
        peers=>[{publicKey=>$key,endpoint=>'8.8.4.4:51820',allowedIPs=>['0.0.0.0/0','::/0']}]}};
    my $adapter=Core::Integrations::Remnawave->new;
    my $normal=$adapter->normalize_outbound($wg);
    is_deeply($normal->{settings}{remoteDNS},['10.64.0.1','fd00::53','10.64.0.1'],'private IPv4/IPv6 DNS is normalized without removing duplicates or changing order');
    is($wg->{settings}{remoteDNS}[1],'FD00:0:0:0:0:0:0:53','normalization does not modify provider input');
    my $eight=clone($wg);$eight->{settings}{remoteDNS}=[('10.64.0.1') x 8];
    is(scalar @{$adapter->normalize_outbound($eight)->{settings}{remoteDNS}},8,'eight DNS servers are accepted');
    for my $dns (undef,{},'1.1.1.1',[],[('1.1.1.1') x 9],[undef],[1],[JSON::PP::true],[''],['dns.example'],
        ['https://1.1.1.1/dns-query'],['1.1.1.1/32'],['1.1.1.1:53'],['[fd00::53]:53'],['fe80::53%eth0'],[' 1.1.1.1'],['1.1.1.1 '],['010.0.0.1'],['256.1.1.1']) {
        my $bad=clone($wg);$bad->{settings}{remoteDNS}=$dns;
        my $accepted=eval {$adapter->normalize_outbound($bad);1};my $error=$@;
        ok(!$accepted,'non-IP, unbounded or malformed remote DNS is refused');
        is(Core::Integrations::Remnawave::_code($error),'INVALID_OUTBOUND','DNS validation uses a fixed existing input error');
    }
    my $f=fixture();my $value=item(101,data=>{rules=>['example.test']},secret=>{outbound=>$wg});
    my ($ok,$result)=run($f,[$value]);is($result->{items}{101}{state},'submitted','provider private DNS does not inherit the outer endpoint public-IP restriction');
    my $published=owned($f->{panel}{rows}{'Out Users'},101,0)->[0];
    is_deeply($published->{settings}{remoteDNS},$normal->{settings}{remoteDNS},'compiled snippet retains the normalized DNS list');
    is_deeply($published->{settings}{peers}[0]{allowedIPs},['0.0.0.0/0','::/0'],'DNS import does not rewrite peer routes');
    ok($published->{settings}{noKernelTun},'WireGuard remains in its private userspace network stack');
    my $without=clone($wg);delete $without->{settings}{remoteDNS};
    $f=fixture();($ok,$result)=run($f,[item(101,data=>{rules=>[]},secret=>{outbound=>$without})]);
    ok(!exists(owned($f->{panel}{rows}{'Out Users'},101,0)->[0]{settings}{remoteDNS}),'omitting DNS does not inject an application default');
    my $private_peer=clone($wg);$private_peer->{settings}{peers}[0]{endpoint}='10.64.0.1:51820';
    $f=fixture();($ok,$result)=run($f,[item(101,data=>{rules=>[]},secret=>{outbound=>$private_peer})]);
    is($result->{items}{101}{error},'ENDPOINT_DENIED','the outer WireGuard peer must still be public');
};
subtest 'strict boolean, identity, JSON and receipt errors are sanitized' => sub {
    for my $switch (0,1,'true','false',{},[]) {my $f=fixture();my ($ok,$result)=run($f,[item(101,enabled=>$switch)]);ok($ok,'bad bool is permanent user error');is($result->{items}{101}{state},'error','only native JSON boolean accepted')}
    for my $id (1101.5,JSON::PP::true,'1101') {my $f=fixture();$f->{panel}{numeric}=$id;my ($ok,$result)=run($f,[item()]);ok(!$ok,'invalid panel identity retry failure');is($result->{items}{101}{error},'USER_MAPPING','never coerce a real/string ID')}
    for my $raw ('{"response":{"id":1,"id":2}}','{"response":{"id":1,"\\u0069d":2}}','{"response":NaN}') {my $f=fixture();$f->{panel}{raw}=$raw;my ($ok,$result)=run($f,[item()]);ok(!$ok,'malformed/duplicate response rejected');is($result->{items}{101}{error},'REMOTE_RESPONSE','raw JSON not exposed')}
    my $f=fixture();my ($ok,$result)=run($f,[]);ok($ok,'empty payload is a safe no-op');is_deeply($result,{items=>{}},'empty receipt explicit');is_deeply($f->{panel}{requests},[],'empty no pending makes no HTTP requests');
};
subtest 'expiry uses wall time and scope identifies one fixed remote resource' => sub {
    local $ENV{TZ}='Asia/Shanghai';
    my $f=fixture();my ($ok,$result)=run($f,[item(101,expire=>'2023-11-15 06:13:20')]);is($result->{items}{101}{state},'waiting_service','Shanghai wall time equals injected epoch');
    ($ok,$result)=run($f,[item(101,expire=>'2023-11-15T06:13:21+08:00')]);is($result->{items}{101}{state},'submitted','one second ahead stays active');
    ($ok,$result)=run($f,[item(101,expire=>'2026-02-30 00:00:00')]);is($result->{items}{101}{error},'INVALID_SERVICE','invalid calendar day rejected');
    is($f->{scopes}[0],substr(Digest::SHA::sha256_hex('["https://9.9.9.9","Out Users","Routing Users"]'),0,20),'scope algorithm remains compatible');
};
subtest 'minimal metadata and fixed configuration need no routing object' => sub {
    my $f=fixture();is_deeply($f->{adapter}->metadata,{feature=>'routing',requires_secret=>1},'adapter declares feature and secret requirement');
    delete $f->{settings}{remnawave}{routing};
    $f->{settings}{remnawave}{request_timeout}=1;$f->{settings}{remnawave}{shm_tz}='America/Los_Angeles';
    $f->{settings}{remnawave}{state_dir}='/unused-lifecycle-state';
    my $original=clone($f->{settings});my ($ok,$result)=run($f,[item()]);ok($ok,'api/token alone configure routing');
    is($result->{items}{101}{state},'submitted','minimal settings publish');
    is_deeply($f->{settings},$original,'lifecycle settings are neither altered nor removed');
    is_deeply([map {$_->[3]{timeout}} @{$f->{panel}{requests}}],[(30) x @{$f->{panel}{requests}}],'native request limit is fixed despite lifecycle override');
    is_deeply([map {$_->[2]{name}} grep {$_->[0] eq 'PATCH'} @{$f->{panel}{requests}}],['Out Users','Routing Users'],'snippet names are fixed');
};
subtest 'public outbound is an optional safe summary, never publication input' => sub {
    my $f=fixture();my $value=item();
    $value->{data}{outbound}={protocol=>'socks',server=>'8.8.4.4',port=>1080};
    my ($ok,$result)=run($f,[$value]);
    is($result->{items}{101}{state},'submitted','safe summary is accepted');
    my ($published)=grep {($_->{tag}//'') =~ /us_101_out\z/} @{$f->{panel}{rows}{'Out Users'}};
    is($published->{protocol},'shadowsocks','publisher reads the canonical encrypted-secret object, not the summary protocol');
    is($published->{settings}{servers}[0]{address},'8.8.8.8','summary cannot change the actual endpoint');
    $f=fixture();$value=item();delete $value->{data}{outbound};
    ($ok,$result)=run($f,[$value]);is($result->{items}{101}{state},'submitted','public summary may be omitted');
    for my $data ({rules=>['example.test'],outbound_summary=>{}},
        {rules=>['example.test'],outbound=>{protocol=>'socks',server=>'8.8.8.8',port=>1080,password=>'private'}},
        {rules=>['example.test'],outbound=>{protocol=>'socks',server=>'owner:private@example.test',port=>1080}}) {
        $f=fixture();($ok,$result)=run($f,[item(101,data=>$data)]);
        like($result->{items}{101}{error},qr/\AINVALID_(?:CONFIG|OUTBOUND)\z/,'old or unsafe public fields fail explicitly');
        is_deeply($f->{panel}->writes,[],'invalid public data never updates snippets');
    }
};
subtest 'any routing configuration is explicitly rejected' => sub {
    for my $routing ({},undef,[],1,{deny=>[]},{geo=>[]},{deny=>['8.8.8.8'],geo=>['geosite:youtube']},{outbound_snippet=>'Out Users'},{routing_snippet=>'Routing Users'},{state_dir=>'/unused'},{management_hosts=>[]},{deny_cidrs=>[]},{allowed_geosite=>[]},{allowed_geoip=>[]}) {
        my $f=fixture();$f->{settings}{remnawave}{routing}=$routing;my ($ok,$result)=run($f,[item()]);
        ok(!$ok,'routing field rejected instead of silently dropping policy');is($result->{items}{101}{error},'INVALID_ROUTING_CONFIG','fixed setting error');
        is(scalar @{$f->{scopes}},0,'invalid settings acquire no state');is_deeply($f->{panel}{requests},[],'no HTTP for invalid settings');
    }
};
subtest 'automatic panel denial protects every resolved address' => sub {
    my $f=fixture();$f->{settings}{remnawave}{api}='https://panel.example';
    $f->{adapter}{resolver}=sub {die 'DNS before scope lock' unless $f->{state}{held};die 'unexpected synthetic DNS' unless $_[0] eq 'panel.example';return ['8.8.8.8','::ffff:8.8.8.4']};
    for my $address ('8.8.8.8','8.8.8.4','::ffff:8.8.8.8') {
        my $value=item();$value->{secret}{outbound}{settings}{servers}[0]{address}=$address;my ($ok,$result)=run($f,[$value]);
        ok($ok,'denied endpoint is a local input error');is($result->{items}{101}{error},'ENDPOINT_DENIED','all panel addresses remain protected');
    }
    is_deeply($f->{panel}->writes,[],'no panel endpoint published');
};
subtest 'geo checks grammar and limits, not node resource availability' => sub {
    my $f=fixture();my $value=item(101,data=>{rules=>['GEOSITE:Operator-Provided','GEOIP:CN','geosite:operator-provided']});my ($ok,$result)=run($f,[$value]);
    ok($ok,'syntax-valid labels accepted without a catalog');is($result->{items}{101}{state},'submitted','unknown-to-adapter labels can be supplied by node resources');
    my $rules=owned($f->{panel}{rows}{'Routing Users'},101,1);is_deeply($rules->[0]{domain},['geosite:operator-provided'],'geosite normalized and deduplicated');is_deeply($rules->[1]{ip},['geoip:cn'],'geoip normalized');
    for my $raw ('geosite:','geoip:cn/other','geosite:tag@one@two','geosite:İ','geosite:K','ext:geoip.dat:cn','regexp:.*') {
        my $invalid=fixture();my ($accepted,$receipt)=run($invalid,[item(101,data=>{rules=>[$raw]})]);ok($accepted,'invalid format is a per-user permanent error');is($receipt->{items}{101}{state},'error','unsupported geo/routing syntax rejected');is_deeply($invalid->{panel}->writes,[],'bad syntax never changes snippets');
    }
    my $invalid=fixture();my ($accepted,$receipt)=run($invalid,[item(101,data=>{rules=>[('geoip:cn') x 201]})]);is($receipt->{items}{101}{error},'INVALID_RULES','rule count limit retained');
    ($accepted,$receipt)=run($invalid,[item(101,data=>{rules=>['geosite:'.('a' x 254)]})]);is($receipt->{items}{101}{state},'error','rule byte limit retained');
};
subtest 'expiry follows existing TZ and ignores lifecycle timezone options' => sub {
    my $f=fixture();$f->{settings}{remnawave}{shm_tz}='America/Los_Angeles';
    {local $ENV{TZ}='UTC';my ($ok,$result)=run($f,[item(101,expire=>'2023-11-15 06:13:20')]);is($result->{items}{101}{state},'submitted','UTC environment interprets the wall time as future')}
    {local $ENV{TZ}='';my ($ok,$result)=run($f,[item(101,expire=>'2023-11-15 06:13:20')]);is($result->{items}{101}{state},'waiting_service','blank environment falls back to Shanghai')}
};
subtest 'the total timeout is rethrown after closing state, not converted into a draft error' => sub {
    my $f=fixture();$f->{adapter}{http}=sub {die "SERVICE_OPTIONS_TIMEOUT\n"};
    my $ok=eval {run($f,[item(),item(102)]);1};ok(!$ok,'controller timeout escapes adapter');is($@,"SERVICE_OPTIONS_TIMEOUT\n",'fixed timeout retained');ok(!$f->{state}{held},'scope state closed before unwind');
    $f=fixture();my ($accepted,$result)=$f->{adapter}->apply(payload=>{feature=>'routing',items=>[item()]},settings=>$f->{settings},state_factory=>sub {die "SERVICE_OPTIONS_KEY_MISSING\n"});
    ok(!$accepted,'missing master key fails');is($result->{items}{101}{error},'SERVICE_OPTIONS_KEY_MISSING','only allowlisted safe state error preserved');
};
subtest 'Unicode and mapped IPv6 normalize canonically' => sub {
    plan skip_all=>'official runtime supplies Net::IDN::Encode' unless eval {require Net::IDN::Encode;1};
    my $adapter=Core::Integrations::Remnawave->new;
    my ($domains,$ips)=$adapter->normalize_rules(['例子.中国','müller.de','faß.de','::ffff:8.8.8.8','::ffff:8.8.8.8/120']);
    is_deeply($domains,['domain:xn--fsqu00a.xn--fiqs8s','domain:xn--mller-kva.de','domain:xn--fa-hia.de'],'UTS46 raw Unicode uses nontransitional canonical labels');
    is_deeply($ips,['::ffff:8.8.8.8','::ffff:8.8.8.0/120'],'mapped IPv6 canonical form is stable');
    my $f=fixture();$f->{settings}{remnawave}{api}='https://例子.中国';
    $f->{adapter}{resolver}=sub {is($_[0],'xn--fsqu00a.xn--fiqs8s','panel IDN resolves canonical label');return ['8.8.8.8']};
    my ($ok,$result)=run($f,[item()]);is($result->{items}{101}{error},'ENDPOINT_DENIED','IDNA panel host protects resolved public management address');
};

done_testing();
