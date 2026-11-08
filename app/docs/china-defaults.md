# 后端默认值与运行配置

以下源码路径相对于 `app/`。默认值只作用于应用和新库数据，不代表运行进程已采用这些设置。

## 全新初始化与计价

`bin/init.pl` 在空数据库导入 `sql/shm/shm_structure.sql` 和 `shm_data.sql`，新库 `billing.currency` 为 `CNY`，运营显示文案与通知模板为中文。消费计量三张表随 `shm_structure.sql` 创建；易支付订单表由本地模块从 `pay_systems/epay.sql` 初始化，不使用旧版定制迁移文件。服务 ID、事件、状态、分类标识和模板变量保持原业务含义。


普通钱包金额使用账本主币单位，CNY 表示元。Cloud 的独立余额、服务价格和原 RUB 汇率基准保持原单位，不把远端金额改标人民币。易支付订单的 `amount_cents` 另以整数分保存。

## 应用与数据库时区

应用与任务进程按官方配置使用 `TZ=Asia/Shanghai`。`conf/shm.conf` 在 `TZ` 空或缺失时补为 `Asia/Shanghai`，显式有效值不被缺省覆盖。原启动流程会将环境写入 `/etc/environment`，应用也读取该文件，应确认实际进程中的值。

数据库连接跟随同一 `TZ`，参数化执行 `SET time_zone = ?`。无效配置或 MySQL 拒绝时区时立即失败，不静默改用 UTC 或 SYSTEM。

MySQL 命名时区依赖已加载时区表。用应用实际连接验证：

```sql
SELECT @@session.time_zone, NOW(), UTC_TIMESTAMP();
SELECT CONVERT_TZ('2026-01-01 00:00:00', '+00:00', 'Asia/Shanghai');
```

最后一项应为 `2026-01-01 08:00:00`，不能为 `NULL`；缺少时区表时先加载再重新连接。无时区 SQL DATETIME 是业务时区的墙上时间；Unix epoch 与带偏移量 ISO 表示绝对时刻。首次部署时统一设置业务时区，确保到期、续费与通知使用相同时间语义。

## 中文模板与运行资源

新 seed 提供中文续费预测和密码重置主题、正文；SMTP、事件和收件人仍需配置。币种或时区偏离默认值时，应同步核对模板中的单位与时区标注。在运行目录的 `data/templates` 存在时，`Core::Template` 使用文件模式，应更新实际 `.tpl/.tpls`，不能只改数据库模板。

支付通道需使用真实币种、金额单位和网关凭据。易支付商户密钥直接在管理端配置，客户接口和日志不返回机密；订单仅保存内部加密凭据快照。使用方法见[易支付本地模块](epay.md)。
