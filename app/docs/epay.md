# 易支付充值

易支付向 SHM 用户钱包充值 CNY。入账使用 `User.payment` 与持久化 PAYMENT 任务；付款通知不直接执行外部资源开通或续费。

## 通道配置

要求 `billing.currency=CNY`。在 `pay_systems` 配置中添加 profile：

```json
{
  "epay": {
    "paysystem": "epay",
    "name": "支付宝",
    "show_for_client": true,
    "enabled": true,
    "protocol": "v2_rsa",
    "pid": "1001",
    "api_url": "https://pay.example.com",
    "notify_url": "https://bill.example.com/shm/pay_systems/epay.cgi?action=notify",
    "return_url": "https://bill.example.com/shm/pay_systems/epay.cgi?action=return",
    "key_version": "key-1",
    "merchant_private_key_file": "/run/secrets/epay_merchant_private.pem",
    "platform_public_key_file": "/run/secrets/epay_platform_public.pem",
    "checkout": "api",
    "type": "alipay",
    "min_amount_cents": 100,
    "max_amount_cents": 1000000
  }
}
```

密钥文件须允许运行 FastCGI 的 `www-data`（UID 33）读取，不向浏览器公开，也不保存在订单或日志中。RSA 使用 PEM 密钥；V2 的 `sign_type` 字面值为 `RSA`，算法为 SHA256withRSA / PKCS#1 v1.5。

| 协议 | `checkout=api` | `checkout=submit` | API 成功码 |
| --- | --- | --- | --- |
| `v2_rsa` | `/api/pay/create`，`method=jump`，验签响应 | `/api/pay/submit` 签名表单 | `0` |
| `v1_md5` | `/mapi.php` | `/submit.php` 签名表单 | `1` |

V1 用 `md5_key_file` 替代两个 RSA 文件字段。旧查单的 `pid+key` 仅由服务器通过 HTTPS POST 发送。网关、通知及返回地址均要求 HTTPS。

API 下单必须配置 `type`，为 1–32 位字母、数字或下划线，例如 `alipay`、`wxpay`；submit 可以省略。微信可另建 `epay_wxpay`，保留 `paysystem=epay` 并固定 `type=wxpay`。客户选择公开 profile，不能自传支付方式或商户覆盖配置。

普通用户仅能使用 `show_for_client=true` 的通道，隐藏通道可供管理员使用。`enabled=false` 拒绝新单，不妨碍历史订单验签与查单。换钥时，在 `credential_versions` 中按旧 `key_version` 保留相应密钥文件，直到相关订单结清；历史订单使用冻结版本。

## API 与通知入口

API 位于 `/shm/v1`，沿用 SHM 登录认证。充值金额单位为元，使用 ASCII 数字，最多两位小数，内部转换为整数分。

| 方法与路径 | 参数 | 用途 |
| --- | --- | --- |
| `POST /user/epay/order` | `ps=epay, amount=10.00` | 创建绑定当前用户的订单 |
| `GET /user/epay/order` | `out_trade_no` | 本人或管理员读取状态 |
| `POST /user/epay/reconcile` | `out_trade_no` | 本人查单补单 |
| `POST /admin/epay/reconcile` | `out_trade_no` | 管理员查单补单 |

创建返回 `out_trade_no` 与 `checkout_url`，或 `checkout_request` 的表单地址和签名字段。创建及补单实际提交资金事务，不接受 `dry_run`；传入 `user_id` 不改变订单归属。

`/shm/pay_systems/epay.cgi` 提供 create、notify、return、query 动作：

- `action=create&ps=epay&amount=10.00`：登录后创建并进入收银台。
- `action=notify`：公开 GET 通知，必须验签并核对本地订单。
- `action=return`：只显示本地状态，不入账。
- `action=query&out_trade_no=...`：本人或管理员查单补单。

`bin/shm-server.pl` 精确映射该入口到 `/app/public_html/shm/pay_systems/epay.cgi`，普通和 legacy 模式均适用，无需复制到 data 目录。Cloud 跳过 epay 下载；实际反向代理需把此请求转交后端处理。

## 入账与重试

下单前持久化 PENDING，冻结用户、金额、CNY、网关、商户、协议、密钥版本和公开配置 fingerprint。通知依据本地订单选择算法，不允许降级，并验证商户、订单、交易号、金额、支付方式及 `TRADE_SUCCESS`。

通知与查单共用入账处理。订单、用户、付款、奖金历史和 spool 表必须为 InnoDB；余额、流水、PAID 状态和 PAYMENT 任务同事务提交后才返回纯文本 `success`。交易号与入账 `uniq_key` 防止重复充值，重复有效通知仍确认成功。

V2 默认容许 300 秒时间偏差，`timestamp_skew` 可设 1–3600 秒。PENDING 过期通知拒绝处理，应主动查单。已持久化 PAID 的重复 notify 可忽略新鲜度，仍严格验签及核对全部字段；加锁后按最新状态再次验证。该例外不适用于 PENDING 或查单响应。保持两端时钟同步，notify_url 不附加 `ps/user_id` 等未签名参数。

下单超时先查询原单，避免重复付款。付款确认不等待资源交付，任务独立重试。适配器不执行网关原路退款；钱包退款是另一业务。上线前需在网关测试环境验收真实金额、签名、通知重试、查单及换钥。
