# 易支付本地模块

易支付作为本地支付模块向 SHM 钱包充值人民币。使用原有 `pay_systems` 管理页面、客户充值入口和 `User.payment` 入账流程，无需登录 SHM Cloud 或下载支付脚本。

商户字段按易支付随附 PHP SDK 命名：V1 使用 `apiurl/pid/key`，V2 使用 `apiurl/pid/merchant_private_key/platform_public_key`。外层付款列表及其 `name`、`paysystem`、`action` 沿用 SHM 原有结构。`type` 是预设到每笔易支付请求中的单个支付方式代码，不新增类型数组或配置继承。

## 配置商户

在管理端配置列表编辑 `pay_systems` 的完整值，增加 `epay` 对象，并保留现有其他付款方式。沿用原版 `GET/POST /shm/v1/admin/config` 接口，配置键为 `pay_systems`，值为下面的 JSON。

`/shm/v1/admin/config/pay_systems` 是原版合并接口，省略字段不会删除已有值。切换 MD5/RSA 凭据或修改接口选择时，使用配置列表保存完整值，移除不再使用的字段。

MD5 只填写服务商提供的三项信息：

```json
{
  "epay": {
    "apiurl": "https://pay.example.com/",
    "pid": "1001",
    "key": "商户MD5密钥"
  }
}
```

RSA 填写四项信息，密钥按服务商提供的 PEM 内容填写，JSON 中换行使用 `\n`：

```json
{
  "epay": {
    "apiurl": "https://pay.example.com/",
    "pid": "1001",
    "merchant_private_key": "-----BEGIN PRIVATE KEY-----\n商户私钥内容\n-----END PRIVATE KEY-----",
    "platform_public_key": "-----BEGIN PUBLIC KEY-----\n平台公钥内容\n-----END PUBLIC KEY-----"
  }
}
```

模块根据完整凭据组使用 MD5/V1 或 RSA/V2，像对应 SDK 一样生成请求中的 `sign_type`，商户不用重复填写。两组混填、RSA 缺少一把密钥均拒绝。V2 签名类型为 `RSA`，实际算法为 SHA256withRSA / PKCS#1 v1.5。商户私钥负责请求签名，平台公钥负责响应和通知验签。

RSA 密钥也支持服务商提供的不带 PEM 首尾行的 Base64 DER 内容，允许换行；商户私钥和平台公钥不能填反。

默认名称为“易支付”、向客户显示、从客户中心同源 `/shm/pay_systems/epay.cgi` 发起付款。需要调整名称或隐藏通道时，沿用原配置的 `name`、`show_for_client`；`enabled: false` 拒绝新单，隐藏列表另设 `show_for_client: false`。多个商户可另建名称，使用原有 `paysystem: "epay"` 复用模块。

## 支付宝、微信等独立入口

在原有 `pay_systems` 中分别配置付款方式，客户充值页即可直接选择“支付宝”或“微信支付”，无需修改前端：

```json
{
  "alipay": {
    "paysystem": "epay",
    "name": "支付宝",
    "type": "alipay",
    "apiurl": "https://pay.example.com/",
    "pid": "1001",
    "key": "商户MD5密钥"
  },
  "wxpay": {
    "paysystem": "epay",
    "name": "微信支付",
    "type": "wxpay",
    "apiurl": "https://pay.example.com/",
    "pid": "1001",
    "key": "商户MD5密钥"
  }
}
```

保留现有其他付款方式。每项使用独立配置名称和不同的显示名称；配置名称由站点自行命名，不要求任何前缀。商户信息按项填写，沿用原配置机制。使用 RSA 时，将该项的 `key` 换成前述商户私钥和平台公钥两项。

已有 `epay` 通用入口可沿用 `show_for_client: false` 隐藏，已创建订单的通知和查单仍按原快照处理。

`type` 是可选的支付方式代码，常见值包括 `alipay`（支付宝）、`wxpay`（微信）、`qqpay`（QQ 钱包）、`bank`（银联）、`jdpay`（京东）、`paypal`、`douyinpay`（抖音）。以服务商实际开通的渠道为准；扩展代码允许小写英文字母开头，后续为小写字母、数字或下划线，总长不超过 32 个字符。空值或格式错误会报配置错误。

配置 `type` 后，该入口直接使用指定渠道，浏览器不能改成另一种方式；省略时保持收银台或接口选择页行为。付款方式在建单时冻结，后续修改配置只影响新订单，已有订单仍按原快照验签、查单和入账。

## 使用原有 action 选择接口

省略 `action` 时，模块提供 SHM 的公开默认操作 `submit`。选择服务端接口下单时，沿用 SHM 已有的 `action` 字段，值与对应易支付接口操作相同：

