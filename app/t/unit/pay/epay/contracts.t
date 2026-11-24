use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../../pay_systems/epay/lib";
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use JSON::PP;
use SHM::Pay::Epay::Protocol qw(build_payment_request canonical_string sign_request verify_notification match_payment money_to_cents);
use SHM::Pay::Epay::Vault qw(read_order seal_order account_values);
use SHM::Pay::Epay::Channels qw(merchant);
my $row = {out_trade_no => 'shm_test_0001', amount_cents => 319, payment_type => 'wxpay', currency => 'CNY',
    user_id => 48, pid => '105', profile => 'epay_7', protocol => 'v1_md5', key_version => 'fixture', gateway_id => '3' x 32};
my $profile = {protocol => 'v1_md5', api_url => 'https://pay.example.test', pid => '105',
    notify_url => 'https://wallet.example.test/shm/pay_systems/epay_notify.cgi',
    return_url => 'https://wallet.example.test/shm/pay_systems/epay_return.cgi'};
my $private = {md5_key => 'test-secret'};
my $config = {%$profile, %$private};
for my $mode (qw(submit mapi)) {
    my $request = build_payment_request($row, $config, flow => $mode);
    is($request->{url}, ($mode eq 'submit' ? "$profile->{api_url}/submit.php" : "$profile->{api_url}/mapi.php"), 'correct checkout API');
    is($request->{fields}{money}, '3.19', 'decimal amount is formatted exactly');
}
my $notice = sign_request({out_trade_no => $row->{out_trade_no}, pid => '105', type => 'wxpay', money => '3.19',
    trade_status => 'TRADE_SUCCESS', trade_no => 'provider_32'}, $config);
ok(eval { verify_notification($notice, $row, $config); 1 }, 'provider notice authenticates');
is(match_payment($notice, $row, $config), 'provider_32', 'notification matches frozen fields');
for my $change ([pid=>'51'], [out_trade_no=>'other'], [type=>'alipay'], [currency=>'USD'], [money=>'3.29']) {
    my $evidence = sign_request({%$notice, @$change}, $config);
    ok(!eval { match_payment($evidence, $row, $config); 1 }, 'reject signed but unrelated payment data');
}
for my $invalid ('1.999','00.01','NaN','1e2','1.','0') {
    ok(!eval {money_to_cents($invalid);1}, 'invalid amount rejected');
}
my $accounts = {epay => {key=>'main',apiurl=>'https://main.example.test',pid=>'101'}, epay_1=>{pid=>'102'}};
is(merchant($accounts,'epay_1')->{pid},'102','partial merchant override');
is(merchant($accounts,'epay_1')->{key},'main','same-provider copy inherits credentials');
$accounts->{epay_1}{apiurl} = 'https://other.example.test';
ok(!eval {merchant($accounts,'epay_1');1}, 'different provider cannot receive credentials by inheritance');

subtest 'historical order and account formats' => sub {
    eval { require Crypt::AuthEnc::GCM; require Crypt::PRNG; 1 } or plan skip_all => 'CryptX is provided in the SHM runtime';
    my $key = 'X' x 32;
    my $iv = 'n' x 12;
    my $json = JSON::PP->new->utf8->canonical;
    no warnings 'redefine';
    local *SHM::Pay::Epay::Vault::site_key = sub { $key };
    # A prior version authenticated optional metadata and stringified each immutable order column.
    my $historical = {%$profile, timestamp_skew=>300, checkout=>'api', key_version=>'fixture'};
    my %identity = map { $_ => "$row->{$_}" } keys %$row;
    my $associated = 'SHM:epay:credentials:1:'.$json->encode({profile=>$historical,identity=>\%identity});
    my ($ct,$tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES',$key,$iv,$associated,$json->encode($private));
    $historical->{credential_box} = encode_base64($iv.$ct.$tag,'');
    my $stored = $json->encode($historical);
    my $old = {%$row,profile_config=>$stored,config_fingerprint=>sha256_hex($stored)};
    is(read_order(undef,$old)->{md5_key},$private->{md5_key},'pending old order still uses the original key');
    ok(!eval {read_order(undef,{%$old,user_id=>49});1},'moving the snapshot to another user is rejected');
    my ($serialized,$digest) = seal_order(undef,$row,$profile,$private);
    is(read_order(undef,{%$row,profile_config=>$serialized,config_fingerprint=>$digest})->{md5_key},$private->{md5_key},'new order decrypts');
    my ($account,$auth) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES',$key,$iv,'SHM:epay:account:1:epay_7',
        $json->encode({key=>'merchant-fixture',pid=>'105'}));
    my $box = encode_base64($iv.$account.$auth,'');
    utf8::upgrade($box);
    is(account_values(undef,'epay_7',$box)->{key},'merchant-fixture','DB character field remains a compatible historical envelope');
    ok(!eval {account_values(undef,'epay',$box);1},'cannot transfer a private envelope to another channel');
};
done_testing;
