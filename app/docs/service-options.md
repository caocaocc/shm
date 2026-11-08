# 服务选项开发契约

服务选项为已购买的服务提供受限设置、机密存储和异步处理能力。通用核心负责归属、事务、队列、加密、锁和生命周期；适配器负责外部系统的业务校验与发布，不改变计费和支付。

## 自动识别能力

核心读取当前购买实例已绑定的 `settings.server_id`，仅检查该服务器最新私有 `settings` 的顶层对象键。
符合短名规则的键映射到已安装的受限 `Core::Integrations::*` 模块，例如 `remnawave` 对应 `Core::Integrations::Remnawave`。
套餐不需要 `options` 启用配置，客户请求不能指定适配器、服务器或凭据要求；核心不从服务器组或其它实例猜测目标。

未分配服务器、服务器记录不存在或没有匹配模块时返回 `supported:false`。恰好一个模块时由其 metadata 声明能力；
匹配多个模块时明确报错，不任意选择。未安装的候选可跳过，已安装模块的依赖、构造或 metadata 损坏则报错。
首次开通尚未绑定服务器时可能暂不显示能力；暂停服务保留绑定后，仍可保存并等待恢复。

改变已绑定服务器或识别到的适配器前，应先完成原目标停用。停用和 REMOVE 始终依据已保存的目标处理，
未确认停用时拒绝直接转移已有配置，不把秘密自动发送到另一目标。

## API

```text
GET  /shm/v1/user/service/options?user_service_id=123
POST /shm/v1/user/service/options
POST /shm/v1/user/service/options/secret
GET  /shm/v1/admin/user/service/options?user_service_id=123
POST /shm/v1/admin/user/service/options
POST /shm/v1/admin/user/service/options/retry
```

用户接口核验登录身份和购买实例归属。管理员接口分别提供脱敏读取、停用、重试，不接受通过客户端选择适配器、服务器、队列或同步结果。

这些后端接口继续保留，管理端不再提供独立分流区域。日常操作通过原有“进入用户中心”入口完成；主动重新应用配置的停用、等待、启用顺序见[分流配置](routing.md)。直接修改持久 JSON 的 `status` 不会触发事务入队。

用户保存时提交 `user_service_id`、布尔值 `enabled`，以及可选的 `data` 和 `secret` 对象：

- `data` 只放可回显内容；提供时替换整个数据对象，省略时保留。
- `secret` 只放机密；省略时保留原值，空对象表示明确清除。完整对象按序列化后的 UTF-8 字节限制为 64KiB，适配器要求凭据时，启用不能清空。
- 停用只提交 `{"user_service_id":123,"enabled":false}`，不包含当前表单草稿。
- 已移除的服务拒绝新保存；未开通或暂停的服务可以保存，但等待恢复后才发布。

普通读取和保存响应沿用 SHM 包装；`data[0]` 包含 `supported`、`feature`、`enabled`、可回显 `data`、`has_secret` 和标量 `status`；失败时同层增加 `error`。外层 SHM `status` 仍是数字 HTTP 状态码。例如分流适配器的 `feature` 为 `routing`。这些响应及管理员接口不返回机密明文、密文或密钥；`supported:false` 表示当前购买实例尚无可识别能力。

`POST /user/service/options/secret` 只接受 `{"user_service_id":123}`，重新核验当前登录者确为实例所有者，再解密该实例既有机密；管理员身份不能绕过本人归属检查。响应中的 `secret` 为通用机密对象，无已保存机密时为 `{}`，已移除的服务拒绝读取。响应使用 `Cache-Control: no-store`，不返回密文、主密钥或服务器私有设置，失败信息与日志不得含机密。此接口不保存、不排队，也不增加适配器方法或 metadata 字段。

分流客户端将新输入的规范化对象存入 `secret.outbound`，原始文本存入同一个机密对象的 `secret.outbound_text`；两者一并加密到数据库 `options.secret` 密文字段，不放在公开 `data`，不新增存储字段。客户端对未裁剪的原文按 UTF-8 字节限制为 16KiB，核心只执行通用机密对象 64KiB 上限，不识别提供商或原文格式。

客户端随服务详情预加载本人机密，按 `secret.outbound_text` 原文回填并初始化已保存基线；缺失或损坏时显示受控读取错误，不从规范化对象重建用户原文。状态轮询仍使用脱敏 GET。已修改的草稿不被迟到响应覆盖，离开实例或退出后丢弃页面内存，不写入浏览器存储。分流适配器发布只读取规范化 `outbound`，原始文本不进入远端 Snippet、队列快照或日志。

标量 `status` 可为 `queued`、`submitted`、`disabled`、`waiting_service`、`error`、`cleaned`。错误仅返回固定机器码，通用错误使用 `SERVICE_OPTIONS_*`；目标无效/变化使用 `SERVICE_OPTIONS_TARGET_INVALID` / `SERVICE_OPTIONS_TARGET_CHANGED`，持久结构无效使用 `SERVICE_OPTIONS_CONFIG_INVALID`；`submitted` 表示外部系统已受理，不等于资源已经生效。

