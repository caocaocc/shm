# 预付套餐消费计量

`PREPAID` 购买时扣全款，后续计量只计算消费价值和可退余额，不按用量重复扣款。累计数据采集、配额执行与停止确认由可信外部适配器负责。

## 套餐与已付期间

在服务 `config` 中启用：

```json
{
  "consumption": {
    "mode": "PREPAID",
    "quotas": {
      "traffic": {"limit": "100000000000", "unit": "byte"},
      "requests": {"limit": "10000", "unit": "request"}
    }
  }
}
```

额度为正十进制字符串，最多 26 位整数、12 位小数，也接受 `{"traffic":"100"}` 简写。最多 32 项计量；名称区分大小写，`time` 不分大小写保留给内部计量。额度和读数使用相同单位，不自动换算 GB/GiB。

未配置的套餐沿用原计费路径。启用后必须由现金加可用奖金足额支付，不使用信用、透支或部分账期。每笔已付 `withdraw` 冻结现金、奖金、币种、起止时间与 epoch、额度及退款规则；未付账单没有消费期间，冻结账单禁止 API 修改和删除。

有效期沿用原 `months/period` 算法：Simpler 一个月为 30 天，Honest 使用日历算法。原 end_date 包含末秒，计算区间为 `[withdraw_date, end_date + 1秒)`。qnt 或延长月份不自动扩额，配置额度就是该期间总额度；冻结期间不支持 add_period_by_money 或自定义到期。独立付费子账单不自动合并计量。

## 消费与退款

已付现金加奖金为 P，实际期间长度为 T，各计量使用量为 U_i、额度为 Q_i：

```text
r = min(1, max(max(0, 已过时间 / T), U_1 / Q_1, U_2 / Q_2, ...))
已消费价值 = P × r
可退款总值 = P − 已消费价值
```

比例取最大值，不相加。例如 30 元、实际 30 天、额度 100 单位：10 天使用 50 单位留存 15 元，20 天使用 60 单位留存 20 元。任一比例达到 1 即耗尽，超额不再次收费。

采用精确有理数计算累计价值，再舍入到分。奖金优先消费，余下消费现金；用量增加时两种可退值均不能增加。现金退回现金余额，奖金退回奖金余额，不执行网关原路退款。关闭期间保留留存和返还结果，重复关闭不重复返款。

冻结的 no_money_back 或 `finish(money_back=>0)` 可结清但不返款；allow_return_full_wd 不绕过消费比例。当前钱包币种与冻结币种不一致时拒绝退款，不自动换汇。

## 可信读数 API

接口位于 `/shm/v1`。管理员可写入，用户仅能读取本人快照：

| 方法与路径 | 字段 |
| --- | --- |
| `GET /user/service/consumption` | `user_service_id`，可选 `withdraw_id` |
| `GET /admin/consumption` | 同上 |
| `POST /admin/consumption/generation` | `user_service_id, withdraw_id, meter, generation, record_id, baseline` |
| `POST /admin/consumption/reading` | 同上，以 `cumulative` 替代 `baseline` |
| `POST /admin/consumption/finalize` | `user_service_id, withdraw_id, cutoff` |

先建计数世代与基线，再报累计值：

```json
{
  "user_service_id": 123,
  "withdraw_id": 456,
  "meter": "traffic",
  "generation": "counter-1",
  "record_id": "counter-1:baseline",
  "baseline": "1000",
  "observed_at": "2026-01-01 12:00:00"
}
```

之后用新 record_id 上报 `cumulative="1050"`，本期用量为 50。每期明确绑定 withdraw_id，旧期晚报不能写入新期。计数器重置时切换 generation 并提供新基线；旧世代贡献保留，切换前须保存最终读数，切换后旧世代不能继续增加。

record_id 在同期间、同计量内唯一，基线与读数共用编号空间。原内容重放幂等，不同内容复用编号、累计值或观测时间倒退返回 409。读数为非负十进制字符串；可选 observed_at 为业务时区 `YYYY-MM-DD HH:mm:ss`，不传取接收时间。适配器应提交真实观测时间，未来或期间外时间返回 400。

快照提供冻结币种、额度、日期，ratio/time_ratio/meter_ratios/totals，现金和奖金的已付/留存/可退值，以及 exhausted、finalized/closed、meter_observed_epoch/refund_ready。未最终确认的可退值只是估算，精确读数须保留十进制字符串和单位。

## 停止与结清

退款流程依次执行：

1. 停用外部资源并确认完成。
2. 上报每项计量的最终累计读数。
3. 以真实停止时间调用 finalize，最终读数须覆盖 cutoff。
4. 调用既有结束、删除或换套餐流程，按固定截止点退款并关闭。

finalize 是管理员对外部事实的确认，不自动停用资源。相同截止点重放幂等，不同截止点返回 409；延迟结束仍按冻结点计算。确认或关闭后拒绝新读数与世代，已有相同记录重放不修改数据。有可退值却缺少最终可信读数时禁止退款；自然到期或耗尽且无可退值时可直接结清。

已确认但未关闭的期间暂不切入新账单，应及时结束、删除或换套餐。结清后重新购买从本次付款时间获得完整新期间，不追溯旧截止点；普通自然续费保留原算法。

## 耗尽与外部动作

可按服务类别配置 CONSUMPTION_EXHAUSTED。写入基线或累计读数时检测耗尽，每期只持久化入队一次；快照读取或纯时间流逝不单独发该事件。时间到期与续费仍使用 CREATE、PROLONGATE、ACTIVATE、BLOCK、REMOVE 生命周期。

事件不机械改变 ACTIVE/BLOCK，适配器须执行真实配额或停用。新期绑定新 withdraw_id 并建当前累计基线；充值钱包不等于加流量，任务重试不能无条件重置或叠加额度。本功能不包含厂商专属采集器或按实际流量直接扣钱包的模式。
