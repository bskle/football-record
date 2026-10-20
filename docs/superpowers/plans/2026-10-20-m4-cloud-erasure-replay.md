# NATIVE-044 云台账擦除重放校验

依据 [M4 母计划](2026-10-18-native-m4.md) 与 [Git 治理](../../git-workflow.md)。本任务只修复 033 单个 SQLite CloudLedger 的历史 receipt 重放，不代表 026 全部本地数据删除。

## 登记与边界

- 作者 `/root/m4_cloud`；非作者审阅 root、m2。原始 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，held 026 target `3a2a26360a822ed58b886c502acf038b028dfba9`。
- 分支 `fix/m4-cloud-erasure-replay`，受管树 `/Users/liam/.codex/worktrees/m4-cloud-erasure-replay/20260830_足球记录`，attachment `01a15725-5eb1-7500-856e-9cf5bdb70f24`。实际初始 HEAD 等于 base，branch / clean 含 ignored 已自行核验。
- 唯一五路径：`CloudLocalTransportErasure.swift`、新 `CloudLocalTransportCurrentZeroTests.swift`、本计划、044 任务卡及验证卡。不改 schema、通用协议、DTO、SDK、Package、其他模块或 026 检查器。

## 实施顺序

1. 在真实 SQLite 先产生原 receipt 与永久 fence；用同文件 SQL 恢复目标 canonical 行，覆盖四表与旧 epoch，先运行失败测试。另核同 inode 重开、foreign 合法保全、malformed / unknown inventory、原 receipt / COMMIT 丢响应重放。
2. 仅在已核原 request digest、stable zone 与 fence 的重放返回前调用现有完整 `validateErasureCanonicalRows`；目标 stable zone 任一 epoch 非零或任一行不可严格归属即 typed `invalidPayload`。不重新删除、不修改 first receipt、不解除 fence。原 requestID 异意图仍先 `identityConflict`。
3. 同一事务保留 current-zero 校验与返回。保留全部原 canonical / control bytes 和其他合法 scope；原 receipt 只证明历史操作，成功重放还要求当前库存严格可验证且目标为零。
4. 完整 Cloud 宿主回归及最低 iOS17/watch10 两模拟器、两设备 SDK 产品编译；所有构建与证据在树外隔离，记录命令、原红绿日志、输入前后 hash 与精确 source / final。

## 交付限制

source 停写后交 root+m2 双审；获准后仅两卡收尾，final 再审。作者不 merge / push / archive 或推进长期分支。没有实际 CloudKit、账号、设备或采集动作；纯本地 SQLite 重放修复不需要真机。026 仍须聚合全部 owned ledger、024 staging、023 Store 等；本组件不背书全 owned / native / fullseal 完成。
