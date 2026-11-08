# Remnawave 接入

沿用上游部署与安装方法：在 SHM Dashboard 保存模板，继续使用站点现有的 Compose、服务器、服务器组和事件。模板源码位于相邻项目的 `remnawave-shm-template/templates/shm-remnawave.template.sh`；core 不打包另一份模板，也不要求导入脚本或重新构建镜像。

面向中国大陆的新站点可使用当前 core 的 CNY、简体中文通知和 `Asia/Shanghai` 默认值，客户端读取后端账本币种。首次初始化前按[中国区默认配置](china-defaults.md)统一设置账本币种与业务时区。需要人民币在线充值时，沿用现有[易支付接入](epay.md)配置。

## 手动保存模板

1. 打开 **Dashboard → Templates → Add new**。
2. 名称自行选择，例如 `vpn_rmw`。更新已安装的模板时，编辑原模板并保留原名称。
3. 粘贴 `remnawave-shm-template/templates/shm-remnawave.template.sh` 的**完整内容**。
4. 点击 **Save**。核对现有服务器或事件的 `settings.template_id`，使其引用刚保存的名称；例如 `vpn_rmw`。不要为了更新内容新建重复事件。

模板继续保存在 SHM 原有模板存储中。不要为本接入创建 `app/data/templates/`：当前 `Core::Template` 检测到该目录会全局切到文件模式，影响原有数据库模板。

Dashboard 使用原有模板 API：`GET /shm/v1/admin/template` 列表，`PUT` 创建、`POST` 更新；`GET /shm/v1/admin/template/<名称>` 读取原始内容。模板名称是字符串，不限定为 `vpn_rmw` 或其他固定值。这些接口无需为本模板修改。

## 核对现有执行环境与配置

SHM 的 `ssh` transport 先解析 Template Toolkit，再把生成的脚本文本交给已有 SSH 目标的 Bash 执行。沿用当前可用的 SSH 主机、密钥与组即可，无需另建专用执行机。`local` transport 只解析模板，不执行 Bash，不能直接运行本 Shell 模板。

实际执行脚本的环境需要 **Bash、curl、jq 和支持模板日期转换的 date**；Linux 上通常为 GNU date，macOS 可使用 GNU `gdate`。同时应有 HTTPS 所需的 CA 证书和配置时区数据，并能访问 SHM 与 Remnawave API。依赖应核对实际 SSH 目标，而不是仅检查运行 Dashboard 的机器。默认模式不需要 Python 或持久状态目录。

下面只列出当前 core 中应核对的字段，不要求重建现有配置：

| 位置 | 字段及含义 |
| --- | --- |
| SHM 全局配置 | `config.api.url` 为执行环境可访问的 SHM 站点根地址，例如 `https://shm.example.com`；模板自行拼接 `/shm/v1`，这里不重复添加该路径 |
| 服务器顶层 | `server_gid`、`transport`、`host` 沿用现有服务器组、SSH 传输与目标地址 |
| 服务器 `settings` | `template_id` 为自选模板名；`key_id`、`port` 等 SSH 参数沿用当前有效值 |
| 服务器 `settings.remnawave` | `api` 为面板地址，`token` 为 API token；`default_internal_squad_name` 为缺省内部组名；`shm_tz` 默认 `Asia/Shanghai`，`expire_safety_minutes` 默认 `0` |
| 套餐 `settings.remnawave` | `internal_squad_name` 或 `internal_squad_pool_names`、可选 `external_squad_name`、`traffic_limit_bytes`、`traffic_limit_strategy`、`hwid_device_limit` |
| 事件 | `server_gid` 引用现有组；`settings.template_id` 引用模板名；`settings.category` 与目标套餐原有 `category` 匹配 |

面板 token 放在服务器的私有配置中，不要写入公开模板或提交到 Git。套餐设置应合并到原有 `settings`，保留其他业务字段。模板用 SHM 用户服务 ID 生成面板用户名 `us_<ID>`，订阅 JSON 保存到对应用户的 `vpn_remna_<ID>` 存储项，供客户端读取。客户端默认只读取该前缀；显式设置 `PROXY_STORAGE_PREFIX` 时只读取所配置的存储项。

## 沿用现有事件

已有 `CREATE`、`ACTIVATE`、`BLOCK`、`REMOVE`、`PROLONGATE` 绑定继续使用，无需凑齐固定数量的事件，也无需改成专用分类。检查现有事件以避免重复执行；只有需要新增行为时才补相应绑定，并继续引用原有服务器组、模板名与套餐分类。

