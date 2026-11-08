# shm

SHM 是支持外部动作的通用计费系统，开源、免费。本分支提供简体中文初始化数据、人民币账本默认值和中国时区配置。

## 文档入口

- [后端功能与测试](app/README.md)：数据库初始化、运行前提及离线/隔离测试入口。
- [分流配置](app/docs/routing.md)：启用个人出口与规则，使用现有队列异步同步。
- [服务选项开发契约](app/docs/service-options.md)：通用保存、凭据保护及原生适配器接口。
- [Remnawave 账号与订阅](app/docs/remnawave.md)：Dashboard 安装账号生命周期模板，核对服务器、事件与套餐配置。
- [默认值与运行配置](app/docs/china-defaults.md)：CNY、`Asia/Shanghai` 与新部署初始化。
- [易支付充值](app/docs/epay.md)：充值配置、通知与补单。
- [预付套餐消费计量](app/docs/prepaid-consumption.md)：额度、读数及退款结清。
- [上游文档](https://docs.myshm.ru)。

账号生命周期模板沿用上游安装方法：在 Dashboard 的 Templates → Add new 中自选名称（例如 `vpn_rmw`），粘贴 `remnawave-shm-template/templates/shm-remnawave.template.sh` 的完整内容并保存。沿用站点现有的 Compose、服务器组和事件配置；本接入不要求重新构建 core 镜像。

本分支面向全新部署，以官方 3.7.0 为稳定基线，定制提交位于上游历史之后。客户端和管理端分别在独立仓库维护；部署继续使用官方镜像及现有源码、构建目录挂载方式。
