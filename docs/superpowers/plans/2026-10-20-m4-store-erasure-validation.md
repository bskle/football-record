# NATIVE-045 — 原 Store 本地擦除当前零验证

基线 `2cab4640ee3a375da39fdabf0f5a317600b0c263`；作者 `/root/m2_review`，非作者审阅 root + cloud。独立分支 `fix/m4-store-erasure-validation`，仅供026 held候选。

现有 Saga 的 localProgress.completed 是历史事实，无法排除同 inode 恢复的旧业务行。新增 concrete MatchStore / SQLiteSessionRepository 的 `validateLocalBusinessErasedV4(requestID:requestDigest:scope:)`，只在原连接一个无 await SQL 事务内验证原父请求、完整 digest、rawUTF8 scope、原 backend 签名证明、local delete + completed 与当前业务零。返回 Sendable、非 Codable、internal-init 的 `LocalBusinessErasureWitnessV4`，仅表示该 SQL 快照，不新建 receipt、不重擦、不修改 Saga/capability/选择或独立删除进度。

## 实施与真实 TDD

1. 新测试先记录 API 编译红，再以最小历史状态读取记录实际运行红：真实签名删号 → 原 Store erase → 同 inode 恢复旧业务行，历史 completed 不得通过。
2. 叶层集中34张擦除表和 normal-intent / migration-checkpoint 两类 witness 的原谓词供擦除与零检查共用。SQLite.swift 仅复用私有已知 schema 提供此入口内部只读布局检查，不改全局迁移/版本/协议。未知表/view/trigger/列、未来版本及损坏控制保留并拒绝。
3. 重验原 Saga 构造不变量、capability digest、原 control canonical bytes、originalScope 与保留 binding、原 pinned backend receipt。所有表零与两 witness 家族零同一事务读；非零损坏行仍阻断。concrete wrapper 只转发原 store，不增加通用 protocol 要求。
4. 测试原成功/重复/重开原 bytes，34表逐表恢复与两类 witness、错父/摘要/rawscope/进度/签名/原 scope 缺失、未来/损坏/未知布局、原擦除 COMMIT 丢响应和原 wrapper；完整 Core host + Session iOS17/watch10 最低 sim SDK。按实际红绿与输入记录，不访问本人账号或 SDK。

## 所有权与验收

仅 LifecycleStatePersistence.swift、SQLite.swift、SessionDependencies.swift、新 LocalBusinessErasureValidationTests.swift 及本计划/任务卡/验证卡七路径。不得改 Store 其他域、Session 调度、SDK、Package、工程、026树；不自行合并/推送/归档。

026需先停业务写入者，再每轮 current-zero 聚合调用该入口，即使 localProgress 已 completed。返回后新增的外部写入只能由下一次验证发现；不承诺永久零或跨叶节点原子。catalog/保留控制/最终关闭/真实设备组合仍由026负责。源/最终均须 root + cloud 双审。