| 事件 | 模板行为 |
| --- | --- |
| `CREATE` | 创建或核对面板用户并保存订阅 |
| `ACTIVATE` | 恢复用户，同步到期时间和限额 |
| `BLOCK` | 停用面板用户 |
| `REMOVE` | 撤销订阅并删除用户，已不存在视为完成 |
| `PROLONGATE` | 同步到期时间和限额；`NO_RESET` 策略在续费时清零流量 |
| `CHANGED` | 按现有绑定同步配置和订阅；`REMOVED`、`NOT PAID`、`INIT` 状态跳过 |
| `CHANGED_TARIFF` | 换套餐后同步新配置与订阅 |

新建换套餐事件时选择 `CHANGED_TARIFF`；需要换套餐后立即同步时补充该绑定。`CHANGED` 与 `CHANGED_TARIFF` 由 core 在不同场景发出，应分别按业务需要绑定。`INIT` 是 SSH 初始化检查动作，不作为套餐生命周期事件新增。

`settings.category` 使用 SQL LIKE 匹配，`%`、`_` 有通配意义；沿用站点分类并确认匹配范围，不要为了本模板把所有分类改为一个值。Core 也会在删除、首次未支付等状态变化后发出 `CHANGED`；模板跳过这些未开通或已移除状态，已开通服务缺失面板账号仍会报错。

## 套餐与日期语义

`traffic_limit_bytes` 以字节为单位，`107374182400` 为 100 GiB，`0` 为不限流量。Remnawave 3.4.7 的 `traffic_limit_strategy` 支持 `NO_RESET`、`DAY`、`WEEK`、`MONTH` 和 `MONTH_ROLLING`。`MONTH_ROLLING` 使用面板滚动月策略，与自然月 `MONTH` 不同。周期策略由面板调度重置，模板不会因 SHM 续费额外清零这些策略。

`hwid_device_limit` 为正整数时限制设备数，显式 `0` 关闭限制；省略时创建采用面板默认值、更新保留已有值，显式 JSON `null` 在更新时恢复面板默认。外部组更新时，`external_squad_name` 缺失或空串保留已有值，显式 JSON `null` 清除，非空名称按面板名称写入；CREATE 使用缺失、空串或 `null` 时不分配外部组。

模板将 SHM 本地到期时间按 `shm_tz` 转为 UTC 后发往面板。SHM 应用、数据库会话与模板时区应一致；Remnawave 的重置调度时间取决于面板部署时区，SHM 或客户端设置 `Asia/Shanghai` 不会自动改变面板调度。变更时区不转换历史日期。

`ACTIVATE`、`PROLONGATE` 在启用或清零之前要求到期时间严格晚于当前时间。配置同步事件遇到过去的到期时间会省略 `expireAt`，继续同步其余配置，不显式启用 `DISABLED` 用户。Remnawave 3.4.7 可能按新的未来到期日或额度恢复 `EXPIRED`、`LIMITED` 用户，这是面板自身行为。

## 可选的续费重试日志

默认 `settings.remnawave.reset_journal_enabled=false`，保持上游 `NO_RESET` 续费清零方式，不依赖 Python、任务日志或持久目录。若清零已经成功而后续步骤失败，重试可能再次清零；操作者可按站点需要核对这类部分成功任务。

只有显式设置服务器 `settings.remnawave.reset_journal_enabled=true` 才启用高级去重日志。此时实际执行环境另需 Python 3 标准库 `fcntl`，以及执行用户拥有的私有持久目录：默认 `$HOME/.local/state/shm-remnawave`，可选 `state_dir` 为该用户可写的绝对路径。目录权限 0700、文件 0600，按 SHM API 和面板地址的哈希隔离；保留 `pending/done`，不用普通用户可写的订阅 Storage 保存控制日志。

启用该选项时，同一接入须使用稳定的执行机、用户和日志目录；容器执行环境需持久卷，不使用 `/tmp` 或可丢弃容器层。已有 `pending` 且无法证明清零已完成时会停止，要求核对；不提供跨执行机严格一次执行保证。这些是选用该高级选项时的条件，不是安装模板的前提。

## 验证

在隔离账号核对创建后的 `us_<ID>` 与 `vpn_remna_<ID>`、客户端订阅读取、停用恢复、续费与换套餐同步、删除重试。支付成功不等于远端已经开通，应查看原有任务状态和日志。

core 的离线契约检查：

```sh
prove app/t/unit/deployment/remnawave_contract.t
```

该测试读取实际 CGI 路由、模型结构和参数校验器，检查自选模板名、现有服务器设置和事件参数，无需数据库、SSH 或面板。模板自身的离线测试在 `remnawave-shm-template` 项目运行；这些检查不替代目标环境验收。
