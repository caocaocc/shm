#!/usr/bin/perl

use v5.14;
use utf8;
use SHM qw(:all);

use Router::Simple;
use Core::System::ServiceManager qw( get_service );
use Core::Utils qw(
    parse_args
    encode_json
    decode_json
    is_email
    switch_user
    blessed
    print_header
    print_json
    get_user_ip
    qrencode
);

use CGI::Carp qw(fatalsToBrowser);
use Data::Dumper;
use Time::HiRes ();

sub route_methods {
    my @pairs;
    while (@_) {
        my $key   = shift;
        my $value = shift;
        if (ref $key eq 'ARRAY') {
            push @pairs, $_, $value for @$key;
        }
        else {
            push @pairs, $key, $value;
        }
    }
    return @pairs;
}

state $routes //= {
'/healthcheck' => {
    GET => {
        params => {},
        controller => 'Test',
        method => 'healthcheck',
        skip_check_auth => 1,
    },
},
'/test' => {
    GET => {
        params => {},
        controller => 'Test',
        skip_check_auth => 1,
    },
},
'/test/http/echo' => {
    GET => {
        controller => 'Test',
        method => 'http_echo',
        skip_check_auth => 1,
    },
    PUT => {
        controller => 'Test',
        method => 'http_echo',
        skip_check_auth => 1,
    },
    POST => {
        controller => 'Test',
        method => 'http_echo',
        skip_check_auth => 1,
    },
    DELETE => {
        controller => 'Test',
        method => 'http_echo',
        skip_check_auth => 1,
    },
},
'/company' => {
    GET => {
        params => {},
        controller => 'Config',
        method => 'api_data_by_company',
        skip_check_auth => 1,
    },
},
'/system/auth' => {
    swagger => {
        tags => '身份验证',
    },
    GET => {
        params => {},
        skip_check_auth => 1,
        controller => 'Config',
        method => 'api_data_by_auth',
        swagger => {
            summary => '获取登录方式（OAuth2、Telegram）及注册、登录、验证码的 API 权限',
        },
    },
},
'/user/service/consumption' => {
    swagger => { tags => '用户服务' },
    GET => {
        controller => 'Consumption',
        method => 'snapshot_for_api',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
            withdraw_id => { type => 'integer', min => 1 },
        },
        swagger => { summary => '查看预付套餐消费比例和可退款余额' },
    },
},
'/admin/consumption' => {
    swagger => { tags => '计量' },
    GET => {
        controller => 'Consumption',
        method => 'snapshot_for_api',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
            withdraw_id => { type => 'integer', min => 1 },
        },
        swagger => { summary => '查看指定计费周期的消费快照' },
    },
},
'/admin/consumption/generation' => {
    swagger => { tags => '计量' },
    POST => {
        controller => 'Consumption',
        method => 'admin_start_generation',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
            withdraw_id => { type => 'integer', required => 1, min => 1 },
            meter => { type => 'string', required => 1, max_length => 64 },
            generation => { type => 'string', required => 1, max_length => 128 },
            record_id => { type => 'string', required => 1, max_length => 128 },
            baseline => { type => 'string', required => 1, max_length => 39, pattern => '^\d{1,26}(?:\.\d{1,12})?$' },
            observed_at => { type => 'string', pattern => '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' },
        },
        swagger => { summary => '提交计量代次的初始累计读数' },
    },
},
'/admin/consumption/reading' => {
    swagger => { tags => '计量' },
    POST => {
        controller => 'Consumption',
        method => 'admin_ingest',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
            withdraw_id => { type => 'integer', required => 1, min => 1 },
            meter => { type => 'string', required => 1, max_length => 64 },
            generation => { type => 'string', required => 1, max_length => 128 },
            record_id => { type => 'string', required => 1, max_length => 128 },
            cumulative => { type => 'string', required => 1, max_length => 39, pattern => '^\d{1,26}(?:\.\d{1,12})?$' },
            observed_at => { type => 'string', pattern => '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' },
        },
        swagger => { summary => '提交通用计量的累计读数' },
    },
},
'/admin/consumption/finalize' => {
    swagger => { tags => '计量' },
    POST => {
        controller => 'Consumption',
        method => 'admin_finalize',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
            withdraw_id => { type => 'integer', required => 1, min => 1 },
            cutoff => { type => 'string', required => 1, pattern => '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' },
        },
        swagger => { summary => '外部资源停止且读数完整后固定结算截止点' },
    },
},
'/user/epay/order' => {
    swagger => { tags => '支付' },
    GET => {
        controller => 'Epay',
        method => 'status',
        params => {
            out_trade_no => { type => 'string', required => 1, max_length => 64, pattern => '^[A-Za-z0-9_-]+$' },
        },
        swagger => { summary => '查询本人的易支付充值订单状态' },
    },
    POST => {
        controller => 'Epay',
        method => 'create_order',
        no_dry_run => 1,
        params => {
            amount => { type => 'string', required => 1, max_length => 11, pattern => '^\d{1,8}(?:\.\d{1,2})?$' },
            ps => { type => 'string', max_length => 64, pattern => '^[A-Za-z0-9_-]+$' },
        },
        swagger => { summary => '创建人民币充值订单并获取支付入口' },
    },
},
route_methods(['/user/epay/reconcile', '/admin/epay/reconcile'], {
    swagger => { tags => '支付' },
    POST => {
        controller => 'Epay',
        method => 'reconcile',
        no_dry_run => 1,
        params => {
            out_trade_no => { type => 'string', required => 1, max_length => 64, pattern => '^[A-Za-z0-9_-]+$' },
        },
        swagger => { summary => '向易支付查单并补齐已付款订单' },
    },
}),
'/user/captcha' => {
    swagger => { tags => '验证码' },
    GET => {
        params => {},
        controller      => 'User',
        method          => 'gen_captcha',
        skip_check_auth => 1,
        swagger => { summary => '获取验证码' },
    },
},
'/user' => {
    swagger => { tags => '用户' },
    GET => {
        controller => 'User',
        method => 'list_for_api', # hide COMMON_LIST_PARAMS
        swagger => { summary => '获取用户' },
        params => {},
    },
    PUT => {
        controller => 'User',
        method => 'reg_api_safe',
        skip_check_auth => 1,
        params => {
            login => { type => 'string', required => 1, min_length => 1, max_length => 64 },
            login_type => { type => 'string', required => 0, enum => ['login','email'] },
            password => { type => 'string', required => 1, min_length => 6, max_length => 128 },
            full_name => { type => 'string', required => 0, min_length => 1, max_length => 64 },
            phone => { type => 'string', required => 0, min_length => 1, max_length => 16 },
            partner_id => { type => 'integer', min => 2 },
            captcha_token  => { type => 'string' },
            captcha_answer => { type => 'string' },
        },
        swagger => { summary => '注册用户' },
    },
},
'/user/referrals' => {
    swagger => { tags => '用户' },
    GET => {
        params => {},
        controller => 'User',
        method => 'api_referrals',
            swagger => { summary => '获取推荐用户数量' },
    },
},
'/user/auth' => {
    swagger => { tags => '用户' },
    POST => {
        controller => 'User',
        method => 'auth_api_safe',
        skip_check_auth => 1,
        params => {
            login    => { type => 'string', required => 1, min_length => 1, max_length => 64 },
            password => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            otp_token => { type => 'string', required => 0, min_length => 1, max_length => 128 },
        },
        args => {
            format => 'json',
        },
        swagger => {
            summary => '登录并获取 `session_id`',
            responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    id => {
                                        type => 'string'
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/user/password-auth' => {
    swagger => { tags => '用户' },
    GET => {
        params => {},
        controller => 'User',
        method => 'api_password_auth_status',
        swagger => { summary => '密码登录状态' },
    },
    POST => {
        params => {},
        controller => 'User',
        method => 'api_enable_password_auth',
        swagger => { summary => '启用密码登录' },
    },
    DELETE => {
        params => {},
        controller => 'User',
        method => 'api_disable_password_auth',
        swagger => { summary => '停用密码登录' },
    },
},
'/user/otp' => {
    swagger => { tags => 'OTP' },
    GET => {
        params => {},
        controller => 'User::OTP',
        method => 'api_status',
        swagger => { summary => 'OTP 状态' },
    },
    POST => {
        params => {
            token => { type => 'string', required => 1, min_length => 1, max_length => 16 },
        },
        controller => 'User::OTP',
        method => 'api_verify',
        swagger => { summary => '验证 OTP' },
    },
    PUT => {
        params => {
            token => { type => 'string', required => 1, min_length => 1, max_length => 16 },
        },
        controller => 'User::OTP',
        method => 'api_enable',
        swagger => { summary => '启用 OTP' },
    },
    DELETE => {
        params => {
            token => { type => 'string', required => 1, min_length => 1, max_length => 16 },
        },
        controller => 'User::OTP',
        method => 'api_disable',
        swagger => { summary => '停用 OTP' },
    },
},
'/user/otp/setup' => {
    swagger => { tags => 'OTP' },
    POST => {
        params => {},
        controller => 'User::OTP',
        method => 'api_setup',
        swagger => {
            summary => '配置 OTP',
            responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    qr_url => {
                                        type => 'string'
                                    },
                                    secret => {
                                        type => 'string'
                                    },
                                    backup_codes => {
                                        type => 'array',
                                        items => {
                                            type => 'number'
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/user/passkey/register' => {
    swagger => { tags => 'Passkey 注册' },
    GET => {
        params => {},
        controller => 'User::Passkey',
        method => 'api_register_options',
        swagger => { summary => '获取 Passkey 注册参数' },
    },
    POST => {
        params => {
            credential_id => { type => 'string', required => 1, min_length => 1, max_length => 512 },
            response      => { type => 'string', required => 1, min_length => 1, max_length => 8192 },
        },
        controller => 'User::Passkey',
        method => 'api_register_complete',
        swagger => { summary => '完成 Passkey 注册' },
    },
},
'/user/passkey' => {
    swagger => { tags => 'Passkey 设置' },
    GET => {
        params => {},
        controller => 'User::Passkey',
        method => 'api_list',
        swagger => { summary => '已注册的 Passkey 列表' },
    },
    POST => {
        params => {
            credential_id => { type => 'string', required => 1, min_length => 1, max_length => 512 },
            name          => { type => 'string', required => 1, min_length => 1, max_length => 128 },
        },
        controller => 'User::Passkey',
        method => 'api_rename',
        swagger => { summary => '按标识重命名 Passkey' },
    },
    DELETE => {
        params => {
            credential_id => { type => 'string', required => 1, min_length => 1, max_length => 512 },
        },
        controller => 'User::Passkey',
        method => 'api_delete',
        swagger => { summary => '按标识删除 Passkey' },
    },
},
'/user/auth/passkey' => {
    swagger => { tags => 'Passkey 身份验证' },
    GET => {
        params => {},
        controller => 'User::Passkey',
        method => 'api_auth_options_public',
        skip_check_auth => 1,
        swagger => { summary => '获取 Passkey 登录参数' },
    },
    POST => {
        params => {
            credential_id => { type => 'string', required => 1, min_length => 1, max_length => 512 },
            response      => { type => 'string', required => 1, min_length => 1, max_length => 8192 },
        },
        controller => 'User::Passkey',
        method => 'api_auth_public',
        skip_check_auth => 1,
        swagger => { summary => '使用 Passkey 登录' },
    },
},
'/user/passwd' => {
    swagger => { tags => '用户' },
    POST => {
        swagger => { summary => '修改用户密码' },
        controller => 'User',
        method => 'passwd',
        params => {
            password     => { type => 'string', required => 1, min_length => 6, max_length => 128 },
            old_password => { type => 'string', min_length => 1, max_length => 128 },
            login        => { type => 'string', min_length => 1, max_length => 128 },
        },
    },
},
'/user/passwd/reset' => {
    swagger => { tags => '用户' },
    POST => {
        params => {
            login => { type => 'string', min_length => 1, max_length => 64 },
            email => { type => 'email', max_length => 254 },
        },
        controller => 'User',
        method => 'passwd_reset_request',
        skip_check_auth => 1,
        swagger => { summary => '申请重置用户密码' },
    },
},
'/user/passwd/reset/verify' => {
    swagger => { tags => '用户' },
    GET => {
        controller => 'User',
        method => 'passwd_reset_verify',
        skip_check_auth => 1,
        params => {
            token => { type => 'string', required => 1, min_length => 8, max_length => 256 },
            login => { type => 'string', required => 1, min_length => 1, max_length => 128 },
        },
        swagger => { summary => '修改密码前验证重置令牌' },
    },
    POST => {
        controller => 'User',
        method => 'passwd_reset_verify',
        skip_check_auth => 1,
        params => {
            password => { type => 'string', required => 1, min_length => 6, max_length => 128 },
            token    => { type => 'string', required => 1, min_length => 8, max_length => 256 },
            login    => { type => 'string', required => 1, min_length => 1, max_length => 128 },
        },
        swagger => { summary => '使用重置令牌修改密码' },
    },
},
'/user/accounts' => {
    swagger => { tags => '用户' },
    GET => {
        controller => 'User::Logins',
        swagger    => { summary => '用户登录账号列表' },
    },
    DELETE => {
        params => {
            login => { type => "string", min_length => 1, max_length => 128 },
        },
        controller => 'User::Logins',
    },
},
'/user/email' => {
    swagger => { tags => '用户' },
    PUT => {
        controller => 'User',
        method => 'set_email',
        params => {
            email => { type => 'email', required => 1, max_length => 254 },
        },
        swagger => { summary => '绑定用户邮箱' },
    },
    GET => {
        params => {},
        controller => 'User',
        method => 'get_emails',
        swagger => { summary => '获取用户邮箱' },
    },
    POST => {
        params => {
            email => { type => 'email', required => 1, max_length => 254 },
            code  => { type => 'string', min_length => 1, max_length => 16 },
        },
        controller => 'User',
        method => 'verify_email',
        swagger => { summary => '验证用户邮箱' },
    },
    DELETE => {
        params => {
            email => { type => 'email', required => 1, max_length => 254 },
        },
        controller => 'User',
        method => 'delete_email',
        swagger => { summary => '删除用户邮箱' },
    },
},
'/user/service' => {
    swagger => { tags => '用户服务' },
    GET => {
        controller => 'USObject',
        params => {
            user_service_id => { type => 'integer', min => 1 },
        },
        swagger => { summary => '用户服务列表' },
    },
    DELETE => {
        controller => 'USObject',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
        },
        swagger => { summary => '删除用户服务' },
    },
    POST => {
        controller => 'USObject',
        method => 'api_add_description',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
            description     => { type => 'string', required => 1, max_length => 254 },
        },
        swagger => { summary => '修改服务备注' },
    },
},
'/user/service/stop' => {
    swagger => { tags => '用户服务' },
    POST => {
        controller => 'USObject',
        method => 'block_force',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
        },
        swagger => { summary => '停用用户服务' },
    },
},
'/user/service/change' => {
    swagger => { tags => '用户服务' },
    POST => {
        controller => 'USObject',
        method => 'change',
        params => {
            user_service_id => { type => 'integer', required => 1, min => 1 },
            service_id      => { type => 'integer', required => 1, min => 1 },
            finish_active   => { type => 'boolean' },
        },
        swagger => { summary => '更换套餐' },
    },
},
'/user/withdraw' => {
    swagger => { tags => '用户' },
    GET => {
        controller => 'Withdraw',
        swagger => { summary => '账户扣费' },
    },
},
'/user/autopayment' => {
    swagger => { tags => '用户' },
    GET => {
        params => {},
        controller => 'User',
        method => 'list_autopayments',
        swagger => { summary => '用户自动付款方式列表' },
    },
    DELETE => {
        controller => 'User',
        method => 'delete_autopayment',
        params => {
            pay_system => { type => 'string', max_length => 64 },
        },
        args => {
            format => 'json',
        },
        swagger => { summary => '删除用户自动付款方式' },
    },
},
'/user/pay' => {
    swagger => { tags => '付款记录' },
    GET => {
        controller => 'Pay',
        swagger => { summary => '用户付款记录列表' },
    },
},
'/user/pay/forecast' => {
    swagger => { tags => '付款记录' },
    GET => {
        params => {
            days           => { type => 'integer', min => 1, max => 90 },
            consider_today => { type => 'boolean' },
            blocked        => { type => 'boolean' },
        },
        controller => 'Pay',
        method => 'forecast',
        swagger => { summary => '预计应付金额' },
    },
},
'/user/pay/paysystems' => {
    swagger => { tags => '付款记录' },
    GET => {
        params => {
            amount    => { type => 'number', min => 0 },
            paysystem => { type => 'string', max_length => 64 },
            pp        => { type => 'boolean' },
        },
        controller => 'Pay',
        method => 'api_paysystems',
        swagger => { summary => '支付方式' },
    },
},
'/service/order' => {
    swagger => { tags => '服务' },
    GET => {
        params => {},
        controller => 'Service',
        method => 'api_price_list',
        swagger => { summary => '可订购服务列表' },
    },
    PUT => {
        controller => 'USObject',
        method => 'create_for_api_safe',
        params => {
            service_id => { type => 'integer', required => 1, min => 1 },
        },
        swagger => { summary => '订购服务' },
    },
},
'/service' => {
    swagger => { tags => '服务' },
    GET => {
        swagger => { summary => '服务详情' },
        controller => 'Service',
        params => {
            service_id => { type => 'integer', required => 1, min => 1 },
        },
    },
},
'/template/*' => {
    swagger => { tags => '模板' },
    splat_to => 'id',
    route_methods(
    GET => {
        params => {
            dry_run => { type => 'boolean' },
            usi => { type => 'integer', min => 1 },
            format => { type => 'string', enum => ['default','plain','html','json','other','qrcode','qrcode_png'] },
        },
        controller => 'Template',
        method => 'parse_for_api',
        args => {
            format => 'plain',
        },
        swagger => { summary => '执行模板' },
    },
        ['PUT','POST','DELETE'] => {
        params => {},
        controller => 'Template',
        method => 'parse_for_api',
        skip_auto_parse_json => 1,
        args => {
            format => 'plain',
        },
        swagger => { summary => '带参数执行模板' },
    },
    ),
},
'/public/*' => {
    swagger => { tags => '模板' },
    splat_to => 'id',
    route_methods(
    GET => {
        params => {
            format => { type => 'string', enum => ['default','plain','html','json','other','qrcode','qrcode_png'] },
        },
        user_id => 1,
        controller => 'Template',
        method => 'parse_for_public',
            args => {
                format => 'plain',
            },
        swagger => { summary => '执行公开模板' },
    },
        ['PUT','POST','DELETE'] => {
        params => {},
        user_id => 1,
        controller => 'Template',
        method => 'parse_for_public',
        skip_auto_parse_json => 1,
            args => {
                format => 'plain',
            },
        swagger => { summary => '带参数执行公开模板' },
    },
    ),
},
# метод для случаев, когда нужно сохранить ещё и settings
'/storage/manage' => {
    swagger => { tags => '存储' },
    GET => {
        params => {},
        controller => 'Storage',
        swagger => { summary => '数据列表' },
    },
    PUT => { #TODO
        params => {},
        controller => 'Storage',
        swagger => { summary => '创建存储数据' },
    },
    POST => { #TODO
        params => {},
        controller => 'Storage',
        swagger => { summary => '修改存储数据' },
    },
    DELETE => { #TODO
        params => {},
        controller => 'Storage',
        swagger => { summary => '删除存储数据' },
    },
},
'/storage/manage/*' => {
    swagger => { tags => '存储' },
    splat_to => 'name',
    GET => {
        params => {},
        controller => 'Storage',
        method => 'read',
        args => {
            format => 'plain',
        },
        swagger => { summary => '读取存储数据' },
    },
    PUT => {
        params => {},
        controller => 'Storage',
        method => 'add',
        skip_auto_parse_json => 1,
        allow_text_plain => 1,
        args => {
            format => 'plain',
        },
        swagger => { summary => '创建存储数据' },
    },
    POST => {
        params => {},
        controller => 'Storage',
        method => 'replace',
        skip_auto_parse_json => 1,
        allow_text_plain => 1,
        args => {
            format => 'plain',
        },
        swagger => { summary => '修改存储数据' },
    },
    DELETE => {
        params => {},
        controller => 'Storage',
        method => 'delete',
        swagger => { summary => '删除存储数据' },
    },
},
'/storage/download/*' => {
    swagger => { tags => '存储' },
    splat_to => 'name',
    GET => {
        params => {},
        controller => 'Storage',
        method => 'download',
        args => {
            format => 'plain',
        },
        swagger => { summary => '下载存储数据' },
    },
},
'/promo' => {
    swagger => { tags => '优惠码' },
    GET => {
        params => {},
        controller => 'Promo',
        method => 'api_get',
        swagger => {
            summary => '用户优惠码列表',
            responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    promo_code => {
                                        type => 'string',
                                    },
                                    created => {
                                        type => 'string',
                                        format => 'date-time',
                                    },
                                    expire => {
                                        type => 'string',
                                        format => 'date-time',
                                    },
                                    reusable => {
                                        type => 'integer',
                                        enum => [0, 1],
                                    },
                                    status => {
                                        type => 'integer',
                                        enum => [0, 1],
                                    },
                                    used => {
                                        type => 'integer',
                                        enum => [0, 1],
                                        description => '优惠码是否已使用（仅限一次性优惠码，可重复使用时始终为 0）',
                                    },
                                    used_date => {
                                        type => 'string',
                                        format => 'date-time',
                                        description => '优惠码使用时间',
                                    },
                                    used_by => {
                                        type => 'integer',
                                        description => '使用优惠码的用户 ID',
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/promo/apply/*' => {
    swagger => { tags => '优惠码' },
    splat_to => 'code',
    GET => {
        params => {},
        controller => 'Promo',
        method => 'api_apply',
        args => {
            format => 'json',
        },
        swagger => { summary => '使用优惠码' },
    },
},
'/admin/system/version' => {
    GET => {
        params => {},
        controller => 'Config',
        method => 'version_info',
        args => {
            format => 'json',
        },
    },
},
'/admin/service' => {
    swagger => { tags => '服务' },
    GET => {
        params => {
            service_id => { type => 'integer', min => 1 },
        },
        controller => 'Service',
        swagger => { summary => '获取服务' },
    },
    PUT => {
        controller => 'Service',
        swagger => { summary => '创建服务' },
    },
    POST => {
        controller => 'Service',
        swagger => { summary => '修改服务' },
    },
    DELETE => {
        params => {
            service_id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Service',
        swagger => { summary => '删除服务' },
    },
},
'/admin/service/order' => {
    swagger => { tags => ['服务','用户服务'] },
    GET => {
        params => {},
        controller => 'Service',
        method => 'api_price_list',
        swagger => { summary => '可订购服务列表' },
    },
    PUT => {
        params => {
            user_id    => { type => 'integer', required => 1, min => 1 },
            service_id => { type => 'integer', required => 1, min => 1 },
            months     => { type => 'number', min => 0.001 },
            cost       => { type => 'number', min => 0 },
            settings   => { type => 'object' },
        },
        controller => 'USObject',
        method => 'create_for_api',
        swagger => { summary => '为用户订购服务' },
    },
},
'/admin/service/children' => {
    swagger => { tags => '服务' },
    GET => {
        params => {
            service_id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Service',
        method => 'api_subservices_list',
        swagger => { summary => '子服务列表' },
    },
    POST => {
        params => {
            service_id => { type => 'integer', required => 1, min => 1 },
            children   => { type => 'array', required => 1 },
        },
        controller => 'Service',
        method => 'children',
        swagger => { summary => '修改子服务列表' },
    },
},
'/admin/service/event' => {
    swagger => { tags => '事件' },
    GET => {
        controller => 'Events',
        swagger => { summary => '事件列表' },
    },
    PUT => {
        controller => 'Events',
        swagger => { summary => '创建事件' },
    },
    POST => {
        controller => 'Events',
        swagger => { summary => '修改事件' },
    },
    DELETE => {
        params => {
            id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Events',
        swagger => { summary => '删除事件' },
    },
},
'/admin/user' => {
    swagger => { tags => '用户' },
    GET => {
        controller => 'User',
        swagger => { summary => '客户列表' },
    },
    PUT => {
        controller => 'User',
        method => 'reg',
        swagger => { summary => '创建客户' },
    },
    POST => {
        controller => 'User',
        swagger => { summary => '修改客户' },
    },
    DELETE => {
        controller => 'User',
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            force => { type => 'boolean' },
        },
        swagger => { summary => '删除客户' },
    },
},
'/admin/user/group' => {
    swagger => { tags => '用户组' },
    GET => {
        params => {
            gid  => { type => 'integer', min => 1 },
        },
        controller => 'User::Groups',
        swagger => { summary => '获取用户组列表' },
    },
    PUT => {
        controller => 'User::Groups',
        params => {
            name           => { type => 'string', required => 1, min_length => 1, max_length => 255 },
            is_admin       => { type => 'boolean' },
            default_policy => { type => 'string', enum => ['allow','deny'] },
            rules          => { type => 'array' },
        },
        swagger => { summary => '创建用户组' },
    },
    POST => {
        controller => 'User::Groups',
        params => {
            gid            => { type => 'integer', required => 1, min => 1 },
            name           => { type => 'string', min_length => 1, max_length => 255 },
            is_admin       => { type => 'boolean' },
            default_policy => { type => 'string', enum => ['allow','deny'] },
            rules          => { type => 'array' },
        },
        swagger => { summary => '修改用户组' },
    },
    DELETE => {
        params => {
            gid => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'User::Groups',
        swagger => { summary => '删除用户组' },
    },
},
'/admin/user/search' => {
    swagger => { tags => '用户' },
    GET => {
        params => {
            text => { type => 'string', min_length => 1, max_length => 128 },
        },
        controller => 'User',
        method => 'api_search_for_admins',
        swagger => { summary => '搜索客户' },
    },
},
'/admin/user/accounts' => {
    swagger => { tags => '用户' },
    GET => {
        controller => 'User::Logins',
        swagger    => { summary => '登录账号列表' },
    },
    PUT => {
        controller => 'User::Logins',
        swagger    => { summary => '添加登录账号' },
    },
    POST => {
        params => {
            login   => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            type    => { type => 'string', required => 1, min_length => 1, max_length => 32 },
            user_id => { type => 'integer', required => 1, min => 1 },
            password => { type => 'string', min_length => 8, max_length => 64 },
            settings => { type => 'object' },
            primary => { type => 'boolean' },
        },
        controller => 'User::Logins',
        swagger    => { summary => '修改登录账号' },
    },
    DELETE => {
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            login   => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            type    => { type => 'string', required => 1, min_length => 1, max_length => 32 },
        },
        controller => 'User::Logins',
        method     => 'api_delete',
        swagger    => { summary => '删除登录账号' },
    },
},
'/admin/user/passwd' => {
    swagger => { tags => '用户' },
    POST => {
        controller => 'User',
        method => 'passwd',
        params => {
            user_id  => { type => 'integer', required => 1, min => 1 },
            password => { type => 'string',  required => 1, min_length => 6, max_length => 128 },
            login    => { type => 'string', min_length => 1, max_length => 128 },
        },
        swagger => { summary => '修改客户密码' },
    },
},
'/admin/user/payment' => {
    swagger => { tags => '用户' },
    PUT => {
        controller => 'User',
        method => 'payment',
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            money   => { type => 'number',  required => 1 },
            pay_system_id => { type => 'string' },
            comment => { type => 'object' },
        },
        swagger => { summary => '向客户账户入账' },
    },
},
'/admin/user/profile' => {
    GET => {
        params => {},
        controller => 'Profile',
    },
    PUT => {
        controller => 'Profile',
    },
    POST => {
        controller => 'Profile',
    },
    DELETE => {
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            id      => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Profile',
    },
},
'/admin/user/pay' => {
    swagger => { tags => '付款记录' },
    GET => {
        controller => 'Pay',
        swagger => { summary => '客户付款记录列表' },
    },
    DELETE => {
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            id      => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Pay',
        swagger => { summary => '删除客户付款记录' },
    },
},
'/admin/user/bonus' => {
    swagger => { tags => '奖励' },
    GET => {
        controller => 'Bonus',
        swagger => { summary => '客户奖励记录列表' },
    },
    PUT => {
        controller => 'Bonus',
        swagger => { summary => '创建奖励记录' },
    },
    POST => {
        controller => 'Bonus',
        swagger => { summary => '修改奖励记录' },
    },
    DELETE => {
        params => {
            id      => { type => 'integer', required => 1, min => 1 },
            user_id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Bonus',
        swagger => { summary => '删除奖励记录' },
    },
},
'/admin/user/service' => {
    swagger => { tags => '用户服务' },
    GET => {
        params => {
            user_id         => { type => 'integer', min => 1 },
            parent          => { type => 'integer', min => 1 },
            service_id      => { type => 'integer', min => 1 },
            user_service_id => { type => 'integer', min => 1 },
        },
        controller => 'UserService',
        swagger => { summary => '客户服务列表' },
    },
    PUT => {
        controller => 'USObject',
    },
    POST => {
        controller => 'USObject',
        swagger => { summary => '修改客户服务' },
    },
    DELETE => {
        params => {
            user_id         => { type => 'integer', required => 1, min => 1 },
            user_service_id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'USObject',
        swagger => { summary => '删除客户服务' },
    },
},
'/admin/user/service/categories' => {
    swagger => { tags => '用户服务' },
    GET => {
        params => {},
        controller => 'Service',
        method => 'categories',
        swagger => { summary => '获取服务分类列表' },
    },
},
'/admin/user/service/withdraw' => {
    swagger => { tags => '扣费记录' },
    GET => {
        params => {
            user_id     => { type => 'integer', min => 1 },
            withdraw_id => { type => 'integer', min => 1 },
        },
        controller => 'Withdraw',
        swagger => { summary => '获取客户扣费记录' },
    },
    PUT => {
        controller => 'Withdraw',
        swagger => { summary => '创建客户扣费记录' },
    },
    POST => {
        controller => 'Withdraw',
        swagger => { summary => '修改客户扣费记录' },
    },
    DELETE => {
        params => {
            user_id     => { type => 'integer', required => 1, min => 1 },
            withdraw_id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Withdraw',
        swagger => { summary => '删除客户扣费记录' },
    },
},
'/admin/user/service/status' => {
    swagger => { tags => '用户服务' },
    POST => {
        controller => 'USObject',
        method => 'set_status_manual',
        params => {
            user_id         => { type => 'integer', required => 1, min => 1 },
            user_service_id => { type => 'integer', required => 1, min => 1 },
            status          => { type => 'string', required => 1, enum => ['ACTIVE','BLOCK'] },
        },
        swagger => { summary => '修改客户服务状态' },
    },
},
'/admin/user/service/stop' => {
    swagger => { tags => '用户服务' },
    POST => {
        controller => 'USObject',
        method => 'block_force',
        params => {
            user_id         => { type => 'integer', required => 1, min => 1 },
            user_service_id => { type => 'integer', required => 1, min => 1 },
        },
        swagger => { summary => '停用客户服务' },
    },
},
'/admin/user/service/activate' => {
    swagger => { tags => '用户服务' },
    POST => {
        controller => 'USObject',
        method => 'activate_force',
        params => {
            user_id         => { type => 'integer', required => 1, min => 1 },
            user_service_id => { type => 'integer', required => 1, min => 1 },
        },
        swagger => { summary => '恢复客户服务' },
    },
},
'/admin/user/service/touch' => {
    swagger => { tags => '用户服务' },
    POST => {
        controller => 'USObject',
        method => 'touch_api',
        params => {
            user_id         => { type => 'integer', required => 1, min => 1 },
            user_service_id => { type => 'integer', required => 1, min => 1 },
        },
        swagger => { summary => '处理服务' },
    },
},
'/admin/user/service/change' => {
    swagger => { tags => '用户服务' },
    POST => {
        controller => 'USObject',
        method => 'change',
        params => {
            user_id              => { type => 'integer', required => 1, min => 1 },
            user_service_id      => { type => 'integer', required => 1, min => 1 },
            service_id           => { type => 'integer', required => 1, min => 1 },
            finish_active        => { type => 'boolean' },
            allow_partial_period => { type => 'boolean' },
        },
        swagger => { summary => '更换客户套餐' },
    },
},
'/admin/user/service/spool' => {
    swagger => { tags => ['用户服务','任务'] },
    GET => {
        controller => 'USObject',
        method => 'api_spool_commands',
        params => {
            user_id         => { type => 'integer', required => 1, min => 1 },
            user_service_id => { type => 'integer', required => 1, min => 1 },
        },
        swagger => { summary => '获取客户服务的当前任务' },
    },
},
'/admin/user/session' => {
    swagger => { tags => '用户' },
    PUT => {
        controller => 'User',
        method => 'gen_session',
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
        },
        args => {
            format => 'json',
        },
        swagger => {
            summary => '为客户生成 session_id',
                responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    id => {
                                        type => 'string'
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/admin/server' => {
    swagger => { tags => '服务器' },
    GET => {
        params => {
            server_id  => { type => 'integer', min => 1 },
        },
        controller => 'Server',
        swagger => { summary => '获取服务器列表' },
    },
    PUT => {
        controller => 'Server',
        swagger => { summary => '创建服务器' },
    },
    POST => {
        controller => 'Server',
        swagger => { summary => '修改服务器' },
    },
    DELETE => {
        params => {
            server_id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Server',
        swagger => { summary => '删除服务器' },
    },
},
'/admin/server/group' => {
    swagger => { tags => '服务器组' },
    GET => {
        params => {
            group_id  => { type => 'integer', min => 1 },
        },
        controller => 'ServerGroups',
        swagger => { summary => '获取服务器组列表' },
    },
    PUT => {
        controller => 'ServerGroups',
        swagger => { summary => '创建服务器组' },
    },
    POST => {
        controller => 'ServerGroups',
        swagger => { summary => '修改服务器组' },
    },
    DELETE => {
        params => {
            group_id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'ServerGroups',
        swagger => { summary => '删除服务器组' },
    },
},
'/admin/server/identity' => {
    swagger => { tags => 'SSH 密钥' },
    GET => {
        params => {
            id     => { type => 'integer', min => 1 },
        },
        controller => 'Identities',
        swagger => { summary => 'SSH 密钥列表' },
    },
    PUT => {
        controller => 'Identities',
        swagger => { summary => '保存新的 SSH 密钥' },
    },
    POST => {
        controller => 'Identities',
        swagger => { summary => '修改 SSH 密钥' },
    },
    DELETE => {
        params => {
            id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Identities',
        swagger => { summary => '删除 SSH 密钥' },
    },
},
'/admin/server/identity/generate' => {
    swagger => { tags => 'SSH 密钥' },
    GET => {
        params => {
            type => { type => 'string', enum => ['rsa','dsa','ecdsa','ed25519'] },
        },
        controller => 'Identities',
        method => 'generate_key_pair',
        swagger => { summary => '生成 SSH 密钥' },
    },
},
'/admin/spool' => {
    swagger => { tags => '任务' },
    GET => {
        params => {
            id              => { type => 'integer', min => 1 },
            user_id         => { type => 'integer', min => 1 },
            user_service_id => { type => 'integer', min => 1 },
            status          => { type => 'string' },
        },
        controller => 'Spool',
        swagger => { summary => '当前任务列表' },
    },
    PUT => {
        controller => 'Spool',
        swagger => { summary => '创建任务' },
    },
    POST => {
        controller => 'Spool',
        swagger => { summary => '修改任务' },
    },
    DELETE => {
        params => {
            id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Spool',
        swagger => { summary => '删除任务' },
    },
},
'/admin/spool/statuses' => {
    swagger => { tags => '任务' },
    GET => {
        params => {},
        controller => 'Spool',
        method => 'statuses',
        swagger => { summary => '任务状态' },
    },
},
'/admin/spool/queues' => {
    swagger => { tags => '任务' },
    GET => {
        params => {
            id   => { type => 'integer', min => 1 },
            name => { type => 'string' },
        },
        controller => 'SpoolQueue',
        swagger => { summary => '任务队列列表' },
    },
    PUT => {
        controller => 'SpoolQueue',
        swagger => { summary => '创建任务队列' },
    },
    POST => {
        controller => 'SpoolQueue',
        swagger => { summary => '修改任务队列' },
    },
},
'/admin/spool/queues/delete' => {
    swagger => { tags => '任务' },
    POST => {
        params => { id => { type => 'integer', required => 1, min => 1 } },
        controller => 'SpoolQueue',
        method => 'api_delete_cascade',
        swagger => { summary => '删除队列并归档全部任务' },
    },
},
'/admin/spool/queues/pause' => {
    swagger => { tags => '任务' },
    POST => {
        params => { id => { type => 'integer', required => 1, min => 1 } },
        controller => 'SpoolQueue',
        method => 'api_pause',
        swagger => { summary => '暂停任务队列' },
    },
},
'/admin/spool/queues/resume' => {
    swagger => { tags => '任务' },
    POST => {
        params => { id => { type => 'integer', required => 1, min => 1 } },
        controller => 'SpoolQueue',
        method => 'api_resume',
        swagger => { summary => '恢复任务队列' },
    },
},
'/admin/spool/history' => {
    swagger => { tags => '任务' },
    GET => {
        controller => 'SpoolHistory',
        swagger => { summary => '已归档任务列表' },
    },
},
'/admin/spool/manual/*' => {
    swagger => { tags => '任务' },
    splat_to => 'action',
    POST => {
        params => {
            id => { type => 'integer', required => 1, min => 1 },
            action => { type => 'string', enum => ['success','pause','retry','resume'] },
        },
        controller => 'Spool',
        method => 'api_manual_action',
        swagger => { summary => '手动修改任务状态' },
    },
},
'/admin/template' => {
    swagger => { tags => '模板' },
    GET => {
        controller => 'Template',
        method => 'list',
        common_params => 1,
        swagger => { summary => '模板列表' },
    },
    PUT => {
        controller => 'Template',
        allow_text_plain => 1,
        swagger => { summary => '创建模板' },
        args => {
            format => 'plain',
        },
    },
    POST => {
        controller => 'Template',
        allow_text_plain => 1,
        swagger => { summary => '修改模板' },
        args => {
            format => 'plain',
        },
    },
    DELETE => {
        params => {
            id => { type => 'string', required => 1, min => 1 },
        },
        controller => 'Template',
        swagger => { summary => '删除模板' },
    },
},
'/admin/template/*' => {
    swagger => { tags => '模板' },
    splat_to => 'id',
    GET => {
        controller => 'Template',
        method => 'parse_for_api',
        common_params => 1,
        args => {
            format => 'plain',
            do_not_parse => 1,
        },
        swagger => { summary => '读取模板' },
    },
    PUT => {
        controller => 'Template',
        args => {
            format => 'plain',
        },
    },
    POST => {
        controller => 'Template',
        args => {
            format => 'plain',
        },
    },
    DELETE => {
        params => {
            id  => { type => 'string', required => 1, min => 1 },
        },
        controller => 'Template',
    },
},
'/admin/storage/manage' => {
    swagger => { tags => '存储' },
    GET => {
        params => {
            user_id => { type => 'integer', min => 1 },
            name    => { type => 'string', max_length => 255 },
        },
        controller => 'Storage',
        swagger => { summary => '获取存储对象列表' },
    },
    PUT => {
        controller => 'Storage',
        swagger => { summary => '创建存储对象' },
    },
    POST => {
        controller => 'Storage',
        method => 'replace',
        swagger => { summary => '修改存储对象数据' },
    },
    DELETE => {
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            name    => { type => 'string', required => 1, min_length => 1, max_length => 255 },
        },
        controller => 'Storage',
        method => 'delete',
        swagger => { summary => '删除存储对象' },
    },
},
'/admin/storage/manage/*' => {
    swagger => { tags => '存储' },
    splat_to => 'name',
    GET => {
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            name => { type => 'string', required => 1, min_length => 1, max_length => 32 },
        },
        controller => 'Storage',
        method => 'read',
        args => {
            format => 'other',
        },
        swagger => { summary => '获取存储对象' },
    },
    POST => {
        controller => 'Storage',
        method => 'replace',
    },
    DELETE => {
        params => {
            user_id => { type => 'integer', required => 1, min => 1 },
            name => { type => 'string', required => 1, min_length => 1, max_length => 32 },
        },
        controller => 'Storage',
        method => 'delete',
    },
},
'/admin/config' => {
    swagger => { tags => '配置' },
    GET => {
        params => {
            key    => { type => 'string', max_length => 128 },
        },
        controller => 'Config',
        swagger => { summary => '读取配置' },
    },
    PUT => {
        controller => 'Config',
        swagger => { summary => '创建配置项' },
    },
    POST => {
        controller => 'Config',
        swagger => { summary => '修改配置项' },
    },
    DELETE => {
        params => {
            key => { type => 'string', required => 1, min_length => 1, max_length => 128 },
        },
        controller => 'Config',
        swagger => { summary => '删除配置项' },
    },
},
'/admin/config/*' => {
    swagger => { tags => '配置' },
    splat_to => 'key',
    GET => {
        params => {},
        controller => 'Config',
        method => 'api_data_by_name',
        swagger => { summary => '获取配置项' },
    },
    POST => {
        controller => 'Config',
        params => {},
        method => 'api_set_value',
        skip_auto_parse_json => 1,
        swagger => { summary => '修改配置项' },
    },
    DELETE => {
        params => {
            value => { type => 'string', required => 1, min_length => 1, max_length => 256 },
        },
        controller => 'Config',
        method => 'api_delete_value',
        swagger => { summary => '删除配置值或配置项' },
    },
},
'/admin/console' => {



},
'/admin/transport/ssh/test' => {
    PUT => {
        params => {
            host   => { type => 'string', required => 1, min_length => 1, max_length => 255 },
            key_id => { type => 'integer', required => 1, min => 1 },
            server_id => { type => 'integer', min => 1 },
            template_id => { type => 'string', min_length => 1 },
            cmd => { type => 'string', min_length => 1 },
            event_name => { type => 'string', min_length => 1},
            timeout => { type => 'integer', min => 1, default => 600 },
        },
        controller => 'Transport::Ssh',
        method => 'ssh_test',
    },
},
'/admin/transport/ssh/init' => {
    PUT => {
        params => {
            host        => { type => 'string', required => 1, min_length => 1, max_length => 255 },
            key_id      => { type => 'integer', required => 1, min => 1 },
            server_id => { type => 'integer', required => 1, min => 1 },
            template_id => { type => 'string', min_length => 1 },
            cmd => { type => 'string', min_length => 1 },
            event_name => { type => 'string', min_length => 1},
            timeout => { type => 'integer', min => 1, default => 600 },
        },
        controller => 'Transport::Ssh',
        method => 'ssh_init',
    },
},
'/admin/promo' => {
    swagger => { tags => '优惠码' },
    GET => {
        params => {
            id     => { type => 'integer', min => 1 },
        },
        controller => 'Promo',
        swagger => { summary => '优惠码列表' },
    },
    PUT => {
        controller => 'Promo',
        method => 'generate',
        swagger => { summary => '生成优惠码' },
    },
    POST => {
        controller => 'Promo',
        method => 'update',
        swagger => { summary => '修改优惠码' },
    },
    DELETE => {
        params => {
            id => { type => 'integer', required => 1, min => 1 },
        },
        controller => 'Promo',
        method => 'delete',
        swagger => { summary => '删除优惠码' },
    },
},
'/admin/promo/*' => {
    POST => {
        controller => 'Promo',
        method => 'update',
    },
    DELETE => {
        controller => 'Promo',
        method => 'delete',
    },
},
'/admin/logs/api' => {
    swagger => { tags => '日志' },
    GET => {
        params => {
            user_id       => { type => 'integer', min => 1 },
            response_code => { type => 'integer', min => 0 },
            url           => { type => 'string',  max_length => 512 },
            method        => { type => 'string',  max_length => 10 },
        },
        controller => 'Logs::Api',
        swagger => { summary => 'API 日志列表' },
    },
},
'/admin/analytics' => {
    GET => {
        params => {
            months => { type => 'integer' },
            no_cache => { type => 'boolean' },
        },
        controller => 'Analytics',
        method => 'api_report',
    },
},
'/admin/topology' => {
    swagger => { tags => '拓扑' },
    GET => {
        params => {
            event   => { type => 'string', pattern => '^\w+$' },
            refresh => { type => 'boolean' },
        },
        controller => 'Topology',
        method => 'api_graph',
        args => {
            format => 'json',
        },
        swagger => { summary => '服务、事件、模板与服务器的关联拓扑' },
    },
},
'/admin/topology/cache/clear' => {
    swagger => { tags => '拓扑' },
    POST => {
        params => {},
        controller => 'Topology',
        method => 'clear_cache',
        swagger => { summary => '清除 Redis 中的拓扑缓存' },
    },
},
'/admin/analytics/cache/clear' => {
    POST => {
        params => {},
        controller => 'Analytics',
        method => 'clear_cache',
    },
},
'/telegram/user' => {
    swagger => {
        tags => 'Telegram bot',
    },
    GET => {
        params => {},
        controller => 'Transport::Telegram',
        method => 'user_tg_settings',
        args => {
            format => 'json',
        },
        swagger => {
            summary => '获取 Telegram 机器人用户设置',
        },
    },
    POST => {
        params => {},
        controller => 'Transport::Telegram',
        method => 'api_set_user_tg_settings',
        skip_auto_parse_json => 1,
        args => {
            format => 'json',
        },
        swagger => {
            summary => '修改 Telegram 机器人用户设置',
        },
    },
    DELETE => {
        params => {},
        controller => 'Transport::Telegram',
        method => 'api_delete_user_tg_settings',
        args => {
            format => 'json',
        },
        swagger => {
            summary => '删除用户 Telegram 账号',
        },
    },
},
'/telegram/bot' => {
    POST => {
        params => {
            # Telegram Update object fields (https://core.telegram.org/bots/api#update)
            tg_profile              => { type => 'string' },
            update_id               => { type => 'integer', min => 1 },
            message                 => { type => 'object' },
            edited_message          => { type => 'object' },
            channel_post            => { type => 'object' },
            edited_channel_post     => { type => 'object' },
            business_connection     => { type => 'object' },
            business_message        => { type => 'object' },
            edited_business_message => { type => 'object' },
            deleted_business_messages => { type => 'object' },
            guest_message           => { type => 'object' },
            message_reaction        => { type => 'object' },
            message_reaction_count  => { type => 'object' },
            inline_query            => { type => 'object' },
            chosen_inline_result    => { type => 'object' },
            callback_query          => { type => 'object' },
            shipping_query          => { type => 'object' },
            pre_checkout_query      => { type => 'object' },
            purchased_paid_media    => { type => 'object' },
            poll                    => { type => 'object' },
            poll_answer             => { type => 'object' },
            my_chat_member          => { type => 'object' },
            chat_member             => { type => 'object' },
            chat_join_request       => { type => 'object' },
            chat_boost              => { type => 'object' },
            removed_chat_boost      => { type => 'object' },
            managed_bot             => { type => 'object' },
        },
        skip_check_auth => 1,
        skip_errors => 1, # do not send report errors to TG API
        controller => 'Transport::Telegram',
        method => 'process_message',
        args => {
            format => 'json',
        },
    },
},
'/telegram/bot/*' => {
    swagger => {
        tags => 'Telegram bot',
    },
    splat_to => 'template',
    POST => {
        params => {
            # Telegram Update object fields (https://core.telegram.org/bots/api#update)
            tg_profile              => { type => 'string' },
            update_id               => { type => 'integer', min => 1 },
            message                 => { type => 'object' },
            edited_message          => { type => 'object' },
            channel_post            => { type => 'object' },
            edited_channel_post     => { type => 'object' },
            business_connection     => { type => 'object' },
            business_message        => { type => 'object' },
            edited_business_message => { type => 'object' },
            deleted_business_messages => { type => 'object' },
            guest_message           => { type => 'object' },
            message_reaction        => { type => 'object' },
            message_reaction_count  => { type => 'object' },
            inline_query            => { type => 'object' },
            chosen_inline_result    => { type => 'object' },
            callback_query          => { type => 'object' },
            shipping_query          => { type => 'object' },
            pre_checkout_query      => { type => 'object' },
            purchased_paid_media    => { type => 'object' },
            poll                    => { type => 'object' },
            poll_answer             => { type => 'object' },
            my_chat_member          => { type => 'object' },
            chat_member             => { type => 'object' },
            chat_join_request       => { type => 'object' },
            chat_boost              => { type => 'object' },
            removed_chat_boost      => { type => 'object' },
            managed_bot             => { type => 'object' },
        },
        skip_check_auth => 1,
        skip_errors => 1, # do not send report errors to TG API
        controller => 'Transport::Telegram',
        method => 'process_message',
        args => {
            format => 'json',
        },
        swagger => {
            summary => '接收 Telegram 数据',
        },
    },
},
'/telegram/set_webhook' => {
    POST => {
        params => {
            url             => { type => 'string', required => 1, min_length => 1, max_length => 2048 },
            token           => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            secret          => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            template_id     => { type => 'string', required => 1, min_length => 1 },
            tg_profile      => { type => 'string', required => 1, min_length => 1 },
            allowed_updates => { type => 'array' },
        },
        controller => 'Transport::Telegram',
        method => 'set_webhook',
        args => {
            format => 'json',
        },
        swagger => {
            summary => '设置 Telegram 机器人 Webhook',
        },
    },
},
'/telegram/delete_webhook' => {
    POST => {
        params => {
            token => { type => 'string', required => 1, min_length => 1, max_length => 128 },
        },
        skip_check_auth => 1,
        controller => 'Transport::Telegram',
        method => 'delete_webhook',
        args => {
            format => 'json',
        },
        swagger => {
            summary => '删除 Telegram 机器人 Webhook',
        },
    },
},

# ─── MAX (VK / OK messenger) bot ─────────────────────────────────────────────
'/max/bot/*' => {
    swagger  => { tags => 'MAX bot' },
    splat_to => 'template',
    POST => {
        params => {
            profile     => { type => 'string' },
            update_type => { type => 'string' },
            timestamp   => { type => 'integer' },
            message     => { type => 'object' },
            callback    => { type => 'object' },
            user        => { type => 'object' },
            chat_id     => { type => 'integer' },
            user_id     => { type => 'integer' },
        },
        skip_check_auth => 1,
        skip_errors     => 1,
        controller => 'Transport::Max',
        method     => 'process_message',
        args       => { format => 'json' },
        swagger    => { summary => 'MAX 机器人 Webhook（使用模板）' },
    },
},
'/max/set_webhook' => {
    swagger => { tags => 'MAX bot' },
    POST => {
        params => {
            url          => { type => 'string', required => 1, min_length => 1, max_length => 2048 },
            token        => { type => 'string', required => 1, min_length => 1, max_length => 256 },
            secret       => { type => 'string', min_length => 5, max_length => 256 },
            template_id  => { type => 'string', required => 1, min_length => 1 },
            profile      => { type => 'string', min_length => 1 },
            update_types => { type => 'object' },
        },
        skip_check_auth => 1,
        controller => 'Transport::Max',
        method     => 'set_webhook',
        args       => { format => 'json' },
        swagger    => { summary => '设置 MAX 机器人 Webhook' },
    },
},

'/max/webapp/auth' => {
    swagger => { tags => 'MAX bot' },
    GET => {
        params => {
            initData => { type => 'string', required => 1, min_length => 1, max_length => 4096 },
            profile  => { type => 'string', min_length => 1, max_length => 64 },
        },
        skip_check_auth => 1,
        controller => 'Transport::Max',
        method     => 'webapp_auth',
        args       => { format => 'json' },
        swagger    => { summary => 'MAX WebApp 身份验证（验证 initData）' },
    },
},

'/telegram/webapp/auth' => {
    swagger => {
        tags => 'Telegram bot',
    },
    GET => {
        params => {
            initData => { type => 'string', required => 1, min_length => 1, max_length => 4096 },
            profile => { type => 'string', required => 1, min_length => 1, max_length => 32 },
        },
        skip_check_auth => 1,
        controller => 'Transport::Telegram',
        method => 'webapp_auth',
        args => {
            format => 'json',
        },
        swagger => {
            summary => 'Telegram 身份验证',
             responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    session_id => {
                                        type => 'string'
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/telegram/web/auth' => {
    swagger => {
        tags => 'Telegram bot',
    },
    POST => {
        params => {
            profile          => { type => 'string' },
            register_if_not_exists => { type => 'boolean' },
            bind_to_profile  => { type => 'boolean' },
            bind_only_if_new => { type => 'boolean' },
            session_id       => { type => 'string', min => 1 },
            # OIDC code flow
            code             => { type => 'string' },
            redirect_uri     => { type => 'string' },
            code_verifier    => { type => 'string' },
            client_id        => { type => 'string' },
            client_secret    => { type => 'string' },
            state            => { type => 'string' },
            expected_state   => { type => 'string' },
            id_token         => { type => 'string' },
            nonce            => { type => 'string' },
            # Legacy widget fields
            id               => { type => 'string' },
            first_name       => { type => 'string' },
            last_name        => { type => 'string' },
            username         => { type => 'string' },
            photo_url        => { type => 'string' },
            auth_date        => { type => 'string' },
            hash             => { type => 'string' },
            query            => { type => 'string' },
        },
        skip_check_auth => 1,
        controller => 'Transport::Telegram',
        method => 'web_auth',
        swagger => {
            summary => 'Telegram 登录验证（OIDC id_token 或旧版 Widget）',
             responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    session_id => {
                                        type => 'string'
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/telegram/web/auth/init' => {
    swagger => {
        tags => 'Telegram bot',
    },
    GET => {
        params => {
            profile                => { type => 'string' },
            redirect_uri           => { type => 'string' },
            return_url             => { type => 'string' },
            scope                  => { type => 'string' },
            register_if_not_exists => { type => 'boolean' },
            bind_to_profile        => { type => 'boolean' },
            bind_only_if_new       => { type => 'boolean' },
            session_id             => { type => 'string', min => 1 },
            ttl                    => { type => 'integer', min => 1 },
        },
        skip_check_auth => 1,
        controller => 'Transport::Telegram',
        method => 'telegram_oidc_init',
        swagger => {
            summary => '初始化 Telegram OIDC 登录（state、nonce、PKCE）',
            responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    auth_url => { type => 'string' },
                                    state => { type => 'string' },
                                    nonce => { type => 'string' },
                                    code_challenge => { type => 'string' },
                                    code_challenge_method => { type => 'string' },
                                    redirect_uri => { type => 'string' },
                                    expires_in => { type => 'number' },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/telegram/web/auth/start' => {
    swagger => {
        tags => 'Telegram bot',
    },
    GET => {
        params => {
            profile                => { type => 'string' },
            redirect_uri           => { type => 'string' },
            return_url             => { type => 'string' },
            scope                  => { type => 'string' },
            register_if_not_exists => { type => 'boolean' },
            bind_to_profile        => { type => 'boolean' },
            bind_only_if_new       => { type => 'boolean' },
            session_id             => { type => 'string', min => 1 },
            ttl                    => { type => 'integer', min => 1 },
        },
        skip_check_auth => 1,
        controller => 'Transport::Telegram',
        method => 'telegram_oidc_start_redirect',
        swagger => {
            summary => '重定向到 Telegram OAuth 登录',
            responses => {
                '302' => {
                    description => 'Redirect to Telegram OAuth',
                },
            },
        },
    },
},
'/telegram/web/callback' => {
    swagger => {
        tags => 'Telegram bot',
    },
    GET => {
        params => {
            profile                => { type => 'string' },
            register_if_not_exists => { type => 'boolean' },
            bind_to_profile        => { type => 'boolean' },
            bind_only_if_new       => { type => 'boolean' },
            session_id             => { type => 'string', min => 1 },
            # OIDC code flow
            code                   => { type => 'string' },
            redirect_uri           => { type => 'string' },
            return_url             => { type => 'string' },
            code_verifier          => { type => 'string' },
            state                  => { type => 'string' },
            expected_state         => { type => 'string' },
            client_id              => { type => 'string' },
            client_secret          => { type => 'string' },
            id_token               => { type => 'string' },
            nonce                  => { type => 'string' },
        },
        skip_check_auth => 1,
        controller => 'Transport::Telegram',
        method => 'web_auth_callback',
        swagger => {
            summary => 'Telegram 登录回调（OIDC 授权码流程）',
            responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    session_id => {
                                        type => 'string'
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/oauth2/init/*' => {
    swagger => { tags => 'oauth2' },
    splat_to => 'provider',
    GET => {
        params => {
            redirect_uri            => { type => 'string' },
            return_url              => { type => 'string' },
            bind_to_profile         => { type => 'boolean' },
            bind_only_if_new        => { type => 'boolean' },
            session_id              => { type => 'string' },
            ttl                     => { type => 'integer', min => 1 },
        },
        skip_check_auth => 1,
        controller => 'Auth::OAuth2',
        method => 'oauth2_init',
        swagger => {
            summary => '初始化 OAuth2 登录或绑定（Google/Yandex/VK/GitHub）：state、nonce、PKCE',
            responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    auth_url => { type => 'string' },
                                    state => { type => 'string' },
                                    nonce => { type => 'string' },
                                    code_challenge => { type => 'string' },
                                    code_challenge_method => { type => 'string' },
                                    redirect_uri => { type => 'string' },
                                    expires_in => { type => 'number' },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/oauth2/start/*' => {
    swagger => { tags => 'oauth2' },
    splat_to => 'provider',
    GET => {
        params => {
            redirect_uri            => { type => 'string' },
            return_url              => { type => 'string' },
            bind_to_profile         => { type => 'boolean' },
            bind_only_if_new        => { type => 'boolean' },
            session_id              => { type => 'string' },
            ttl                     => { type => 'integer', min => 1 },
        },
        skip_check_auth => 1,
        controller => 'Auth::OAuth2',
        method => 'oauth2_start_redirect',
        swagger => {
            summary => '重定向到 OAuth2 提供方进行登录或绑定',
            responses => {
                '302' => { description => 'Redirect to provider OAuth' },
            },
        },
    },
},
'/oauth2/callback/*' => {
    swagger => { tags => 'oauth2' },
    splat_to => 'provider',
    GET => {
        params => {
            bind_to_profile        => { type => 'boolean' },
            bind_only_if_new       => { type => 'boolean' },
            # SECURITY: нет клиентского uid — см. комментарий в /oauth2/init/*.
            session_id             => { type => 'string' },
            code                   => { type => 'string' },
            redirect_uri           => { type => 'string' },
            return_url             => { type => 'string' },
            code_verifier          => { type => 'string' },
            state                  => { type => 'string' },
            expected_state         => { type => 'string' },
        },
        skip_check_auth => 1,
        controller => 'Auth::OAuth2',
        method => 'oauth2_callback_redirect',
        swagger => {
            summary => 'OAuth2 登录或绑定回调（Google/Yandex/VK/GitHub）',
            responses => {
                '200' => {
                    content => {
                        'application/json' => {
                            schema => {
                                type => 'object',
                                properties => {
                                    session_id => { type => 'string' },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
},
'/admin/cloud/user' => {
    GET => {
        params => {},
        controller => 'Cloud',
        method => 'get_user',
    },
    PUT => {
        params => {
            login          => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            password       => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            captcha_token  => { type => 'string' },
            captcha_answer => { type => 'string' },
        },
        controller => 'Cloud',
        method => 'reg_user',
    },
},
'/admin/cloud/user/auth' => {
    swagger => {
        tags => 'Cloud SHM',
    },
    POST => {
        params => {
            login    => { type => 'string', required => 1, min_length => 1, max_length => 128 },
            password => { type => 'string', required => 1, min_length => 1, max_length => 128 },
        },
        controller => 'Cloud',
        method => 'login_user',
    },
    DELETE => {
        params => {},
        controller => 'Cloud',
        method => 'logout_user',
    },
},
'/admin/cloud/paysystems' => {
    GET => {
        params => {},
        controller => 'Cloud',
        method => 'paysystems',
    },
},
'/admin/cloud/currencies' => {
    GET => {
        params => {
            no_cache => { type => 'boolean' },
        },
        controller => 'Cloud::Currency',
        method => 'currencies',
    },
    POST => {
        params => {
            currencies => { type => 'object', required => 1 },
        },
        controller => 'Cloud::Currency',
        method => 'save',
    },
},
'/admin/cloud/proxy/*' => {
    splat_to => 'uri',
    GET => {
        params => {},
        controller => 'Cloud',
        method => 'proxy',
        args => {
            format => 'json',
        },
    },
    POST => {
        params => {},
        controller => 'Cloud',
        method => 'proxy',
        args => {
            format => 'json',
        },
    },
    PUT => {
        params => {},
        controller => 'Cloud',
        method => 'proxy',
        args => {
            format => 'json',
        },
    },
    DELETE => {
        params => {},
        controller => 'Cloud',
        method => 'proxy',
        args => {
            format => 'json',
        },
    },
}

};

$routes->{'/swagger.json'} //= {
    GET => {
        params => {},
        controller => 'Swagger',
        method => 'gen_swagger_json',
        skip_check_auth => 1,
        args => {
            routes => $routes,
            format => 'json',
        },
    },
};

$routes->{'/swagger_admin.json'} //= {
    GET => {
        params => {},
        controller => 'Swagger',
        method => 'gen_swagger_json',
        skip_check_auth => 1,
        args => {
            routes => $routes,
            admin_mode => 1,
            format => 'json',
        },
    },
};

$routes->{'/system/locations'} //= {
    swagger => { tags => '系统' },
    GET => {
        params => {},
        controller => 'Swagger',
        method => 'list_locations',
        args => {
            routes => $routes,
        },
        swagger => { summary => '可用用户 API 路径和方法' },
    },
};

$routes->{'/admin/system/locations'} //= {
    swagger => { tags => '系统' },
    GET => {
        params => {},
        controller => 'Swagger',
        method => 'list_locations',
        args => {
            routes => $routes,
            admin_mode => 1,
        },
        swagger => { summary => '可用管理 API 路径和方法' },
    },
};

state $router //= Router::Simple->new();
for my $uri ( keys %{ $routes } ) {
    for my $method ( 'GET','POST','PUT','DELETE' ) {
        next unless $routes->{$uri}->{$method};
        $routes->{$uri}->{$method}->{splat_to} = $routes->{$uri}->{splat_to} if $routes->{$uri}->{splat_to};
        $router->connect( sprintf("%s:%s", $method, $uri), $routes->{$uri}->{$method} );
    }
}

our $request_start = Time::HiRes::time();
my $uri = $ENV{PATH_INFO};
our %in;

if ( my $p = $router->match( sprintf("%s:%s", $ENV{REQUEST_METHOD}, $uri )) ) {

    my $api_descr = $p->{swagger}{summary};
    %in = parse_args( auto_parse_json => $p->{skip_auto_parse_json} ? 0 : 1 );
    $in{filter} = decode_json( $in{filter} ) if $in{filter};

    if ( my $splat = $p->{splat} ) {
        $in{ $p->{splat_to} || 'id' } = $splat->[0];
    }

    my $user = SHM->new(
        skip_check_auth => $p->{skip_check_auth},
        user_id => $p->{user_id},
    );

    if ( $user->is_blocked ) {
        _log_api_call( $user, code => 403, error => 'User is blocked', descr => $api_descr );
        print_header( status => 403 );
        print_json( { status => 403, error => "User is blocked"} );
        exit 0;
    }

    my $admin_mode;
    if ( $uri =~/^\/admin\// ) {
        unless ( $user->is_admin ) {
            _log_api_call( $user, code => 403, error => 'Permission denied', descr => $api_descr );
            print_header( status => 403 );
            print_json( { status => 403, error => "Permission denied"} );
            exit 0;
        }
        $admin_mode = 1;
    }

    unless ( $p->{skip_check_auth} ) {
        unless ( $user->can_access( uri => $uri, method => $ENV{REQUEST_METHOD} ) ) {
            _log_api_call( $user, code => 403, error => 'Permission denied', descr => $api_descr );
            print_header( status => 403 );
            print_json( { status => 403, error => "Permission denied"} );
            exit 0;
        }
    }

    my %args = (
        %{ $p->{args} || {} },
        %in,
        admin => $admin_mode,
    );

    # Payment calls durably commit and may create an external gateway order.
    # A generic rollback preview cannot undo either effect.
    if ( $p->{no_dry_run} && $in{dry_run} ) {
        print_header( status => 400 );
        print_json({ status => 400, error => '支付接口不支持 dry_run' });
        exit 0;
    }

    # User-switching (impersonation) is only allowed for a genuinely
    # authenticated admin (session/login/basic-auth). Routes that force a
    # fixed context user via route config (e.g. /public/* uses user_id => 1
    # to run unauthenticated) must never honour a client-supplied user_id,
    # otherwise an anonymous caller could impersonate any client.
    if ( !$p->{user_id} && $user->is_admin && $args{user_id} ) {
        switch_user( $args{user_id} );
    } else {
        delete $args{user_id};
    }

    my $service = get_service( $p->{controller} );
    unless ( $service ) {
        _log_api_call( $user, code => 404, error => '资源不存在', descr => $api_descr );
        print_header( status => 404 );
        print_json( { error => '资源不存在'} );
        exit 0;
    }

    # If params is explicitly defined in route (even as empty {}), use it as-is.
    # If params is not defined at all, auto-populate from controller structure.
    my %schema;
    if ( exists $p->{params} ) {
        %schema = %{ $p->{params} };
    } elsif ( $service->can('structure') ) {
        my $structure = $service->structure;
        for my $field ( keys %{ $structure } ) {
            my $type = $structure->{ $field }->{type} // 'string';
            $type = 'object' if $type eq 'json';
            $type = 'string' if $type =~ /^(?:text|now|date)$/;
            $schema{ $field } = { type => $type };
        }
    }

    # For GET list_for_api endpoints, inject common list params into schema so
    # they pass validation and are forwarded to the controller.
    if ( $ENV{REQUEST_METHOD} eq 'GET' && ( !$p->{method} || $p->{common_params} ) ) {
        my %_common = (
            field  => { type => 'string',  pattern => '^\w+' },
            sort_field => {type => 'string', pattern => '^\w+' },
            sort_direction => { type => 'enum', enum => ['desc','asc'] },
            start  => { type => 'string', pattern => '^\d{4}-\d{2}-\d{2}' },
            stop   => { type => 'string', pattern => '^\d{4}-\d{2}-\d{2}' },
            limit  => { type => 'integer', min => 0, max => 10000 },
            offset => { type => 'integer', min => 0 },
            filter => { type => 'string' },
        );

        for my $f ( keys %_common ) {
            $schema{$f} //= $_common{$f};
        }
    }

    my $method = $p->{method};
    $method ||= 'list_for_api'  if $ENV{REQUEST_METHOD} eq 'GET';
    $method ||= 'api_set'       if $ENV{REQUEST_METHOD} eq 'POST';
    $method ||= 'api_add'       if $ENV{REQUEST_METHOD} eq 'PUT';
    $method ||= 'delete'        if $ENV{REQUEST_METHOD} eq 'DELETE';

    my %allowed_input_fields = map { $_ => 1 } (
        keys %schema,
        'dry_run',
        'format',
        'POSTDATA',
        'PUTDATA',
        ( $p->{splat_to} ? $p->{splat_to} : () ),
    );
    if ( my $err = validate_params( \%schema, \%args, \%allowed_input_fields ) ) {
        _log_api_call( $user, code => 400, error => $err, descr => $api_descr );
        print_header( status => 400 );
        print_json( { status => 400, error => $err } );
        get_service('logger')->warning( sprintf("API validation error: %s %s::%s => %s",
            $ENV{REQUEST_METHOD},
            ref $service,
            $method,
            $err
        ));
        exit 0;
    }

    # Pin the session to the current client fingerprint (IP + User-Agent)
    # whenever a route explicitly accepts `session_id` as a parameter (vs.
    # the auth cookie/header), so a leaked session_id can be detected if
    # replayed from a different client (see Core::Sessions::validate).
    if ( $schema{session_id} && $args{session_id} ) {
        get_service('sessions')->bind_fingerprint( session_id => $args{session_id} );
    }

    # Build safe_args: route-level defaults + only declared/validated input fields.
    # Any %in field not listed in params or optional is silently dropped.
    # Use %args (not %in) so that type-coerced values (int, number) are used.
    my %safe_args = (
        %{ $p->{args} || {} },
        $admin_mode ? ( admin => $admin_mode ) : (),
    );
    # User-provided input only (no route-level defaults like `routes`).
    # Used for logging to avoid serialising huge internal structures.
    my %input_args;
    for my $field ( keys %in ) {
        if ( $allowed_input_fields{$field} ) {
            $safe_args{$field}  = $args{$field};
            $input_args{$field} = $args{$field};
        }
    }
    # Preserve user_id context if admin switched user (already processed above)
    $safe_args{user_id} = $args{user_id} if $admin_mode && exists $args{user_id};

    unless ( $service->can( $method ) ) {
        _log_api_call( $user, code => 500, args => \%input_args, error => 'Method not exists', descr => $api_descr );
        print_header( status => 500 );
        print_json( { status => 500, error => 'Method not exists'} );
        exit 0;
    }

    our $last_cache_reset //= time();
    our $cache_reset_interval //= 10;

    if ( my $cache = get_service('Core::System::Cache') ) {
        my $ip = get_user_ip();
        my $tag = lc sprintf("%s-%s-%s", ref $service, $method, $ip);
        if ( $cache->get( $tag ) >= 5 ) {
            get_service('logger')->error("API rejected for tag: $tag");
            _log_api_call( $user, code => 429, args => \%input_args, error => '429 Too Many Requests', descr => $api_descr );
            print_header( status => 429 );
            print_json( { status => 429, error => '429 Too Many Requests', ip => $ip } );
            exit 0;
        }

        # Cache reset operations with rate limiting (max 1 per 10 seconds per worker)
        my $now = time();
        if ($now - $last_cache_reset >= $cache_reset_interval) {
            my %resets = $cache->redis->hgetall('SHM:Cache:Reset');
            for my $item ( keys %resets ) {
                my $reset_ts = $resets{$item};
                next if $reset_ts < $last_cache_reset;
                my $reset_service = get_service( $item ) || next;
                $reset_service->unregister_child();
                Core::System::ServiceManager::setup() if $item eq 'Core::Config';
                get_service('logger')->info("Worker PID=$$ Reset cache for $item");
            }

            # Always update last check time after interval passes
            # Set -1 sec to prevent race conditions
            $last_cache_reset = $now - 1;
        }
    }

    my @data;
    my %headers;
    my %info;

    # Temporary direct disallow `fields`
    delete $args{fields};

    if ( $ENV{REQUEST_METHOD} eq 'GET' ) {
        @data = $service->$method( %safe_args );
        %info = (
            items => $service->found_rows(),
            limit => $in{limit} || 25,
            offset => $in{offset} || 0,
            $safe_args{filter} ? (filter => $safe_args{filter}) : (),
        );
    } elsif ( $ENV{REQUEST_METHOD} eq 'PUT' ) {
        my $ret = $service->$method( %safe_args );
        if ( length $ret ) {
            if ( ref $ret eq 'HASH' ) {
                push @data, $ret;
            } elsif ( ref $ret eq 'ARRAY' ) {
                @data = @{ $ret };
            } elsif ( blessed $ret ) {
                @data = scalar $ret->get;
            } else {
                if ( my $obj = $service->id( $ret ) ) {
                    @data = scalar $obj->get;
                } else {
                    $headers{status} = 409;
                    $info{error} = "Can't create a service";
                }
            }
        }
        else {
            $headers{status} = 400;
            $info{error} = "Can't add a new object. Perhaps it already exists?";
        }
    } elsif ( $ENV{REQUEST_METHOD} eq 'POST' || $ENV{REQUEST_METHOD} eq 'DELETE' ) {
        if ( $user->id && $service->can('structure') ) {
            if ( $service = $service->id( get_service_id( $service, %safe_args ) ) ) {
                if ( !$admin_mode && $user->id != $service->user_id ) {
                    $headers{status} = 404;
                    $info{error} = "Object not found. Check the ID.";
                } else {
                    if ( $service->lock( timeout => 3 )) {
                        push @data, $service->$method( %safe_args );
                    } else {
                        $headers{status} = 408;
                        $info{error} = "The service is locked. Try again later.";
                    }
                }
            } else {
                $headers{status} = 404;
                $info{error} = "Object not found. Check the ID.";
            }
        } elsif ( $service->can( $method ) ) {
            push @data, $service->$method( %safe_args );
        } else {
            $headers{status} = 400;
            $info{error} = "Unknown error";
        }
    } else {
            $headers{status} = 400;
            $info{error} = "Unknown REQUEST_METHOD";
    };

    my $report = get_service('report');
    unless ( $report->is_success || $p->{skip_errors} ) {
        my %headers = $report->headers;
        $headers{status} ||= 400;
        my ( $err_msg ) = $report->errors;
        _log_api_call( $user, code => $headers{status}, args => \%input_args, error => $err_msg, descr => $api_descr );
        print_header( %headers );
        print_json( { status => $headers{status}, error => $err_msg } );
        exit 0;
    }

    if ( $service ) {
        $service->remove_protected_fields( \@data, admin => $user->is_admin );
    }

    if ( $safe_args{format} eq 'plain' || $safe_args{format} eq 'html' ) {
        print_header( %headers, type => "text/$safe_args{format}" );
        for ( @data ) {
            unless ( ref ) {
                utf8::encode($_);
                print;
            } else {
                print encode_json( $_ );
            }
        }
    } elsif ( $safe_args{format} eq 'json' ) {
        print_header( %headers, type => "application/json" );
        for ( @data ) {
            unless ( ref ) {
                utf8::encode($_);
                print;
            } else {
                print encode_json( $_ );
            }
        }
    } elsif ( $safe_args{format} eq 'other' ) {
        print_header( %headers,
            type => 'application/octet-stream',
            $safe_args{filename} ? ('Content-Disposition' => "attachment; filename=$safe_args{filename}") : (),
        );
        for ( @data ) {
            unless ( ref ) {
                utf8::encode($_);
                print;
            } else {
                print encode_json( $_ );
            }
        }
    } elsif ( $safe_args{format} eq 'qrcode' ) {
        print_header( %headers,
            type => 'image/svg+xml',
        );
        my $data = join('', @data);
        my $result = qrencode($data, format => 'SVG');
        print $result->{data} if $result->{success};
    } elsif ( $safe_args{format} eq 'qrcode_png' ) {
        print_header( %headers,
            type => 'image/png',
        );
        my $data = join('', @data);
        my $result = qrencode($data, format => 'PNG');
        print $result->{data} if $result->{success};
    } elsif ( $info{error} ) {
        print_header( %headers );
        print_json({
            %info,
            status => $headers{status},
        });
    } else {
        print_header( %headers );
        print_json({
            TZ => $ENV{TZ},
            date => scalar localtime,
            %info,
            data => \@data,
            status => 200,
        });
    }

    _log_api_call( $user, code => $headers{status}, args => \%input_args, descr => $api_descr, error => $info{error} );
    if ( $in{dry_run} ) {
        $user->rollback();
    } else {
        $user->commit();
    }
} else {
    _log_api_call( undef, code => 404 );
    print_header( status => 404 );
    print_json( { status => 404, error => 'Method not found'} );
}

sub get_service_id {
    my $service = shift;
    my %args = @_;

    my $table_key = $service->get_table_key;
    my $service_id = $args{ $table_key } || $args{id};

    if ( !$service_id && $table_key eq 'user_id' ) {
        $service_id = get_service('user')->id;
    }

    unless ( length $service_id ) {
        print_header( status => 400 );
        print_json( { status => 400, error => sprintf("`%s` not present", $service->get_table_key ) } );
        exit 0;
    }

    my $key2 = $service->get_table_key2;
    if ( $key2 && exists $args{ $key2 } ) {
        return ( $service_id, $args{ $key2 } );
    }

    return ( $service_id );
}

# Validate %args against a params schema defined in the route.
# Schema format (per field):
#   type         => 'integer' | 'number' | 'string' | 'email' | 'boolean' | 'object' | 'array'
#   required     => 1   (field must be present and non-empty)
#   min / max    => numeric bounds (for integer/number)
#   min_length   => minimum string length
#   max_length   => maximum string length
#   pattern      => regex the value must match (string)
#   enum         => arrayref of allowed values
#
# Returns undef on success, or an error string on the first failing field.
sub validate_params {
    my ( $schema, $args, $allowed_input_fields ) = @_;

    for my $field ( sort keys %{ $schema } ) {
        my $rule  = $schema->{ $field };
        my $value = $args->{ $field };
        my $type  = $rule->{type} // 'string';

        # presence check
        if ( $rule->{required} && ( !defined $value || $value eq '' ) ) {
            return sprintf( "Field required: %s", $field );
        }

        # Skip remaining checks only when field is truly absent.
        # Empty string is treated as provided value and must be validated.
        next unless defined $value;

        # type coercion / check
        if ( $type eq 'integer' ) {
            return sprintf( "Field '%s' must be an integer", $field )
                unless $value =~ /^-?\d+$/;
            $value = int($value);
            $args->{ $field } = $value;
            return sprintf( "Field '%s' must be >= %s", $field, $rule->{min} )
                if defined $rule->{min} && $value < $rule->{min};
            return sprintf( "Field '%s' must be <= %s", $field, $rule->{max} )
                if defined $rule->{max} && $value > $rule->{max};
        }
        elsif ( $type eq 'number' ) {
            return sprintf( "Field '%s' must be a number", $field )
                unless $value =~ /^-?(?:\d+\.?\d*|\.\d+)$/;
            $value = $value + 0;
            $args->{ $field } = $value;
            return sprintf( "Field '%s' must be >= %s", $field, $rule->{min} )
                if defined $rule->{min} && $value < $rule->{min};
            return sprintf( "Field '%s' must be <= %s", $field, $rule->{max} )
                if defined $rule->{max} && $value > $rule->{max};
        }
        elsif ( $type eq 'boolean' ) {
            # Normalize JSON booleans (true → 1, false → 0) and string variants
            if ( ref $value ) {
                $value = $value ? 1 : 0;
                $args->{ $field } = $value;
            } elsif ( $value eq 'true' || $value eq 'false' ) {
                $value = $value eq 'true' ? 1 : 0;
                $args->{ $field } = $value;
            }
            return sprintf( "Field '%s' must be 0 or 1", $field )
                unless $value =~ /^[01]$/;
        }
        elsif ( $type eq 'email' ) {
            return sprintf( "Field '%s' must be a valid email address", $field )
                unless is_email($value) && length($value) <= 254;
        }
        elsif ( $type eq 'object' ) {
            return sprintf( "Field '%s' must be an object", $field )
                unless ref($value) eq 'HASH';
        }
        elsif ( $type eq 'array' ) {
            return sprintf( "Field '%s' must be an array", $field )
                unless ref($value) eq 'ARRAY';
        }
        elsif ( $type eq 'string' ) {
            if ( defined $rule->{min_length} && length($value) < $rule->{min_length} ) {
                return sprintf( "Field '%s' must be at least %d characters", $field, $rule->{min_length} );
            }
            if ( defined $rule->{max_length} && length($value) > $rule->{max_length} ) {
                return sprintf( "Field '%s' must be at most %d characters", $field, $rule->{max_length} );
            }
            if ( defined $rule->{pattern} && $value !~ /$rule->{pattern}/ ) {
                return sprintf( "Field '%s' has an invalid format", $field );
            }
        }

        # enum check (applicable to any type)
        if ( my $enum = $rule->{enum} ) {
            my %allowed = map { $_ => 1 } @{ $enum };
            return sprintf( "Field '%s' must be one of: %s", $field, join(', ', @{ $enum }) )
                unless $allowed{ $value };
        }
    }

    return undef;
}

sub _log_api_call {
    my $self = shift;
    my %args = (
        code => 200,
        args => {},
        descr => undef,
        error => undef,
        @_,
    );

    unless ( $self ) {
        $self = SHM->new( skip_check_auth => 1 );
    }

    my $logs = $self->srv('Logs::Api') || return;

    return $logs->add(
        url => $ENV{PATH_INFO},
        method => $ENV{REQUEST_METHOD},
        ip => get_user_ip(),
        duration => int( (Time::HiRes::time() - $request_start) * 1000 ),
        response_code => delete $args{code} // 200,
        response_error => delete $args{error},
        %args,
    );
}

# exit 0;
