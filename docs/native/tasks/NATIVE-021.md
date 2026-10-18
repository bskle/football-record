# NATIVE-021 参考权威后台

状态：已登记并开始；只交付无需用户协助的软件范围，不表示真实 Apple / 撤销 / 部署 / 设备通过。

| 字段 | 登记 |
|---|---|
| 作者 | /root/m4_authority，唯一写入负责人 |
| 主代理 / 审阅者 | /root；两位非作者由主代理安排，尚未审阅 |
| base_ref / base_sha | dev / `5e876cfd875585b315b57f91bcb8dc7160f8afa6` |
| 合并目标 / 登记 target | dev / `5e876cfd875585b315b57f91bcb8dc7160f8afa6` |
| 分支 | `feat/m4-authority` |
| attachment / createdAt | `01a14f8f-e54f-74c1-9bb2-3592b307337f` / `1792336192` |
| 受管 worktree | `/Users/liam/.codex/worktrees/m4-authority/20260830_足球记录` |
| 初始实际 HEAD / 状态 | `5e876cfd875585b315b57f91bcb8dc7160f8afa6` / clean，分支已核 |
| 所有权 | `backend/**`、本任务卡、`docs/native/validation/NATIVE-021.md` |
| 只读边界 | native、App、工程配置、冻结合同与其他任务全部只读 |
| 前置 | NATIVE-020 双审，实际 no-ff merge 到登记 base；主代理已同步 |
| 证据 | `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-021` |

按 [M4 计划第5节](../../superpowers/plans/2026-10-18-native-m4.md) 的021.1～4逐slice红绿后提交。真实两worker文件SQLite、严格签名、HTTP与丢响应恢复必须实跑；Node `v22.23.1`，保留SQLite ExperimentalWarning。不写生产部署、不推进长期分支、不push/merge/archive。

工程冻结细节：同设备同key的新challenge + 完整Apple验证成功签发一次性reauthenticationID，持久绑定account/device/key及issuedAt/expiry/consumed；不改变激活。lost使用的证明须在eligibleAt后新签发，初始JWT不能复用。

Software progress (2026-10-19 Shanghai): 021.1-021.4 implemented and automatically verified. Final pre-source full round: **56/56** (21 auth, 10 real HTTP/CLI, 17 lifecycle, 5 lock/config contention, 3 privacy/analytics). Runtime: Node v22.23.1 / SQLite 3.51.3, ExperimentalWarning retained.

Commits already recorded: `747d474af90f114a8d4eefa6488d5e7f788cc616` durable locks; `d6de05d` first-key initialization race fix; `8bf85c9` strict credentials and interoperability vector; `6a1d91b` lifecycle/metrics. The coherent final HTTP/codec/README/regression slice includes these cards; exact final SHA and post-commit inputs are recorded externally to avoid self-referencing commit text.

Completed software evidence includes actual two-worker same-file competition, first-result bytes across reopen, original-token auth recovery, fresh signed status, exact normal/abnormal roles, seven-day/lost grants, all migration/delete transaction failure/reopen stages, and real HTTP disconnect recovery for auth/acquire/normal activation/forced activation/delete. S21-pre1 pending-delete/migration mutual exclusion and S21-pre2 account-wide delete requestID namespace were observed red and fixed. Post-migration old phone/Watch same-key re-enrollment preserves waiting/current epoch and rejects old sessions; normal Watch release requires its own device PoP through any phone proxy.

The fixed public-only Node-to-Swift vector is `backend/test/fixtures/receipt-v1.json`; its private key was discarded. `startFixtureAuthority` now opens actual loopback HTTP on port 0 with a signing client and two-worker harness. CLI was manually started and reopened with explicit persistent development key files; no fixture bypass exists in production auth factory.

Formal source/final review: pending two non-authors. Merge/dev advance/push/archive: not performed by author. Author will stop writing after the coherent source commit and provide its exact SHA, clean status, post-commit full-suite output and complete hash manifest to the main agent.

Acceptance limits: local reference service only. Real Apple login/JWKS network, code exchange/revocation, iCloud/CloudKit, production TLS/storage/deployment/backup and physical devices remain unverified and belong to 024/026. Cloud saves are opaque authenticated-client assertions. Backend deletion does not imply CloudKit/local/HealthKit deletion. No native source or shared project configuration changed; device build/test is not applicable to this isolated backend software slice, and is not waived for M4 overall.
