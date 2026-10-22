# NATIVE-053：原当前认证证据只读快照

状态：exact source 双审 PASS；作者最终两卡收尾并停写，待 root 与消费者最终增量审阅、实际目标接入。

- 唯一作者 `/root/m4_auth_evidence`，非作者审阅 `/root`、`/root/m4_integration_resume`（026 消费者）。
- base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；计划提交 `bed07e1e7792584f564eeff8530b7b73d49eee8d`；冻结 source `fd5b0a3468eee62b9d191eaa65dadf857d30ed2a`。
- 分支 `feat/m4-current-auth-evidence`；工作树 `/Users/liam/.codex/worktrees/m4-current-auth-evidence/20260830_足球记录`；attachment `01a1613d-2c64-7f30-a713-87f2f531ad4e`。初始 HEAD/base/branch/clean 已核，未新建共享配置或修改他人文件。
- 目标仅 held NATIVE-026，登记目标 `885f226adf87866854c987fb6ffb4b2e818bb9a4`，实际 merge target 由 root 后续核对；尚未接入 026，不入 dev/release/main。

六个独占新路径及精确 API/事务/回归计划见[具体计划](../../superpowers/plans/2026-10-22-m4-current-auth-evidence.md)。实际 source 只增加 Store reader、原 SQLiteSessionRepository extension-only forwarding、新测试三个文件，393 行；不改旧业务 gate、required protocol、schema、工程、052 路径、认证写入或旧 wire。

`CurrentAuthenticationEvidenceReadingV4.currentAuthenticationEvidenceV4(expectedIdentityGeneration:)` 从同一原 SQLite `BEGIN DEFERRED` 只读快照复验当前 binding、有效世代、auth-current、原 attempt/admission 与固定 Store trust 的 signed receipt，返回不可公开构造、非 Codable 的证据值。所有查询在 actor 内同步完成，失败显式 rollback；无网络/vault/SQL mutation/诊断补写或资源关闭。

registered/phone 与 waitingMigration/waiting 严格区分。原绑定 suspended、世代或 admission 不一致、部分/损坏证明、错误 purpose 不返回历史成功；正常初始缺失世代行沿原语义为 0。完全没有认证事实可返回 nil，不能据此声称整个 namespace 新建或无业务。此投影不刷新凭据或放开录制。device/key/cloud 依原 accepted 本地 tuple 严格关联，原 receipt 并无这些独立 signed claims；不声称抵御所有 metadata 协同重写/回滚，026 仍需原资源 owner、signer、当前独立身份和 lifetime 检查。

[验证记录](../validation/NATIVE-053.md)：实际 missing-API 编译 RED、unavailable 运行 RED、原 facade 缺转发的真实断言 RED 分层保留。新 focused 单轮 15/0；同一冻结 source 完整 Core 单轮 **272/0**（44 Core、164 Store、47 Session、17 Sync）及四项最低 iOS17/watchOS10 sim/device MatchSession 产品编译通过；106 输入 before/post/source Git 全匹配。15 项已包含于 272，不另相加。

root 与消费者已分别对 exact source 给出 PASS，无发现；源码审阅核对 106 项 Git 输入、677 份证据、实际日志及限制，未冒称 reviewer 重跑测试。root/source 审阅记录位于树外 NATIVE-053 证据目录；最终两卡后 product/test/plan 继续保持 source bytes。无 App/UI、真实 Apple/Keychain/iCloud/CloudKit/Health/WC、账号、签名、设备、部署或 whole026/M4 验收，SDK 仅编译；本机只读接口无需真机协助。

作者不 merge/push/archive 或推进永久分支。最终双审、实际接入/复验及 Git 治理由 root 负责；活跃依赖存在时保留该树及临时分支。
