use strict;
use warnings;
use utf8;
use Test::More;
BEGIN {
    plan skip_all => 'Requires the disposable routingtpl database and ROUTING_PANEL_TEST=1'
        unless ($ENV{DB_NAME} // '') eq 'routingtpl' && ($ENV{ROUTING_PANEL_TEST} // '') eq '1';
}
use DBI;
use Crypt::AuthEnc::GCM ();
use Crypt::PRNG ();
use MIME::Base64 qw(decode_base64 encode_base64);
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use HTTP::Daemon;
use HTTP::Request::Common qw(GET POST);
use HTTP::Response;
use JSON::PP qw(encode_json decode_json);
use LWP::UserAgent;
use POSIX ();
use Time::HiRes qw(usleep);

# Run only in a newly initialized, isolated SHM fixture. The mock is loopback
# only; the real CGI, worker and this test must share the core container.
my $dsn = "DBI:mysql:database=routingtpl;host=$ENV{DB_HOST};port=$ENV{DB_PORT}";
my $db = DBI->connect($dsn,
    $ENV{DB_USER}, $ENV{DB_PASS}, {RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1});
sub scalar_sql { $db->selectrow_array(shift, undef, @_) }
sub sql { $db->do(shift, undef, @_) }
# Match the SHM worker's wall clock when querying native Spool DATETIME fields.
my $zone=POSIX::strftime('%z',localtime());
$zone =~ s/([+-][0-9]{2})([0-9]{2})/$1:$2/ or die 'Missing test worker UTC offset';
sql('SET time_zone=?',$zone);
BAIL_OUT('Use an empty routing fixture')
    if scalar_sql(q{SELECT COUNT(*) FROM storage WHERE user_id=0 AND (name LIKE 'routing:%' OR name LIKE 'routingp:%')})
        || scalar_sql(q{SELECT COUNT(*) FROM users WHERE user_id>=7101});
BAIL_OUT('Unexpected queue entries in the fixture')
    if scalar_sql(q{SELECT COUNT(*) FROM spool WHERE user_id!=1 OR event->>'$.kind'!='Jobs'});
sql(q{DELETE FROM spool WHERE user_id=1 AND event->>'$.kind'='Jobs'});
my $dir = tempdir(CLEANUP => 1);

my $mock = HTTP::Daemon->new(LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1) or die $!;
my $panel_url = "http://127.0.0.1:" . $mock->sockport;
my $child = fork(); die $! unless defined $child;
if (!$child) {
    $db->{InactiveDestroy} = 1;
    $SIG{TERM} = sub { POSIX::_exit(0) };
    my %panels;
    for my $name (qw(default main other)) {
        $panels{$name} = {'Out Users' => [{tag => 'operator',protocol => 'freedom'}],
            'Routing Users' => [{ruleTag => 'operator',type => 'field',outboundTag => 'operator',domain => ['example.org']}]};
    }
    while (my $con = $mock->accept) {
        my $req = $con->get_request;
        if ($req) {
            my ($code,$result) = (404,{});
            my $path = $req->uri->path;
            my ($name) = $path =~ s{^/(default|main|other)(?=/api/)}{} ? $1 : '';
            my $snippets = $panels{$name} || {};
            if (($req->header('Authorization') // '') ne 'Bearer mock-credential') { $code = 401 }
            elsif ($path eq '/api/snippets' && $req->method eq 'GET') {
                # Commit a service transition between the worker's initial lookup
                # and its final check, with no timing assumptions about SQL or HTTP.
                if (unlink "$dir/transition-while-reading-$name") {
                    my $writer = DBI->connect($dsn,$ENV{DB_USER},$ENV{DB_PASS},{RaiseError=>1});
                    if ($name eq 'main') {
                        $writer->do(q{UPDATE user_services SET status='PROGRESS' WHERE user_service_id=7101});
                    } elsif ($name eq 'other') {
                        $writer->do(q{UPDATE user_services SET user_id=7301 WHERE user_service_id=7401});
                    }
                    $writer->disconnect;
                }
                $code=200; $result={response=>{snippets=>[map {{name=>$_,snippet=>$snippets->{$_}}} sort keys %$snippets]}};
            } elsif ($path eq '/api/snippets' && $req->method eq 'PATCH') {
                my $change=decode_json($req->content);
                open my $log, '>>', "$dir/$name-writes" or die $!;
                print {$log} "PATCH $change->{name}\n"; close $log;
                if (-f "$dir/pause-patch") {
                    open my $fh,'>',"$dir/patch-start" or die $!; close $fh;
                    for (1..200) {last unless -f "$dir/pause-patch"; usleep(25000)}
                    if (-f "$dir/pause-patch") {
                        open my $flag,'>',"$dir/patch-timeout" or die $!; close $flag;
                    }
                }
                if ($change->{name} eq 'Routing Users' && -f "$dir/fail-rules") {
                    $code=503;
                } elsif (exists $snippets->{$change->{name}} && ref($change->{snippet}) eq 'ARRAY') {
                    $snippets->{$change->{name}}=$change->{snippet}; $code=200;
                }
            } elsif ($path eq '/api/snippets/actions/sync' && $req->method eq 'POST') {
                open my $log, '>>', "$dir/$name-writes" or die $!;
                print {$log} "SYNC\n"; close $log;
                open my $times, '>>', "$dir/$name-times" or die $!;
                print {$times} time, "\n"; close $times;
                $code=-f "$dir/fail-sync" ? 503 : 202;
            } elsif ($path =~ m{\A/api/users/by-username/us_(7[1-6]01)\z}) {
                $code=200; $result={response=>{id=>0+$1+2000,username=>"us_$1"}};
            }
            $con->send_response(HTTP::Response->new($code,'fixture',['Content-Type'=>'application/json'],encode_json($result)));
        }
        $con->close;
    }
    POSIX::_exit(0);
}
close $mock;
END { if ($child) {kill 'TERM',$child; waitpid($child,0)} }
my %panel = (7101=>'main',7201=>'main',7301=>'default',7401=>'other',7501=>'main',7601=>'main',7701=>'other');
for my $id (sort keys %panel) {
    sql(q{INSERT INTO servers (server_id,name,transport,host,settings) VALUES (?,'test panel','local','localhost',?)},
        $id,encode_json({remnawave=>{api=>"$panel_url/$panel{$id}/api",token=>'mock-credential'}}));
}
sql(q{INSERT INTO services (service_id,name,cost,category) VALUES (7101,'Fixture VPN',10,'vpn-fixture')});
my %sessions;
for my $id (sort keys %panel) {
    sql(q{INSERT INTO users (user_id,login,balance,bonus,credit,gid) VALUES (?,?,0,0,0,2)},$id,"fixture$id");
    sql(q{INSERT INTO user_services (user_service_id,user_id,service_id,status_before,status,settings) VALUES (?,?,7101,'ACTIVE','ACTIVE',?)},$id,$id, encode_json({server_id=>0+$id}));
    $sessions{$id} = sha256_hex("fixture:$id:" . rand());
    sql(q{INSERT INTO sessions (id,user_id,settings) VALUES (?,?,'{}')},sha256_hex($sessions{$id}),$id);
}

my $ua=LWP::UserAgent->new(timeout=>10,max_redirect=>0);
my $base='http://api/shm/v1/user/service/routing';
sub page {
    my ($uid,$id)=@_;
    return $ua->request(GET "$base?user_service_id=$id", $uid ? (Cookie=>"session_id=$sessions{$uid}") : ());
}
sub submit {
    my ($uid,$id,$action,$text,$rules)=@_;
    my %data=(user_service_id=>0+$id,action=>$action);
    if ($action eq 'save') {
        $data{outbound_text}=$text;
        $data{rules}=[split /\n/, $rules];
    }
    return $ua->request(POST $base, Cookie=>"session_id=$sessions{$uid}", Content_Type=>'application/json', Content=>encode_json(\%data));
}
sub saved_record {
    my ($id) = @_;
    my $box = scalar_sql('SELECT data FROM storage WHERE user_id=0 AND name=?', "routing:$id");
    return {} unless $box;
    open my $fh,'<:raw','/app/data/routing-templates/key' or die $!;
    my $key = do { local $/; <$fh> };
    my $bytes = decode_base64($box);
    my ($iv, $body, $tag) = unpack('a12 a'.(length($bytes)-28).' a16', $bytes);
    my $clear = Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES',$key,$iv,"routing:$id:$id",$body,$tag);
    defined($clear) or die "Cannot read fixture record for service $id";
    return decode_json($clear);
}
my @process_one=($^X,'-MSHM','-MCore::System::ServiceManager=get_service','-e',
    'my $u=SHM->new(user_id=>1); get_service("spool")->process_one(); $u->commit;');
sub worker { is(system(@process_one),0,'upstream Spool worker processes one task') }
sub snippets {
    my $name=shift // 'main';
    my $r=$ua->request(GET "$panel_url/$name/api/snippets",Authorization=>'Bearer mock-credential');
    return {map {$_->{name}=>$_->{snippet}} @{decode_json($r->content)->{response}{snippets}}};
}
sub check_result {
    my ($r,$expected,$label)=@_; is($r->code,$expected,$label) or diag("HTTP " . $r->code . " " . $r->message);
}
sub toggle_failure {
    my ($name,$enable)=@_;
    if ($enable) {open(my $fh,'>',"$dir/$name") or die $!; close $fh}
    else {unlink "$dir/$name" or die $!}
}
sub batch_count { return scalar_sql(q{SELECT COUNT(*) FROM spool WHERE settings->>'$.routing_panel'=?},sha256_hex("$panel_url/$_[0]")) }
sub batch_due {
    return scalar_sql(q{SELECT UNIX_TIMESTAMP(executed)+`delayed` FROM spool WHERE settings->>'$.routing_panel'=? LIMIT 1},sha256_hex("$panel_url/$_[0]"));
}
sub writes {
    my ($panel,$op)=@_;
    return 0 unless -e "$dir/$panel-writes";
    open my $fh,'<',"$dir/$panel-writes" or die $!;
    return scalar grep {chomp; $_ eq $op} <$fh>;
}
# Pull work through the actual upstream scheduler, including its due-time condition;
# a new Perl process per poll has the same state visibility as a new worker.
sub pump {
    my ($ready,$label,$seconds)=@_; my $limit=time+($seconds // 20);
    while (!$ready->() && time<$limit) {
        system(@process_one)==0 or BAIL_OUT('upstream worker process failed');
        usleep(150000);
    }
    ok($ready->(),$label) or diag('spool: '.encode_json($db->selectall_arrayref('SELECT id,user_id,status,`delayed`,JSON_KEYS(response) FROM spool')));
}
sub seed_settings {
    my ($window,$interval)=@_;
    sql(q{INSERT INTO config (`key`,value) VALUES ('routing',?) ON DUPLICATE KEY UPDATE value=VALUES(value)},
        encode_json({batch_window_seconds=>$window,min_publish_interval_seconds=>$interval}));
}
sub save_route {
    my ($id,$out,$rule)=@_;
    my $r=submit($id,$id,'save',$out,$rule);
    check_result($r,200,"service $id saves routing");
    return $r;
}
sub service_event {
    my ($id,$event)=@_;
    is(system($^X,'-MSHM','-MCore::System::ServiceManager=get_service','-e',
        'my($id,$event)=@ARGV; my $u=SHM->new(user_id=>$id); get_service("us",_id=>$id)->set_status_by_event($event); $u->commit;', $id,$event),0,
        "upstream service event $event");
}
sub has_out {
    my ($id)=@_;
    return scalar grep {($_->{tag}//'') =~ /_us_${id}_out$/} @{snippets($panel{$id})->{'Out Users'}};
}
sub domain_for {
    my ($id)=@_;
    return [map {@{$_->{domain} || []}} grep {($_->{ruleTag}//'') =~ /_us_${id}_domain$/} @{snippets($panel{$id})->{'Routing Users'}}];
}


check_result(page(0,7101),401,'anonymous cannot read an outlet');
check_result(page(7101,7201),404,'customer cannot read another service');
my $form=page(7101,7101);
check_result($form,200,'owner can read the empty configuration');
like($form->header('Cache-Control') // '',qr/no-store/,'private configuration is not cached');
my $secret='socks5://fixture:private-fixture-secret@8.8.8.8:1080';
# Use the actual defaults on a separate panel before customizing the shared one.
my $now=time;
save_route(7301,$secret,'default.example');
is(batch_count('default'),1,'first edit creates one panel job');
my $first_due=batch_due('default') // 0;
cmp_ok($first_due,'>=',$now+2,'default is a short batch, not an immediate publish');
cmp_ok($first_due,'<=',time+3,'default short window is three seconds');
pump(sub {writes('default','SYNC')==1},'idle panel delivers its first batch');
open my $clock,'<',"$dir/default-times" or die $!;
chomp(my $received=<$clock>);
cmp_ok($received,'>=',$first_due,'mock received no sync before the native worker deadline');
cmp_ok($received-$now,'<=',15,'idle panel dispatched within the actual short window and worker poll');
save_route(7301,$secret,'new.default.example');
my $cooldown=(batch_due('default') // 0)-time;
cmp_ok($cooldown,'>',3570,'default cooldown is approximately one hour');
cmp_ok($cooldown,'<=',3600,'default cooldown is at most 3600 seconds');

seed_settings(2,5);
save_route(7101,$secret,"example.com\n8.8.4.4/32");
my $due=batch_due('main');
save_route(7201,'socks5://8.8.4.4:1080','example.net');
is(batch_count('main'),1,'two server rows using the same panel share one job');
is(batch_due('main'),$due,'later edits keep the first deadline');
is(writes('main','SYNC'),0,'saving does not call the remote panel');
my ($box)=scalar_sql(q{SELECT data FROM storage WHERE user_id=0 AND name='routing:7101'});
ok($box && index($box,'private-fixture-secret')<0,'saved outbound is opaque in Storage');
my $storage_list=$ua->request(GET 'http://api/shm/v1/storage/manage',Cookie=>"session_id=$sessions{7101}");
check_result($storage_list,200,'authenticated customer Storage list works');
ok(index($storage_list->content,'routing:7101') < 0,'ordinary customer storage list omits system row');
my $storage_row=$ua->request(GET 'http://api/shm/v1/storage/manage/routing:7101',Cookie=>"session_id=$sessions{7101}");
ok(index($storage_row->content,$box)<0 && index($storage_row->content,$secret)<0,
    'guessing the storage name discloses neither the ciphertext nor the outbound');
my $loaded=page(7101,7101);
ok(index($loaded->decoded_content,$secret)>=0,'owner reload gets original input');
my $draft=submit(7101,7101,'save','socks5://8.8.8.8:1080','bad rule!');
check_result($draft,400,'invalid edit is rejected');
# In this two-service batch the outbound write succeeds and the rules write
# fails once. Retry via the ordinary queue; it must not append duplicate tags.
toggle_failure('fail-rules',1);
pump(sub {writes('main','PATCH Routing Users')>0},'first attempt reaches the second PATCH');
is(writes('main','SYNC'),0,'a half-published batch does not request sync');
is(scalar(@{snippets()->{'Out Users'}}),3,'first write contains both customer outbounds');
toggle_failure('fail-rules',0);
pump(sub {writes('main','SYNC')==1},'one sync covers both users and both snippets',40);
is(writes('main','PATCH Out Users'),1,'retry recognizes the already-stored first PATCH');
is_deeply([sort map {@{$_->{user} || []}} @{snippets()->{'Routing Users'}}],['9101','9101','9201'],'published rules use the correct per-service remote account');

# Fail adding a batch job after persisting a changed service, on a panel with
# no job. These writes belong to one transaction.
my $before_failed_save=scalar_sql(q{SELECT data FROM storage WHERE user_id=0 AND name='routing:7101'});
sql(q{CREATE TRIGGER routing_fixture_reject_queue BEFORE INSERT ON spool FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='fixture rejects queue insert'});
my $failed_save=submit(7101,7101,'save','socks5://8.8.4.4:4180','example.net');
sql(q{DROP TRIGGER routing_fixture_reject_queue});
ok(!$failed_save->is_success && !$failed_save->is_redirect,'an enqueue failure is not acknowledged');
is(scalar_sql(q{SELECT data FROM storage WHERE user_id=0 AND name='routing:7101'}),$before_failed_save,'failed queue insertion rolls back service intent');
is(batch_count('main'),0,'failed transaction leaves no job');

my $base_rules="example.com\n8.8.4.4/32";
save_route(7101,$secret,$base_rules);
worker();
is(writes('main','SYNC'),1,'unchanged confirmed settings do not sync');
save_route(7101,$secret,'temporary.example');
save_route(7101,$secret,$base_rules);
my $sync_before=writes('main','SYNC');
pump(sub {batch_count('main')==0},'final intent equal to acknowledged config clears pending work');
is(writes('main','SYNC'),$sync_before,'A to B to A sends no sync');
is(writes('main','PATCH Out Users'),1,'A to B to A sends no outbound PATCH');

# The other panel is allowed to deliver immediately even while the default
# panel remains on its one-hour cooldown.
save_route(7401,$secret,'other.example');
pump(sub {writes('other','SYNC')==1},'unrelated panel publishes within its own budget');
is(writes('default','SYNC'),1,'one-hour panel stays in cooldown');
my $old_job=scalar_sql(q{SELECT id FROM spool WHERE settings->>'$.routing_panel'=?},sha256_hex("$panel_url/default"));
my $old_deadline=batch_due('default');
save_route(7301,$secret,'final.default.example');
is(scalar_sql(q{SELECT id FROM spool WHERE settings->>'$.routing_panel'=?},sha256_hex("$panel_url/default")),
    $old_job,'shorter administrator interval reuses the existing native job');
cmp_ok(batch_due('default'),'<',$old_deadline,'fresh intent after shortening the interval advances the due time');
pump(sub {writes('default','SYNC')==2},'shorter interval applies to an existing queued batch');

# Save a new desire while the earlier publisher is parked in its HTTP PATCH.
# An independent web request must return while that request is in flight;
# subsequent work must retain the newer intent regardless of old completion.
save_route(7101,$secret,'first.example');
toggle_failure('pause-patch',1);
my $publisher = fork(); die $! unless defined $publisher;
if (!$publisher) {
    $db->{InactiveDestroy}=1;
    for (1..60) {
        system(@process_one)==0 or POSIX::_exit(125);
        last if -f "$dir/patch-start";
        usleep(150000);
    }
    POSIX::_exit(0);
}
for (1..180) {last if -f "$dir/patch-start"; usleep(50000)}
ok(-f "$dir/patch-start",'publisher is inside the remote PATCH');
save_route(7101,$secret,'last.example');
ok(!-e "$dir/patch-timeout",'the web request commits while the remote publisher is still paused');
toggle_failure('pause-patch',0);
waitpid($publisher,0); is($?,0,'first publisher exits');
pump(sub {domain_for(7101)->[0] && domain_for(7101)->[0] eq 'domain:last.example' && !batch_count('main')},
    'a fresh worker publishes a save received during the previous batch',40);
is(has_out(7201),1,'publishing another user still preserves previous user');

my $withdraw=submit(7101,7101,'disable');
check_result($withdraw,200,'user can request withdrawal');
my $pending_disable=decode_json(page(7101,7101)->content)->{data}[0];
ok(!$pending_disable->{enabled} && $pending_disable->{status} eq 'queued','disable is pending until publication');
cmp_ok($pending_disable->{publish_at},'>',0,'pending withdrawal has a publication time');
my $before_disable=writes('main','SYNC');
pump(sub {!has_out(7101) && writes('main','SYNC')>$before_disable},'disable withdraws the previously published entries');
ok(index(page(7101,7101)->decoded_content,$secret)>=0,'disabled record retains original input');
is(has_out(7201),1,'disable preserves other customer');
is(snippets()->{'Out Users'}[0]{tag},'operator','operator retains the default outbound position');

# A service can still be in PROGRESS when the batch starts. Complete that
# transition without a CHANGED event, then exercise native normal renewal:
# upstream PROLONGATE preserves ACTIVE and does not emit CHANGED.
my $progress_before=writes('main','SYNC');
save_route(7201,$secret,'renewed.example');
sql(q{UPDATE user_services SET status_before='ACTIVE',status='PROGRESS' WHERE user_service_id=7201});
pump(sub {saved_record(7201)->{status} eq 'waiting'},'renewal progress keeps a pending recheck');
is_deeply(domain_for(7201),['domain:example.net'],'progress leaves existing routing in place');
is(writes('main','SYNC'),$progress_before,'progress alone never restarts the panel');
is(system($^X,'-MSHM','-MCore::System::ServiceManager=get_service','-e',
    'my $u=SHM->new(user_id=>1); get_service("us",_id=>7201,user_id=>7201)->set_status_manual(status=>"ACTIVE"); $u->commit;'),
    0,'native status update completes the pending transition without another lifecycle notification');
service_event(7201,'PROLONGATE');
is(scalar_sql('SELECT status FROM user_services WHERE user_service_id=7201'),'ACTIVE','ordinary renewal preserves active status');
is(scalar_sql('SELECT COUNT(*) FROM spool WHERE user_id=7201'),0,'no second CHANGED is needed for the recheck');
pump(sub {(domain_for(7201)->[0] // '') eq 'domain:renewed.example'},'ordinary renewal resumes without a second CHANGED event',78);

save_route(7201,$secret,'pause.example');
sql(q{UPDATE user_services SET status='ERROR' WHERE user_service_id=7201});
pump(sub {saved_record(7201)->{status} eq 'waiting'},'unexpected service ERROR preserves the pending edit');
is_deeply(domain_for(7201),['domain:renewed.example'],'ERROR does not replace or remove the confirmed remote rules');
check_result(submit(7201,7201,'disable'),200,'explicit disable accepted during service ERROR');
pump(sub {!has_out(7201)},'explicit disable may withdraw confirmed entries during ERROR',78);
sql(q{UPDATE user_services SET status='ACTIVE' WHERE user_service_id=7201});
save_route(7201,$secret,'scope.example');
pump(sub {has_out(7201)},'restored service can enable routing');
service_event(7201,'BLOCK');
pump(sub {!has_out(7201)},'BLOCK withdraws active routing');
service_event(7201,'ACTIVATE');
pump(sub {has_out(7201)},'ACTIVATE restores the saved desire');

service_event(7201,'REMOVE'); toggle_failure('fail-sync',1);
my $before_removed=writes('main','SYNC');
pump(sub {writes('main','SYNC')>$before_removed},'removed service attempts sync even after clearing its binding');
ok(scalar_sql(q{SELECT COUNT(*) FROM storage WHERE user_id=0 AND name='routing:7201'}),'unacknowledged removal keeps recovery data');
my $patch_count=writes('main','PATCH Routing Users');
toggle_failure('fail-sync',0);
pump(sub {!scalar_sql(q{SELECT COUNT(*) FROM storage WHERE user_id=0 AND name='routing:7201'})},'removal clears ciphertext only after sync acknowledgement',45);
is(writes('main','PATCH Routing Users'),$patch_count,'recovery resubmits uncertain sync without re-PATCHing');
is_deeply(snippets()->{'Out Users'},[{tag=>'operator',protocol=>'freedom'}],'removal preserves platform default');

my $before_unused=writes('main','SYNC');
for my $pair ([7501,'INIT'],[7601,'NOT PAID']) {
    my ($id,$status)=@$pair;
    save_route($id,$secret,'draft.example');
    sql(q{UPDATE user_services SET status=? WHERE user_service_id=?},$status,$id);
    check_result(submit($id,$id,'save',$secret,'draft.example'),404,'new edits require an active service');
}
pump(sub {saved_record(7501)->{status} eq 'waiting'
          && saved_record(7601)->{status} eq 'waiting'
          && !batch_count('main')},'drafts are classified against the current service state');
is(writes('main','SYNC'),$before_unused,'unpublished INIT and NOT PAID drafts cause no restarts');
ok(!has_out(7501) && !has_out(7601),'non-active services cannot install their outlets');
service_event(7601,'REMOVE');
pump(sub {!scalar_sql(q{SELECT COUNT(*) FROM storage WHERE user_id=0 AND name='routing:7601'})},
    'removal of an unpublished service erases only its draft');
is(writes('main','SYNC'),$before_unused,'never-published removal costs no sync');

# Rejected edits leave an already published service unchanged.
save_route(7101,$secret,'keep.example');
pump(sub {has_out(7101) && !batch_count('main')},'service has acknowledged routing before a rejected edit');
my $stored_7101 = q{SELECT data FROM storage WHERE user_id=0 AND name='routing:7101'};
my $before_invalid = scalar_sql($stored_7101);
my $invalid_text = 'socks5://127.0.0.1:1080';
my $invalid = submit(7101,7101,'save',$invalid_text,'invalid.example');
check_result($invalid,400,'a fixed non-public proxy is rejected before enqueue');
like($invalid->decoded_content,qr/ENDPOINT_DENIED/,'the owner receives the input error');
is(scalar_sql($stored_7101),$before_invalid,'rejected edit keeps encrypted settings and publication receipt');
is(batch_count('main'),0,'rejected edit creates no panel job');

# Simulate an intent accepted by an earlier form, using the real envelope and
# the normal queue. Keep the previous publication receipt for later withdrawal.
save_route(7101,$secret,'legacy.example');
{
    open my $fh,'<:raw','/app/data/routing-templates/key' or die $!;
    my $key = do { local $/; <$fh> };
    my $box = decode_base64(scalar_sql($stored_7101));
    my $aad = 'routing:7101:7101';
    my ($iv,$body,$tag) = unpack('a12 a'.(length($box)-28).' a16',$box);
    my $raw = Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES',$key,$iv,$aad,$body,$tag);
    my $record = decode_json($raw);
    $record->{outbound_text} = $invalid_text;
    $record->{outbound}{settings}{servers}[0]{address} = '127.0.0.1';
    my $nonce = Crypt::PRNG::random_bytes(12);
    my ($cipher,$new_tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES',$key,$nonce,$aad,encode_json($record));
    sql(q{UPDATE storage SET data=? WHERE user_id=0 AND name='routing:7101'},encode_base64($nonce.$cipher.$new_tag,''));
}
sql(q{UPDATE user_services SET status='ACTIVE' WHERE user_service_id=7501});
save_route(7501,$secret,'healthy.example');
pump(sub {has_out(7501) && !batch_count('main')},'a permanently invalid member leaves the batch while the valid peer publishes');
is_deeply(domain_for(7101),['domain:keep.example'],'previously published live routing is retained');
like(page(7101,7101)->decoded_content,qr/ENDPOINT_DENIED/,'queued fixed address reports an error');
my $stopped = scalar_sql($stored_7101);
save_route(7501,$secret,'next-batch.example');
pump(sub {domain_for(7501)->[0] && domain_for(7501)->[0] eq 'domain:next-batch.example' && !batch_count('main')},
    'the next panel cycle has no retry for the invalid intent');
is(scalar_sql($stored_7101),$stopped,'other users publishing leave the failed intent intact');
check_result(submit(7101,7101,'disable'),200,'the invalid saved endpoint can still be disabled');
pump(sub {!has_out(7101) && !batch_count('main')},'withdrawal uses the retained receipt and cleans the old outlet');
open $clock,'<',"$dir/main-times" or die $!;
chomp(my @times=<$clock>);
my @premature=grep {$times[$_]-$times[$_-1]<5} 1..$#times;
is_deeply(\@premature,[],'every actual HTTP sync attempt, including uncertain retries, respects the customized panel interval');
is(scalar_sql(q{SELECT COUNT(*) FROM logs_api WHERE args LIKE '%private-fixture-secret%'}),0,'private text absent from API audit');
is(scalar_sql(q{SELECT COUNT(*) FROM spool_history WHERE response LIKE '%private-fixture-secret%' OR settings LIKE '%private-fixture-secret%'}),0,'private text absent from job history');

save_route(7101,$secret,'after-renewal.example');
save_route(7501,$secret,'active.example');
toggle_failure('transition-while-reading-main',1);
toggle_failure('fail-rules',1);
my $attempts = writes('main','PATCH Routing Users');
pump(sub {writes('main','PATCH Routing Users') > $attempts}, 'shared write fails after one service enters renewal');
is(saved_record(7101)->{status},'queued','service excluded at publication retains its own status');
like(page(7501,7501)->decoded_content,qr/REMOTE_HTTP/,'the participating service receives the panel error');
toggle_failure('fail-rules',0);
sql(q{UPDATE user_services SET status='ACTIVE' WHERE user_service_id=7101});
pump(sub { !batch_count('main') },'the batch resumes after renewal and panel recovery',45);

# A general panel task survives removal of its original service and customer.
service_event(7401,'REMOVE');
pump(sub {batch_count('other') == 1}, 'REMOVE has reached the shared panel queue');
my $original_box = scalar_sql(q{SELECT data FROM storage WHERE user_id=0 AND name='routing:7401'});
toggle_failure('transition-while-reading-other',1);
pump(sub { !-f "$dir/transition-while-reading-other" }, 'ownership changes just before the shared write');
ok(has_out(7401),'a service ID assigned to another user cannot withdraw the original outlet');
is(scalar_sql(q{SELECT data FROM storage WHERE user_id=0 AND name='routing:7401'}),$original_box,'owner mismatch leaves the authenticated record intact');
sql(q{UPDATE user_services SET user_id=7401 WHERE user_service_id=7401});
is(system($^X,'-MSHM','-MCore::System::ServiceManager=get_service','-e',
    'my $u=SHM->new(user_id=>1); get_service("user",_id=>7401)->delete(); $u->commit;'),0,'SHM processes normal account deletion');
is(scalar_sql('SELECT COUNT(*) FROM users WHERE user_id=7401'),0,'native delete removed the customer');
is(scalar_sql('SELECT COUNT(*) FROM user_services WHERE user_service_id=7401'),0,'native delete physically removed the service');
save_route(7701,$secret,'never-published.example');
# A lost local completion can also leave a pending member after its records are gone.
sql(q{DELETE FROM storage WHERE user_id=0 AND name='routing:7701'});
sql(q{DELETE FROM user_services WHERE user_service_id=7701});
toggle_failure('fail-sync',1);
my $deletion_syncs = writes('other','SYNC');
pump(sub {writes('other','SYNC') > $deletion_syncs},'physically deleted service withdraws from its saved panel');
ok(!has_out(7401),'queued cleanup removes the original outlet');
ok(scalar_sql(q{SELECT COUNT(*) FROM storage WHERE user_id=0 AND name='routing:7401'}),'unconfirmed hard delete retains its encrypted recovery record');
toggle_failure('fail-sync',0);
pump(sub { !batch_count('other') },'confirmed cleanup and already absent member both leave the queue',45);
is(scalar_sql(q{SELECT COUNT(*) FROM storage WHERE user_id=0 AND name='routing:7401'}),0,'only confirmed cleanup discards the recovery record');

# Eligibility follows the assigned panel across tariff changes.
ok(has_out(7501), 'service has a published outlet before changing its plan');
sql(q{INSERT INTO services (service_id,name,cost,category) VALUES (7801,'Fixture Other',10,'other-fixture')});
save_route(7501, $secret, 'queued-before-plan-change.example');
sql(q{UPDATE user_services SET service_id=7801 WHERE user_service_id=7501});
pump(sub { (domain_for(7501)->[0] // '') eq 'domain:queued-before-plan-change.example' }, 'queued rules publish under the new tariff on the same panel');
ok(has_out(7101), 'changing a plan preserves another customer on the same panel');
my $remembered = saved_record(7101)->{outbound_text};
my $before_toggle = writes('main','SYNC');
check_result(submit(7101,7101,'disable'),200,'owner can disable without losing the saved outlet');
check_result(submit(7101,7101,'enable'),200,'enable uses the locked saved configuration');
ok(saved_record(7101)->{outbound_text} eq $remembered, 'reenable keeps the last saved original text');
pump(sub { !batch_count('main') }, 'a rapid disable and enable is coalesced');
is(writes('main','SYNC'), $before_toggle, 'no effective change triggers no panel sync');

my $new_panel_writes = writes('other','SYNC');
save_route(7101, $secret, 'queued-before-reassignment.example');
sql(q{UPDATE user_services SET settings=JSON_SET(settings,'$.server_id',7401) WHERE user_service_id=7101});
pump(sub { !has_out(7101) && !batch_count('main') }, 'server change withdraws the outlet from its original panel');
my $detached = saved_record(7101);
is_deeply([@{$detached}{qw(status error published)}], ['error','TARGET_CHANGED',0], 'confirmed withdrawal keeps a recoverable receipt');
is(writes('other','SYNC'), $new_panel_writes, 'reassignment sends no configuration to the new panel');
check_result(submit(7101,7101,'enable'),409,'enable cannot silently transfer an active outlet to a new target');
save_route(7101,'socks5://8.8.4.4:1081','new-target.example');
$panel{7101}='other';
pump(sub { (domain_for(7101)->[0] // '') eq 'domain:new-target.example' }, 'an explicit new save can bind to the replacement panel');
my $unrelated_writes = writes('main','SYNC');
save_route(7101,'socks5://8.8.4.4:1081','changed-api.example');
sql(q{UPDATE servers SET settings=JSON_SET(settings,'$.remnawave.api',?) WHERE server_id=7401}, "$panel_url/main/api");
pump(sub { (saved_record(7101)->{error} // '') eq 'TARGET_CHANGED' }, 'changing the saved server URL fails closed');
ok(saved_record(7101)->{published}, 'unverified old target retains its outstanding cleanup receipt');
ok(has_out(7101), 'old outlet is not treated as withdrawn');
is(writes('main','SYNC'), $unrelated_writes, 'worker never submits credentials to an unverified replacement URL');
done_testing;