| 商户凭据 | `action` | 易支付接口 |
| --- | --- | --- |
| MD5 / V1 | `submit`（默认） | `/submit.php` |
| MD5 / V1 | `mapi` | `/mapi.php` |
| RSA / V2 | `submit`（默认） | `/api/pay/submit` |
| RSA / V2 | `create` | `/api/pay/create` |

例如 MD5 商户增加 `"action": "mapi"`；RSA 商户增加 `"action": "create"`。这些是 SHM 对模块的操作选择，不作为同名参数发给易支付。商户配置决定实际接口，浏览器不能通过改链接切换接口。

未配置 `type` 时，网页提交进入服务商收银台选择渠道；接口下单先在模块页面选择支付宝或微信，再由服务器创建订单。配置 `type` 后，两种模式都直接使用指定渠道，接口下单不再显示二次选择页。

接口下单优先请求网关的 jump 模式，同时处理普通接口返回的网页跳转、二维码、支付应用唤起地址。V1 解析 `payurl/qrcode/urlscheme`，V2 解析 `pay_type/pay_info`；不执行网关返回的 HTML 或 JavaScript。二维码使用原有 `qrencode` 工具，不新增前端应用或运行依赖。

V2 原生 `method` 表示 `jump/web` 等支付场景，模块接口下单使用 `jump`；它不能用来表示 `submit/mapi` 接口选择。


## 地址、金额和处理结果

账本币种必须为 `CNY`。`api.url` 必须是 SHM 已配置、可公网访问的 HTTPS 基础地址，模块从该地址生成：

```text
通知地址：<api.url>/shm/pay_systems/epay.cgi?action=notify
返回地址：<api.url>/shm/pay_systems/epay.cgi?action=return
```

不根据浏览器传来的 Host 或 Referer 生成地址。原反向代理需要继续将 `/shm` 请求转交后端；当前官方客户端已有该代理路径。通知入口无需客户登录，必须严格验签；返回页只显示状态，不作为入账凭据。

客户输入金额的单位为元，最多两位小数；模块内部使用整数分。付款通知只给钱包充值，不直接执行外部资源开通或续费。余额、付款流水、PAID 状态及原有 PAYMENT 任务同事务提交后才回复纯文本 `success`。重复有效通知仍回复成功，不重复入账。

创建订单时固定用户、金额、商户、网关、签名协议和支付方式。通知不能自行切换签名算法或降级。接口超时或返回异常会显示已保存的原单号，保留 PENDING，先查询原单，不自动切换接口或创建另一笔订单。

登录后可通过模块入口查询：

```text
/shm/pay_systems/epay.cgi?action=status&out_trade_no=订单号
/shm/pay_systems/epay.cgi?action=query&out_trade_no=订单号
```

`status` 读取本地状态；`query` 向网关查单并补齐已付订单。仅订单本人或管理员可使用；浏览器提供的 `user_id` 不改变订单归属。款项到账后，资源交付沿用 SHM 的任务处理和重试。

## 本地交付和机密保存

源模块位于 `app/pay_systems/epay.cgi`，业务和签名代码位于同目录的 `lib/SHM/Pay/`。通用本地模块安装逻辑在 core 初始化时将可信 CGI 原子安装到原有 `/app/data/pay_systems/`，执行其安装检查，然后沿用原 CGI 路由。Cloud 跳过已有本地来源的模块，不使用易支付名称特判。安装记录保护已有手工修改文件，冲突时停止覆盖。

安装检查使用 CLI 数据库上下文，不依赖 HTTP 服务或 CGI 日志管道先启动；首次启动、原容器重启和停止后再启动均沿用现有部署流程。

商户密钥只在管理员配置中填写，不通过客户列表或日志返回。旧式和现代支付列表均只返回公开字段；配置保存请求、SQL 参数和 JSON 错误诊断不输出原始密钥。

每笔订单的必要凭据以 AES-GCM 加密快照保存在 `epay_orders.profile_config`，内部标识自动生成。模块在已有共享数据卷 `/app/data/epay` 自动管理私有目录和加密密钥，权限分别为 0700、0600；无需手工创建 PEM 文件、增加挂载或 `.env` 参数。后续修改、停用或删除商户配置不会改变新订单已保存的凭据。服务商撤销签名密钥可能影响对应订单的查单，应按服务商实际情况处理。

备份时保留原数据库和共享数据卷；已有加密订单时若密钥缺失，模块拒绝重新生成密钥。配置不使用旧文件凭据、手工 `protocol/key_version` 等字段；发现未加密旧订单时停止初始化，不自动删除或改写业务数据。原易支付专用 `/user/epay/*`、`/admin/epay/*` API 已移除，使用统一模块入口。

Compose、镜像选择、挂载和前端构建保持原部署方式。更新 `shm-core/app` 后按原流程先启动 core，完成初始化与健康检查，再启动 spool。真实商户启用前核对签名、回调、查单和重复通知结果。
