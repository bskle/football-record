# NATIVE-015 Match Sync Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. /root owns quality review and integration; /root/m2_review independently owns specification review. Both reviewers are non-authors.

**Goal:** Recover durable peer deliveries and serialize accepted peer facts through the existing Session queue.

**Architecture:** Shared DTO/protocol/fragment validation stays in MatchStore, with all SQL through the facade's one actor. MatchSync depends only on Core/Store. MatchSession implements the inbound coordinator and persists terminal cleanup before SDK dispatch. Existing schema3 generic delivery/fragment tables are used without schema edits.

**Tech Stack:** Swift6, SQLite3, XCTest, AsyncStream; iOS17/watchOS10 unchanged.

- [x] Write failing Store fragment/restart and Session terminal gateway race tests; save `red-initial.log` from `swift test --package-path native/Packages/MatchCore --scratch-path /tmp/football-record-NATIVE015-build/Core --filter 'SyncDeliveryTests|PeerTerminalTests'`.
- [x] Add MatchStore `SyncServiceModels.swift`, `SyncFragment.swift`, `SyncDeliveryPersistence.swift`: full-message raw SHA256 distinct from domain-separated packet body checksum, per-fragment identity/integrity, 8MiB/256KiB/32 chunk limits, durable quota/expiry/consume/replay and attempt ledgers. Add SyncRepository/SyncInboundCoordinator identities and real facade forwarding. Tests use SQLite close/reopen and injected time.
- [x] Register MatchSync product/target/test target in Package.swift. Add transport, codec, retry, DEBUG persistent identity fixture provider and one-drain service. Red/green service tests cover no transport, callback without ACK, stable bytes after restart, 32 due batch, 8 ACK attempts sleep and trust/identity mismatch. Timer uses clock.now for decisions; tests advance controlled clock and invoke wake without sleep.
- [x] Extend SessionRepository and SQLiteSessionRepository with same-instance identity and methods on its existing Store. Explicit local namespace config selects production unavailable or development isolation. Mechanically forward the two authorized Presentation wrappers and TestRepository; no shared fake identity.
- [x] Add Session receiving extension: validate peer/local namespace and limited canonical header, acquire same-match queue, COMMIT/reload/publish, locked terminal preflight, release then schedule gateway; duplicate republish and cleanup wake. Extract terminal locked helper, preflight before pending gateway selection, stable original-command lookup and token-bound failed-finish successor. Preserve 011/012 and terminal recovery.
- [x] Run targeted tests then Core/Store/Session/MatchSync all tests and full verify with added MatchSync two minimum SDK targets (8 total + 2 Apps). Source freeze/commit first, tree-external full Git inputs/red-green/final manifest, final docs commit and stop.

## Minimal additive API choices

`validateSyncDeliveryV3(deliveryID:peer:now:)` rechecks saved route/inbox authorization binding before a send; a current provider authorization alone cannot identify the old stored epoch. `reactivateSyncACKsV3()` reactivates sleeping ACKs only for a new service activation; ordinary scheduling never resets the 8-attempt limit. These extra SyncRepository methods have real Store/facade/wrapper forwarding. Duplicate packet receipt reactivates its own stable ACK in the same Store transaction. Root was informed before implementation; fixed contract methods remain unchanged.


## 实际完成与交接

源提交 `a6f01d03cd9acc0ff0354354d32c6c6d34543177`，基线/目标 `c3940dd9a1cf4690d849114290c7614905140c7e`。最终完整验证235宿主测试、8SDK、2App均通过；该source/target的 `/root` 质量与 `/root/m2_review` 规格两位非作者双审均PASS；文档最终检查与集成由root执行，作者不合并。证据和边界见 [验证卡](../../native/validation/NATIVE-015.md)。

实际额外接口均已由root批准并真实转发：`validateSyncDeliveryV3`（保存route/inbox与当前peer同绑定），`reactivateSyncACKsV3`（累计attempt不归零），`pendingSyncAssembliesV3(peer:now:)`（当前trust恢复完整未consume消息）。`connectionDidActivate()`仅真实激活重唤醒ACK，不另建listener；typed `SyncStateUpdate`明确读取失败；`didPersistDelivery`只在片段持久成功后释放transport自有输入。完整签名/016与017接线规则已补合同§5—7，既有固定方法保留。

schema3结构不变；record持久化字段在任务卡说明。consume成功后删除临时组避免历史大Data无界；完整未consume不按24h过期，startup与普通wake均可恢复。Session持久cleanup意图后仍按原ledger先回查原未决操作，已有原token保存证明优先于多余finish；同场锁内不等待SDK。

根在本轮纠正过一次helper共享写入授权偏差；作者接管两个已写测试文件/故障钩子并全部验证，之后不再共享可写树。设备WC通信、真实后台/配对重启、最低系统运行和物理断电压力均未验；production trust/transport默认unavailable。
