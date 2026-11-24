use v5.14;
use utf8;

use Test::More;
use Test::Deep;

use Core::Utils qw/
    decode_json
    shm_test_api
/;

my $ret = qx(
    curl -s \\
    -H "Content-Type: application/json" \\
    -H "test: 1" \\
    -H "login: admin" \\
    -H "password: admin" \\
    -X PUT \\
    -d '{"user_id":40092,"pay_system_id":"test","money":123.45,"comment":{"comment":"Test payment #4"}}' \\
    http://api/shm/v1/admin/user/payment
);

my $json_ret = decode_json( $ret );

cmp_deeply( $json_ret->{data}->[0], {
    id => ignore(),
    user_id => 40092,
    date => ignore(),
    pay_system_id => 'test',
    money => 123.45,
    comment => {
        comment => 'Test payment #4',
    },
    uniq_key => undef,
}, 'Test API');

subtest 'manual credit refuses a different currency' => sub {
    my %admin = (login => 'admin', password => 'admin');
    my $url = 'v1/admin/user?user_id=40092';
    my %before = shm_test_api(%admin, url => $url);
    is($before{json}{data}[0]{user_id}, 40092, 'read the intended wallet');

    my %payment = shm_test_api(%admin, method => 'PUT', url => 'v1/admin/user/payment',
        data => { user_id => 40092, money => '1.25', currency => 'USD' },
    );
    is($payment{json}{status}, 400, 'reject foreign currency');
    my %after = shm_test_api(%admin, url => $url);
    is($after{json}{data}[0]{balance}, $before{json}{data}[0]{balance}, 'wallet balance unchanged');
};

done_testing();
