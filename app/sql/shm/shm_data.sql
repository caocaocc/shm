BEGIN;

INSERT INTO `users` VALUES
(1,0,'admin','0df78fa86a30eca0a918fdd21a94e238133ce7ab',0,NOW(),NULL,0,0.00,0.00,NULL,NULL,0,1,0,'管理员',0,0.00,NULL,NULL,NULL)
;

INSERT INTO `accounts` VALUES
('admin','login',1,'{"password": {"hash": "$7$100000$92e8c37b96278da15d1f542c0a566d2d$2f09dcdf0d50a2c4c83418ced379ab333ff9ac6d222227fe30ec39e4b849f26f"}}')
;

INSERT INTO `user_groups` VALUES
(1,'admins',1,'allow',NULL),
(2,'users',0,'allow',NULL),
(3,'审核员',1,'deny','[{"uri": "/admin/user", "action": "allow", "methods": ["GET", "POST"]}, {"uri": "/admin/user/search", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/accounts", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/service", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/service/*", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/pay", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/bonus", "action": "allow", "methods": ["GET"]}]'),
(4,'客服',1,'deny','[{"uri": "/admin/user", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/search", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/accounts", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/service", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/service/*", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/pay", "action": "allow", "methods": ["GET"]}, {"uri": "/admin/user/bonus", "action": "allow", "methods": ["GET"]}]'),
(5,'只读管理员',1,'deny','[{"uri": "/admin/*", "action": "allow", "methods": ["GET"]}]')
;

INSERT INTO `servers_groups` VALUES
(default,'LOCAL','local','random',NULL),
(default,'邮件通知','mail','random',NULL),
(default,'Telegram 通知','telegram','random',NULL),
(default,'Linux 服务器','ssh','random',NULL)
;

INSERT INTO `services` VALUES
(default,'测试服务',0.00,1.00,'test','[]',NULL,0,NULL,NULL,1,0,NULL,0,NULL,0,0)
;

INSERT INTO `events` VALUES
(default,'UserService','用户密码重置','user_password_reset',1,'{\"category\": \"%\", \"template_id\": \"user_password_reset\"}')
;

INSERT INTO `templates` VALUES
('forecast','{{ user.full_name }}，您好：\n\n以下服务即将到期或尚未支付，请及时续费：\n\n{{ FOR item IN user.pays.forecast.items }}\n- 服务：{{ item.name }}\n  金额：{{ item.total }} 元\n  {{ IF item.expire }}\n  到期时间（北京时间）：{{ item.expire }}\n  {{ END }}\n{{ END }}\n\n{{ IF user.pays.forecast.dept }}\n待补缴金额：{{ user.pays.forecast.dept }} 元\n{{ END }}\n\n合计应付：{{ user.pays.forecast.total }} 元（人民币）\n\n到期前未完成续费的服务将暂停。\n\n请登录用户中心查看详情：{{ config.api.url }}\n\n本邮件由系统自动发送。如您收到的邮件有误，请联系我们：{{ config.mail.from }}','{\"subject\": \"SHM - 服务续费提醒\"}'),
('user_password_reset','您好：\n\n您的新密码：{{ user.set_new_passwd }}\n\n用户中心：{{ config.cli.url }}','{\"subject\": \"SHM - 密码重置\"}')
;

INSERT INTO `config` VALUES
("_shm", '{"version":"0.0.3", "cloud": {}}'),
("billing",'{"type": "Simpler", "partner": {"income_percent": 0},"currency": "CNY"}'),
("company", '{"name":"示例公司"}'),
("telegram", '{"token":""}'),
("api",     '{"url":"https://bill.example.com"}'),
("cli",     '{"url":"https://bill.example.com"}'),
("pay_systems",'{"manual":{"name":"手动入账","show_for_client":false},"yoomoney":{"name":"ЮMoney","account":"000000000000000","secret":"","template_id":"yoomoney_template","show_for_client":false}}'),
("mail",    '{"from":"mail@example.com"}')
;

INSERT INTO `spool` (id,status,user_id,event) VALUES
(default,'NEW',1,'{"title":"服务自动续费","kind":"Jobs","method":"job_prolongate","period":"600"}'),
(default,'NEW',1,'{"title":"数据与服务清理","kind":"Jobs","method":"job_cleanup","period":"86400"}'),
(default,'NEW',1,'{"title":"生成并发送续费提醒","kind":"Jobs","method":"job_make_forecasts","period":"86400"}')
;

COMMIT;

