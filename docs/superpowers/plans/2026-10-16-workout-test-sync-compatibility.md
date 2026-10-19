# WorkoutCapture 测试替身同步兼容实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. 本任务已由主代理派给唯一写入开发代理，按父任务授权执行及停在双审检查点。

**Goal:** 让既有 WorkoutCapture 测试替身符合当前 SyncRepository，恢复完整 40 项宿主回归。

**Architecture:** 仅在 `FaultRepository` 补齐继承的 16 个同步方法，逐一转发至已有同一个 `inner: SQLiteSessionRepository`。保留数据库身份、错误传播、`commitV2` 故障注入和所有测试断言，不新增产品实现或默认成功替身。

**Tech Stack:** Swift 6、SwiftPM、XCTest、SQLiteSessionRepository；最低 iOS 17 / watchOS 10 不变。

依据：[原生开发母计划](2026-10-15-native-development.md)、[Git 治理](../../git-workflow.md)、[任务卡](../../native/tasks/NATIVE-019.md)。本修复仅进入 NATIVE-018 临时整包，008/010/016/018 的真机门槛继续保留。

## Task 1: 登记与复现

**Files:** 创建本计划和 `docs/native/tasks/NATIVE-019.md`；读取 `native/Packages/MatchCore/Sources/MatchStore/SyncServiceModels.swift` 及 `native/Modules/MatchPresentation/Sources/MatchPresentation/AppBootstrap.swift` 作接口/转发参考。

- [x] 核对独立树、分支、完整基线、任务所有权及 008 已普通合入。
- [x] 修改源码前执行下列命令，完整保存编译红证据及实际退出码。预期 `FaultRepository` 不符合 `SyncRepository`，记录 16 个缺失要求；此处既有编译失败已能直接复现兼容回归，不增添镜像转发测试。

```sh
swift test --package-path native/Modules/WorkoutCapture --scratch-path /tmp/football-record-NATIVE019-build/WorkoutCaptureHost
```

## Task 2: 最小修复及验证

**Files:** 仅修改 `native/Modules/WorkoutCapture/Tests/WorkoutCaptureTests/SessionPersistenceTests.swift`。

- [x] 在 `FaultRepository` 的 `databaseNamespace()` 前添加以下 16 个方法。不得修改其他现有行。

```swift
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity { await inner.syncRepositoryIdentity() }
  func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem] { try await inner.unroutedBusinessOutboxV3(matchID: matchID) }
  func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization, now: Date) async throws -> RouteReceiptV3 { try await inner.routeBusinessOutboxV3(outboxID: outboxID, peer: peer, now: now) }
  func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2] { try await inner.pendingPacketsV2(matchID: matchID) }
  func receiveV2(_ bytes: Data, peer: PeerAuthorization, expectedMatchID: String, now: Date) async throws -> InboundReceiptV3 { try await inner.receiveV2(bytes, peer: peer, expectedMatchID: expectedMatchID, now: now) }
  func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws { try await inner.acknowledgeV2(bytes, peer: peer, now: now) }
  func syncStateV3(matchID: String) async throws -> SyncState { try await inner.syncStateV3(matchID: matchID) }
  func ensureSyncDeliveriesV3(matchID: String) async throws { try await inner.ensureSyncDeliveriesV3(matchID: matchID) }
  func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord] { try await inner.dueSyncDeliveriesV3(now: now, limit: limit) }
  func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date, issue: SyncIssue?, now: Date) async throws { try await inner.recordSyncAttemptV3(deliveryID: deliveryID, nextAttemptAt: nextAttemptAt, issue: issue, now: now) }
  func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization, now: Date) async throws { try await inner.validateSyncDeliveryV3(deliveryID: deliveryID, peer: peer, now: now) }
  func reactivateSyncACKsV3() async throws { try await inner.reactivateSyncACKsV3() }
  func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws -> FragmentAssemblyResult { try await inner.acceptSyncFragmentV3(bytes, peer: peer, now: now) }
  func pendingSyncAssembliesV3(peer: PeerAuthorization, now: Date) async throws -> [FragmentAssemblyResult] { try await inner.pendingSyncAssembliesV3(peer: peer, now: now) }
  func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws { try await inner.consumeSyncAssemblyV3(messageID: messageID, wholeChecksum: wholeChecksum) }
  func expireSyncAssembliesV3(now: Date) async throws { try await inner.expireSyncAssembliesV3(now: now) }
```

- [x] 原命令运行完整现有测试，预期 40 项、0 失败；确保 7 项 SessionPersistence SQLite 故障/重开测试仍运行。日志使用同一独立 scratch；证据保存于 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-019`。
- [x] `git diff --check`、检查源码 diff 只新增 16 行转发；单独暂存源码，提交 `test: restore workout repository sync compatibility`。body 写实际命令、结果和限制。
- [x] 向主代理报告完整 source SHA、红绿日志、diff 和未验项，等待 root 与 m2_review 两位非作者审阅。不得自行合并、推送、归档或推进永久分支。

## Task 3: 双审后证据定稿

**Files:** 仅本计划、`docs/native/tasks/NATIVE-019.md`、`docs/native/validation/NATIVE-019.md`。

- [x] 收到 source 双审结论后记录审阅 SHA、实际结果、证据哈希及保留门槛；外部 manifest 不提交构建缓存或个人数据。
- [x] 核对链接、事实与 `git diff --check`，明确路径提交三文档；将 final SHA 回报主代理，保留 worktree 等待后续集成治理。

## 验收边界

40 项仅为当前组装 Core 上的 WorkoutCapture 宿主 XCTest，不代表完整 331 项整包或产品/真机验收。真机不适用于纯测试替身兼容修复；签名、安装、授权、GPS、后台、锁屏、恢复与生产 peer/后台锁均不由本修复证明。

## 执行结果（2026-10-16）

- 源码提交 `59f439a6d59b926dcf2462f046f45c5513831b35`；仅指定测试文件新增 16 行，删除 0 行。剥离新增块后与基线 Git blob 字节一致。
- 编译红证据：2026-10-16 09:57:58–09:58:12 UTC，退出码 1，16 个缺失协议要求；完整测试绿证据：09:58:47–09:58:56 UTC，退出码 0，40 项 / 0 失败（含原 7 项持久化回归）。
- `/root` 质量审与 `/root/m2_review` 规格审均对该 source SHA PASS。此处仅记 source 双审；三文档最终审在文档提交后由主代理安排。
- `source-manifest.json` 已登记 89 个实际 Git 输入文件与 10 项证据，均含 SHA-256；文档提交后生成的 `final-manifest.json` 另绑定实际 final SHA 及三文档 Git blob。清单位置和具体结果见[验证记录](../../native/validation/NATIVE-019.md)。
- 不合并、不推送、不归档，停止写入后交主代理继续 NATIVE-018 临时整包；其实际接收目标 SHA 及 merge 结果由主代理另行登记。
