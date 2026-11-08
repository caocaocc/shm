# SHM 后端功能说明

本分支基于官方稳定版 3.7.0；普通信用支付、部分账期、统计和 SSH 修复沿用上游。PREPAID 另按实际目标套餐要求足额现金与可用奖励支付，不透支、不缩短账期。历史统计回填脚本不自动运行。

本目录包含 SHM 应用代码、全新数据库初始化、API、任务及测试。本文中的源码路径相对于 `app/`；常规运行目录为 `/app`。

- [默认值与运行配置](docs/china-defaults.md)：中文初始化数据、CNY、时区及新库初始化。
- [易支付充值](docs/epay.md)：RSA/MD5 通道、下单、通知与查单补单。
- [预付套餐消费计量](docs/prepaid-consumption.md)：额度、累计读数、消费比例与退款结清。
- [分流配置](docs/routing.md)：个人出口、规则和同步状态。
- [服务选项开发契约](docs/service-options.md)：通用 API、当前精简存储结构、机密保护和适配器接口。
- [Remnawave 账号与订阅](docs/remnawave.md)：Dashboard 安装生命周期模板，沿用现有套餐与事件配置。

账户、余额、套餐、续费和外部动作仍使用 SHM 原有业务流程。实际资源的采集、开通、限额与停止由事件模板或可信适配器执行；充值确认不等于资源已交付。

## 运行前提

需要本目录代码实际进入运行环境，并具备相应数据库结构和 Perl 依赖。RSA 使用 `Crypt::PK::RSA`（Cryptx）；原基础环境已包含该依赖。本分支面向全新部署，初始化入口为 `bin/init.pl`，使用空数据库创建业务结构和初始数据。生产环境不要启用 `DEV` 或 `DEV_DB_CLEANUP`。

新库使用 CNY，应用与数据库会话共用 `TZ`，按官方配置设置 `TZ=Asia/Shanghai`；为空或未设置时补为上海时区，显式有效时区保持有效。账本币种与业务时区在初始化时统一设置，详见[配置说明](docs/china-defaults.md)。

## 后端测试

测试源码与依赖准备在 `/app` 后，单元测试入口为：

```sh
env PERL5LIB=/app/lib:/app/conf SHM_ROOT_DIR=/app DB_PASS=unit-test-only \
  SHM_TEST=1 TZ=Asia/Shanghai prove -r -j4 /app/t/unit
```

集成测试会修改夹具数据，必须使用专用空测试库，例如 `shm_test`。将 `DB_HOST`、`DB_PORT`、`DB_NAME`、`DB_USER`、`DB_PASS` 导出到测试进程，再在该隔离库执行：

```sh
export PERL5LIB=/app/lib:/app/conf
export SHM_ROOT_DIR=/app
export TZ=Asia/Shanghai
export SHM_TEST=1
env DEV=1 perl /app/bin/init.pl
env EPAY_INTEGRATION_TEST=1 SHM_SQL_CONFIG_TEST=1 prove -r -j1 \
  /app/t/integration/billing \
  /app/t/integration/pay/epay.t \
  /app/t/integration/service_options.t \
  /app/t/integration/service_options_secret.t \
  /app/t/integration/service_options_remnawave.t \
  /app/t/integration/backend_api.t \
  /app/t/integration/deployment/time_zone.t \
  /app/t/integration/feature_without_subscription.t \
  /app/t/integration/user/passwd_accounts.t
```

各测试的启用开关与跳过条件以代码为准；部分测试检查 `_test` 库名，其余也须由操作者保证隔离。易支付测试使用本地密钥与模拟响应，不联系真实网关。实际通知入口仍需单独验收。
