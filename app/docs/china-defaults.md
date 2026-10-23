# 后端默认值与运行配置

以下源码路径相对于 `app/`。默认值只作用于应用和新库数据，不代表运行进程已采用这些设置。

## 初始化、币种与升级

`bin/init.pl` 在空数据库导入 `sql/shm/shm_structure.sql` 和 `shm_data.sql`，新库 `billing.currency` 为 `CNY`，运营显示文案与通知模板为中文。服务 ID、事件、状态、分类标识和模板变量保持原业务含义。

已有库通过 `bin/migrations` 升级，不重新导入 seed。`3.5.1` 增加易支付订单和消费计量存储，并把旧库缺失的账本币种明确保存为 `RUB`；已有明确币种保持原值，金额不换算。修改 `billing.currency` 不能代替历史余额迁移，付款或消费退款的币种不一致时会拒绝处理。

普通钱包金额使用账本主币单位，CNY 表示元。Cloud 的独立余额、服务价格和原 RUB 汇率基准保持原单位，不把远端金额改标人民币。易支付订单的 `amount_cents` 另以整数分保存。

## 应用与数据库时区

`conf/shm.conf` 读取运行环境；`TZ` 空或缺失时才补为 `Asia/Shanghai`，显式有效值不被该缺省覆盖。原启动流程会将环境写入 `/etc/environment`，应用也读取该文件，应确认实际进程中的值。

数据库连接按非空 `DB_TZ`、`TZ`、`Asia/Shanghai` 的顺序选择 session 时区，参数化执行 `SET time_zone = ?`。无效配置或 MySQL 拒绝时区时立即失败，不静默改用 UTC 或 SYSTEM。

`DB_TZ` 必须注入实际后端和任务进程。原 Compose 不映射该变量，仅写在宿主 `.env` 中不会生效。若使用显式 `DB_TZ=+08:00`，应用的 `TZ` 仍可保持 `Asia/Shanghai`；两者需要分别核对。

MySQL 命名时区依赖已加载时区表。用应用实际连接验证：

```sql
SELECT @@session.time_zone, NOW(), UTC_TIMESTAMP();
SELECT CONVERT_TZ('2026-01-01 00:00:00', '+00:00', 'Asia/Shanghai');
```

最后一项应为 `2026-01-01 08:00:00`，不能为 `NULL`。无时区 SQL DATETIME 是业务时区的墙上时间；Unix epoch 与带偏移量 ISO 表示绝对时刻。改变 TZ 不迁移已有日期，应在调整前核对历史日期、到期、续费与通知时间。

## 中文模板与运行资源

新 seed 提供中文续费预测和密码重置主题、正文；SMTP、事件和收件人仍需配置。已有模板不会因升级自动改写。在运行目录的 `data/templates` 存在时，`Core::Template` 使用文件模式，应更新实际 `.tpl/.tpls`，不能只改数据库模板。

支付通道需使用真实币种、金额单位和网关凭据。私钥和 MD5 密钥放在运行进程可读的只读文件中，不写进订单或日志。内置易支付入口及配置见[易支付说明](epay.md)。
