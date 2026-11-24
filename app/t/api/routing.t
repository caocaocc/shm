use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Digest::SHA qw(sha256_hex);
use HTTP::Request;
use JSON::PP;
use LWP::UserAgent;

plan skip_all => 'Uses a disposable native_routing_test database and the real API'
    unless ($ENV{DB_NAME} // '') eq 'native_routing_test' && $ENV{ROUTING_NATIVE_HTTP_TEST};

my $db = DBI->connect("DBI:mysql:database=$ENV{DB_NAME};host=$ENV{DB_HOST}", $ENV{DB_USER},
    $ENV{DB_PASS}, {RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1});
my $ua = LWP::UserAgent->new(timeout => 10, max_redirect => 0);
my $json = JSON::PP->new->utf8;
my $url = 'http://api/shm/v1/user/service';
my ($owner, $other, $id, $foreign, $plan, $node);
my %cookie;
for my $login (qw(owner other)) {
    $db->do(q{INSERT INTO users (login,gid,balance,bonus,credit) VALUES (?,2,0,0,0)}, undef, "routing-$login-$$");
    my $uid = $db->{mysql_insertid};
    $cookie{$uid} = sha256_hex(rand() . ":$uid:$$");
    $db->do('INSERT INTO sessions (id,user_id,settings) VALUES (?,?,JSON_OBJECT())', undef,
        sha256_hex($cookie{$uid}), $uid);
    if ($login eq 'owner') { $owner = $uid } else { $other = $uid }
}
$db->do(q{INSERT INTO servers (name,transport,host,settings) VALUES ('fixture','local','localhost',?)},
    undef, $json->encode({remnawave=>{api=>'http://127.0.0.1:19582', token=>'test-only'}}));
$node = $db->{mysql_insertid};
$db->do(q{INSERT INTO services (name,cost,category) VALUES ('routing test',1,'vpn-shared')});
$plan = $db->{mysql_insertid};
for my $uid ($owner,$other) {
    $db->do(q{INSERT INTO user_services (user_id,service_id,status_before,status,settings)
        VALUES (?,?,'ACTIVE','ACTIVE',JSON_OBJECT('server_id',?))}, undef, $uid,$plan,$node);
    if ($uid == $owner) { $id = $db->{mysql_insertid} } else { $foreign = $db->{mysql_insertid} }
}

sub call_api {
    my ($uid,$method,$path,$data,%headers) = @_;
    my $req = HTTP::Request->new($method => $url . $path);
    $req->header(Cookie => "session_id=$cookie{$uid}") if $uid;
    if (defined $data) {
        $req->content($json->encode($data));
        $req->header('Content-Type' => 'application/json');
    }
    $req->header($_ => $headers{$_}) for keys %headers;
    return $ua->request($req);
}
sub record {
    my ($response) = @_;
    is($response->code,200,'HTTP success') or diag('HTTP '.$response->code);
    my $body = $json->decode($response->content);
    return $body->{data}[0] // {};
}
my $read = "/routing?user_service_id=$id";
ok(record(call_api($owner,'GET',"?user_service_id=$id"))->{routing_available}, 'eligible service advertised');
my $initial = call_api($owner,'GET',$read);
is(record($initial)->{status}, 'unconfigured', 'fresh install needs no template');
is($initial->header('Cache-Control'),'private, no-store','owner response cannot be cached');
ok(!$initial->header('Access-Control-Allow-Origin'),'no reflected CORS');
is(call_api(undef,'GET',$read)->code,401,'session required');
is(call_api($other,'GET',$read)->code,404,'another owner cannot read');
is(call_api($owner,'GET',"/routing?user_service_id=$foreign")->code,404,'other service hidden');
is(call_api($owner,'GET',$read,undef,Origin=>'https://different.example')->code,403,'foreign origin rejected');
is(call_api($owner,'POST','/routing',{},'Content-Type'=>'text/plain')->code,400,'simple browser POST rejected');
is(call_api($owner,'POST','/routing?dry_run=1',{})->code,400,'POST query rejected');
is(call_api($owner,'GET',$read.'&format=html')->code,400,'only JSON response supported');

my $text = "服务器：8.8.8.8\r\n端口：1080\r\n用户名：测试\r\n密码：fixture-private-value\r\n";
my $save = {user_service_id=>$id, action=>'save', outbound_text=>$text, rules=>['example.org','geoip:cn']};
is(call_api($other,'POST','/routing',$save)->code,404,'another owner cannot write');
my $saved = record(call_api($owner,'POST','/routing',$save));
is($saved->{status},'queued','save commits before worker runs');
is_deeply($saved->{enabled},JSON::PP::true,'boolean retained');
is(record(call_api($owner,'GET',$read))->{outbound_text},$text,'original text survives a new request');
is_deeply(record(call_api($owner,'GET',$read))->{rules},$save->{rules},'rules survive reload');
ok(defined $saved->{publish_at},'scheduled time visible to owner');
my ($cipher) = $db->selectrow_array('SELECT data FROM storage WHERE user_id=0 AND name=?',undef,"routing:$id");
ok($cipher && index($cipher,'fixture-private-value') < 0,'only ciphertext stored');
my ($unredacted) = $db->selectrow_array(q{SELECT COUNT(*) FROM logs_api WHERE url='/user/service/routing'
    AND (args->>'$.redacted' IS NULL OR CAST(args AS CHAR) LIKE '%fixture-private-value%')});
is($unredacted,0,'audit payload redacted');

is_deeply(record(call_api($owner,'POST','/routing',{user_service_id=>$id,action=>'disable'}))->{enabled},
    JSON::PP::false,'disable keeps saved draft');
is(record(call_api($owner,'POST','/routing',{user_service_id=>$id,action=>'enable'}))->{outbound_text},
    $text,'enable reuses original exit');
$db->do(q{INSERT INTO config (`key`,value) VALUES ('routing',JSON_OBJECT('legacy_categories',JSON_ARRAY('other%')))
    ON DUPLICATE KEY UPDATE value=JSON_SET(value,'$.legacy_categories',JSON_ARRAY('other%'))});
ok(record(call_api($owner,'GET',"?user_service_id=$id"))->{routing_available},'old category filters do not gate a bound service');
is(record(call_api($owner,'GET',$read))->{outbound_text},$text,'owner retains access to the saved text');
$db->do(q{UPDATE user_services SET settings=JSON_REMOVE(settings,'$.server_id') WHERE user_service_id=?},undef,$id);
ok(!record(call_api($owner,'GET',"?user_service_id=$id"))->{routing_available},'active service without an assigned panel hides the tab');
is(call_api($owner,'POST','/routing',$save)->code,404,'unbound service cannot save');
$db->do(q{UPDATE user_services SET settings=JSON_SET(settings,'$.server_id',?) WHERE user_service_id=?},undef,$node,$id);
$db->do(q{UPDATE servers SET settings=JSON_REMOVE(settings,'$.remnawave.token') WHERE server_id=?},undef,$node);
ok(!record(call_api($owner,'GET',"?user_service_id=$id"))->{routing_available},'incomplete panel credentials hide the tab');
is(call_api($owner,'GET',$read)->code,404,'incomplete panel configuration cannot read the outlet');
$db->do(q{UPDATE servers SET settings=JSON_SET(settings,'$.remnawave.token','test-only') WHERE server_id=?},undef,$node);
$db->do(q{UPDATE user_services SET status='BLOCK' WHERE user_service_id=?},undef,$id);
ok(!record(call_api($owner,'GET',"?user_service_id=$id"))->{routing_available},'blocked service hides tab');
is(call_api($owner,'POST','/routing',$save)->code,404,'blocked service cannot enable');
my $withdrawn = record(call_api($owner,'POST','/routing',{user_service_id=>$id,action=>'disable'}));
is($withdrawn->{outbound_text}, '', 'owner can withdraw a blocked route without revealing credentials');
is_deeply($withdrawn->{rules}, [], 'withdrawal outside current scope returns no rules');
$db->do(q{UPDATE config SET value=JSON_REMOVE(value,'$.legacy_categories') WHERE `key`='routing'});
done_testing;
