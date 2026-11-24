# 服务分流

客户在服务详情的「分流配置」中保存出口和匹配规则。服务须处于 ACTIVE，已分配的服务器须配置 remnawave.api 与 remnawave.token。服务所属用户可在该页面重新读取自己的出口原文。已停用的规则保留草稿，可重新启用。

在 Remnawave Profile 中将 Out Users 引用于 outbounds，将 Routing Users 引用于 routing.rules。两个 Snippet 均须包含平台原有条目，Out Users 的首项须为平台出口。引用顺序决定匹配优先级。服务器 Token 需要读取用户、读取和更新 Snippet、提交同步的权限。每项服务匹配面板账户 us_ 加用户服务编号。

出口接受 SOCKS5 文本、Shadowsocks 分享链接及单 Peer 的 WireGuard 配置。目标须为可公开访问的地址。每行填写一条域名、IP、CIDR、geosite 或 geoip 规则，每项服务最多 200 条。WireGuard 的 DNS 作为 remoteDNS 下发，节点需支持该选项。

保存、启用或停用通过同源的 /shm/v1/user/service/routing 接口提交。在同一事务里写入意愿并安排 Spool 任务。面板默认合并 3 秒内的修改，每次发起同步后至少间隔 3600 秒。管理端系统配置 routing 支持 batch_window_seconds 和 min_publish_interval_seconds。已提交表示面板接受同步，节点加载时间由 Remnawave 决定。

同一面板由一个发布任务更新。任务重新核对账号、服务归属和服务器，处理本批服务的出口和规则，保留平台及其他用户的条目。切换服务器前可先停用并等待撤回。切换后需确认并保存目标服务器使用的出口。旧面板无法访问时应先恢复旧面板连接，以便确认撤回。

升级前暂停写入、等待旧发布任务完成，同时备份数据库和共享数据卷。必须保留 /app/data/routing-templates/key；没有原密钥时已保存的出口无法解密。旧模板保留给管理员查看，已识别的旧任务由原生 Spool 接管。账号开通、续费仍沿用原账号模板。发布失败时检查任务队列、面板凭据、Snippet 名称及平台默认出口。日志和反馈使用错误代码。