任务诊断保留已验证回执中的安全错误码；混合失败或部分成功时，结果中的 `errors`（如有）按购买实例编号映射各项失败码。任务执行完成不保证全部实例成功，应同时核对逐项状态。异常、超时或无效回执使用核心固定失败码，不把原始异常或外部响应写入任务诊断；界面只显示已知码及对应的安全提示。

## 原生适配器

短名使用小写单词和下划线，解析为受限 `Core::Integrations::*` 名称，例如 `remnawave` 对应 `Core::Integrations::Remnawave`。模块必须预先安装，每次创建独立对象，不使用请求提供的路径或任意类名。

适配器实现两个方法：

```perl
sub metadata { return {feature => 'routing', requires_secret => 1} }
sub apply { ... }
```

`metadata()` 只包含 `feature` 和 `requires_secret` 两项，声明能力和凭据要求，普通用户与套餐设置不能覆盖。`requires_secret` 只在加载模块时读取，不写入实例或任务；模块当前声明的 `feature` 必须与已保存/任务的能力匹配，变化时拒绝执行；已停用也不能沿用旧机密或数据切换到另一 feature。同一 feature 的目标转移仍需先确认原目标停用。通用核心不根据提供商名称做业务特判。

`apply()` 接收 `payload`、服务器私有 `settings`、固定总超时 `timeout`、`state_factory` 和 `current_items`，返回成功位与结构化结果：

```perl
(1, {items => {123 => {state => 'submitted'}}})
```

`payload` 包含能力及本批实例的当前状态、公开数据和内存中的已解密机密。核心严格验证结果的实例编号、状态和安全错误码。适配器不得返回完整外部响应、原始异常、Token 或用户凭据。

`state_factory` 提供按目标加锁的加密恢复状态，支持 `load/save/clear/close`；`current_items` 在恢复时重新核对当前来源和授权。不能把历史启用草稿直接当成当前有效配置。

## 存储、并发与生命周期

实例设置保存在 `user_services.settings.options`，不新增表。当前结构如下，全部目标与同步字段由程序管理：

```json
{
  "feature": "routing",
  "enabled": 1,
  "target": {"adapter": "remnawave", "server_id": 17},
  "data": {"outbound": {"protocol": "socks", "server": "proxy.example.com", "port": 1080}, "rules": ["example.com"]},
  "secret": "程序生成的加密字符串",
  "status": "submitted"
}
```

`feature` 只保存一份；`target` 保留实际发布目标，停用或 REMOVE 不跟随实例的新绑定。目标的服务器记录在旧目标确认清理前应保持可用，不能把同一记录直接改指另一个面板。`data.outbound` 只是可缺省的公开摘要（协议、地址、端口），不是用于发布的完整出口。`secret` 在数据库中始终为 AES-GCM 密文；API 输入与本人专用读取的同名 `secret` 则是机密对象。普通 API 不返回数据库中的 `target` 或 `secret`。

`status` 是标量，失败时同层增加固定机器码 `error`，重排队或成功后删除过期 `error`。尚未配置可没有 options，已清理可保留 `data:{}`。持久记录和任务只接受当前结构，旧形状明确拒绝，不自动转换、清空或替换密钥。

保存与入队位于同一事务；任务只存 `feature`、`target` 和 `user_service_ids`，不保存凭据要求、公开配置或机密快照。同步锁仍按 `[adapter, server_id, feature]` 的规范 JSON 字节分组；数据变更不引入版本号。

密钥、锁和加密恢复文件保存在 `${SHM_ROOT_DIR}/data/service-options`，通常是 `/app/data/service-options`，目录 0700、文件 0600，由应用运行账户拥有。现有共享 `shm-data` 卷必须同时供 core/spool 使用；不增加环境变量或挂载。

AES-GCM 的认证数据绑定用户和购买实例，恢复状态另绑定目标作用域。文件拒绝不安全权限与链接，原子写入并同步目录。数据库、密钥及恢复文件须一并备份；密钥缺失或认证失败时停止，不生成替代密钥覆盖已有数据。

首次建立密钥前还会检查现有 options 的根字段与状态类型；发现不可识别结构返回 `SERVICE_OPTIONS_CONFIG_INVALID`，不解密、转换或清除其中内容。合法的当前无机密选项不会阻止首次建钥。此拒绝检测只保护全新部署前提，不提供旧格式兼容或迁移。

worker 取得目标分组锁后重新读取当前配置；同一外部目标还使用共享作用域锁。所有发布进程必须共享同一持久卷，不能与绕过锁的发布脚本并行。HTTP 日志和任务历史只保留脱敏结果；明文不进入队列、控制台或日志。

保存期间客户仍可提交新设置，状态回写通过 CAS 防止旧任务覆盖新内容。外部操作需要幂等；多个 API 请求不等于事务，适配器必须保留最小恢复记录并正确处理当前停用、等待和清理意图。

BLOCK 沿用原停权流程并保留选项；ACTIVATE 重新调度当前选项；REMOVE 按目标批量清理，明确确认后才擦除源机密和规则。保留期仍由原 `billing.cleanup` 决定，不增加第二套定时器，也不删除账务历史。

运行中应持久化实例配置、密钥及恢复文件，供重启和失败任务恢复使用。现有失败配置可通过管理员重试接口继续同步，无需重新提交机密。实际业务配置见[分流配置](routing.md)。
