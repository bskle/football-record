# NATIVE-045 — Store 当前零验证

状态：source `f7fdca78f635618ef837a85496058ab8f3fe6cbc` 已 root + cloud 两位非作者 exact PASS_SOURCE_HELD_026_ONLY；final 仅两卡收尾，clean停写后交同 HEAD 窄审。未由作者合入、推送或归档，仍供026本地候选。

- base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；登记 held026 target `3a2a26360a822ed58b886c502acf038b028dfba9`，后续实际接收 target 由root核验。
- 作者 `/root/m2_review`，非作者审阅 root、cloud；分支 `fix/m4-store-erasure-validation`。树 `/Users/liam/.codex/worktrees/m4-store-erasure-validation/20260830_足球记录`，attachment `01a15726-2a59-7720-a2f7-4be66bb39fc4`，createdAt1792463481。
- 七 owned paths 均在登记内；[计划](../../superpowers/plans/2026-10-20-m4-store-erasure-validation.md)、产品和测试在 final 保持 source 原 bytes。

已交付 `MatchStore.validateLocalBusinessErasedV4(requestID:requestDigest:scope:)` 与 concrete `SQLiteSessionRepository` 同原 store 转发。一个无 await SQL 事务重验原 Saga/parent/digest/rawscope/capability、原 control canonical bytes、保留 binding、原 pinned backend deleted/backendDeleted/revoked 证明及当前34张业务表和两类业务 witness 零；未知/未来布局、损坏证明或残留行拒绝并保全。擦除和检查共用原清单，检查不重新擦除、不改 first receipt/Saga/capability/选择或任何独立删除进度。

返回的 `LocalBusinessErasureWitnessV4` 为 Sendable、非 Codable、internal-init 的单次 SQL 快照证据。未扩 generic protocol、schema/迁移、Package/工程或其他任务。完整 Core 同一命令四 suite **271/0**（44 Core +163 Store +47 Session +17 Sync，Store含新14项），两 fresh 最低 Session sim SDK（iOS17/watch10）均 exit0，239 runtime inputs 每命令 before/post0，详见[验证卡](../validation/NATIVE-045.md)。

原 API/运行红及历史绿分层保留；source manifest SHA256 `a49e05eaeacdfae0a55a1574178f39a960c95ffe11a2be8bde3d0c0c74eb85a4` 绑定29证据。final增量不重跑测试，不预填已接收/已合并。026仍须先排空业务写入者，每轮 aggregate/reopen fresh读回，并负责 catalog、跨叶节点 current-zero 与真实环境门槛。没有实际 Simulator/SDK/账号/Health/WC/设备操作，不证明永久零、物理擦除或026/M4整包完成。
