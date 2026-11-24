# 在原版 SHM 安装易支付

已有 SHM 3.7.0 站点可以通过管理员模板或服务器命令安装同一支付模块。安装前备份数据库、应用数据卷和当前管理端静态目录，保留原有支付入口以便核对归属。使用完整部署包创建的新站可直接打开支付系统进行配置。

## 准备管理端

下载配套的 shm-epay-gui-template ZIP 和同名 .sha256。在同一目录运行 `sha256sum -c 文件名.zip.sha256`。解压到空目录，在解压目录执行 `sha256sum -c SHA256SUMS`。将其中的 `shm-admin/dist/` 安装到管理端静态文件挂载目录。确认 Nginx 的 MIME 表将 js 和 mjs 都映射为 application/javascript；使用配套 Compose 的站点可以将 ZIP 中的 shm-admin/mime.types 放入对应挂载路径。整目录替换后重新创建管理端容器。

## 使用管理员模板

1. 由有权编辑模板和系统配置的管理员，导入 ZIP 中的 `epay_install.tt`，模板 ID 使用 `epay_install`，保持私有。
2. 在登录的管理域名打开 `/shm/v1/template/epay_install?format=html`。核对安装状态，点击「安装易支付」。
3. 成功后进入「支付系统 → 易支付 → 配置」，录入商户，显示所需渠道。

如果页面提示数据目录权限不足，在原 Compose 项目中为 www-data 配置 `/app/data/epay` 为 0700，`/app/data/pay_systems` 为 0755，然后重试。安装器提示同名入口归属冲突时，先核对来源和待付订单。

## 使用服务器命令

将 shm-epay-gui-module 的 tar.gz 和同名 .sha256 放到空目录。先运行 `sha256sum -c 文件名.tar.gz.sha256` 再解包。在保存原 Compose 的目录运行安装器，下面以 /opt/shm 为例。

~~~sh
(cd epay-module && sha256sum -c SHA256SUMS) &&
  installer="$PWD/epay-module/install" &&
  (cd /opt/shm && sh "$installer")
~~~

出现 `Installed /shm/pay_systems/epay.cgi` 后，登录管理端填写商户资料。升级时使用新版包重新执行同一入口，沿用原数据库及数据卷。历史订单继续使用其下单时的资料。管理员模板与服务器命令使用同一套运行文件和订单表。

## 旧商户和待付订单

独立安装器会将旧版 epay_merchants 配置中的商户资料迁移到私有表 epay_accounts。发现同一渠道存在互相矛盾的凭据时，事务会回滚，安装器会指出对应渠道。请核对该商户当前使用的资料后重试。

旧订单需要对应数据库和 /app/data/epay/key 才能按下单时使用的配置查单和核对通知。若独立安装器报告公网 CGI 归属冲突，先隐藏充值渠道、清点待付订单、核对现有安装方式及入口文件。完成更新后，用旧订单确认通知及查单可用，再恢复充值。

## 从源码生成模块

在 core 仓库运行 `perl app/scripts/epay-standalone/build.pl /tmp/epay-module`，目标必须是新目录。该目录包含安装脚本、模块运行文件、可导入模板与 SHA256SUMS。正式发行的配套 ZIP 另外包含已构建的管理界面。

商户与订单的使用说明见[易支付商户与订单](epay.md)。
