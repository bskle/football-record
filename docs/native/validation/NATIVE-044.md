# NATIVE-044 验证

当前：验证待执行，结果将按实际单轮计数记录。

- 真实 SQLite 红绿：目标四表 / 旧 epoch 恢复、同 inode 重开、unknown / malformed foreign 保全、原 first receipt 与 COMMIT 丢响应重放。
- 完整 Cloud host 与最低 iOS17/watch10 sim/device 四产品编译；计划命令不算已执行。
- 树外 `native-validation/NATIVE-044/` 保存实际输入、命令、原日志及 hash；source / final SHA 不回写自身 hash。
- 纯本地 SQL 重放，无真实 CloudKit 或设备动作；不是 026 全 owned / native / fullseal 通过。

对应 [任务卡](../tasks/NATIVE-044.md) 与 [实施计划](../../superpowers/plans/2026-10-20-m4-cloud-erasure-replay.md)。
