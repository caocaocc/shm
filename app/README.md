# SHM 应用说明

- [语言、人民币和上海时区](docs/china-defaults.md)
- [套餐额度、计量和退款](docs/prepaid-consumption.md)
- [易支付商户与渠道](docs/epay.md)
- [原版站点独立安装易支付](docs/epay-standalone.md)
- [客户分流配置与面板发布](docs/routing.md)

使用官方镜像时，将本目录挂载到 core 和 spool 的 `/app`，再将现有应用数据卷挂载到 `/app/data`。生产更新前应同时备份数据库与数据卷，以便恢复历史订单、支付密钥及分流凭据。
