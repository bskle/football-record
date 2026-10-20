# NATIVE-042 会话与展示退役

基线 `2cab4640ee3a375da39fdabf0f5a317600b0c263`；独立分支 `fix/m4-session-retirement`。作者 `/root/m2_review`，非作者审阅 root 与 cloud。该修复提供 026 所需的停写、排空和旧 UI 清理边界，不关闭原仓库或 Saga。

## API 与组合顺序

1. `RecordingModel.beginRetirement()` 同步永久关闭新 UI 业务入口并建立迟到结果栅栏。
2. concrete `MatchSession.retireBusiness() async throws` 永久关闭新业务与后台调度，等待已派发 gateway 的原观测持久完成。不得取消实际采集调用、伪造 notCreated、另派 finish/recover，或吞掉持久化失败。错误保留原观测供数据库重试；COMMIT 丢响应只在 canonical 读回证明后视为完成。
3. `await RecordingModel.shutdown()` 排空自身直接操作、观察与反馈派生任务，清除 snapshot/history/pending/metrics。SyncStatus 自身观察也 join；其独立 shutdown/restart 行为保留。

026 先同步 beginRetirement，再 await 原 Session 退役，最后 await Model.shutdown。纯显式查询与原 Lifecycle/Saga 仓库继续可用。新增 `SessionError.retired` 仅在 SessionModels；不向通用协议加默认空实现。

## 实施与验证

- 先测试受控 perform/reconcile 挂起、原观测提交失败/丢响应、并发退役、退役后拒新业务与保留读取。
- 再测试 load/history/prepare/observer/status 挂起后的 shutdown join 与迟到结果栅栏、敏感投影清理。
- 每段保留实际红绿，区分 API 编译红与运行断言红；完整 Core 与 Presentation 宿主测试、相关最低 iOS17/watch10 SDK 及两无签名 generic simulator App。真实 SDK 回调/设备组合仍由 026 后验。
- 仅所有权内 Session source/tests、两个 Presentation source、四个登记测试与本计划/任务/验证卡；不改 Store、MatchSync、AccountKit、SDK、工程、Package 或 038 工厂。
- 作者不合并、推送或归档；source/final 停写后交两位非作者按 exact SHA 审阅。
