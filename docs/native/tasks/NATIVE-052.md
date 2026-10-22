# NATIVE-052 删除控制面 fresh reauthentication

2026-10-22：本机软件实现的 whole source `04c5393cceeb5dbc6ec90d3af422d26d63ce93de` 已由两位非作者 `/root`、`/root/m4_recovery_audit` 审阅通过。本次仅补齐任务卡与验证卡，final 两卡窄审待主代理执行；尚未交付合入 NATIVE-026，也未完成 whole026 / M4 或原生发布。

依据[计划](../../superpowers/plans/2026-10-20-m4-deletion-control-reauth.md)、[合同](../contracts/m4-account-lock-cloud.md)和[验证卡](../validation/NATIVE-052.md)。初始 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，accepted050 `c031a15a5dfd1aa51f219770c6cee57bdc36006c` 及046 `f05e987b3c91fef81f34e22a588d77915a6648db` 普通合入后，effective base 为 `07c1b92a75d1c9998afecbfb8cb731a464b414af`。合并目标仍是 held026 `test/m4-e2e-integration`；最初登记的 target `0e7292df9b1f4eef2edc31d3d7954eee92ceb892` 只作历史依据，实际接收 SHA 由主代理届时核对。

## 写入与恢复记录

临时分支 `fix/deletion-control-reauth`，当前受管树 `/Users/liam/.codex/worktrees/m4-deletion-control-reauth-resume/20260830_足球记录`，attachment `01a16137-5f80-7890-ae1f-6e9ef60cd196`。当前唯一作者 `/root/m4_deletion_resume` 续接先前作者 cloud，仍限于已登记20条路径。工程、Package、SDK、App/UI 和旧业务入口未扩权。

旧树 `/Users/liam/.codex/worktrees/m4-deletion-control-reauth/20260830_足球记录` 启动清理后缺失；从保留的 snapshot `08a387fae82c56837585e8d389b61f97356f35e7` 恢复6个明确 Core WIP 文件，逐 blob 核对，未改写历史。旧 attachment `01a157d5-d491-7062-b011-005625f415a7` 与 snapshot ref 保留；不以缺目录推断已安全归档。

## 已交付行为

- Backend 独立 `deleteControl.v1` purpose 与 challenge / Apple / recover 流程，只允许原 device/key/account/epoch/cloud scope、原 capability 和 canonical 删除 parent。fresh Apple 证明后可在同事务预留原 client intent 的 absent→requested，原 delete 请求首次 bytes/digest 不变，appleRevocation 不回退。
- 控制凭证只用于原删除或查询、精确原锁的已验证 status，以及一次明确确认后持久化的稳定 abnormal 请求及其查询。不能新建身份、恢复业务、创建 Match/permit/capture、acquire、normal 或开启新锁。
- 原 Store / Session facade 增加独立可选控制入口，同 SQL 检查原 Saga/control/capability、raw scope、binding/key/generation、原 attempt 和可信签名。保留 immutable 首次证明与后续 closing，兼容046 inventory、045 current-zero 和 LocalErasure 严格历史验证。
- AccountKit 使用原 client/signer/vault 和独立当前身份来源；await 前后核对原 parent 与完整 tuple。已持久化的 auth attempt 仅 recover 原 ID；401、404、timeout 不关闭 unknown。仅在 challenge 响应丢失、尚无 auth attempt 且该流程尚未派发 Apple code/auth POST 时，重新核对后可要求调用方显式提供新 challenge/auth IDs；不自动造 ID，不把它解释成 auth 从未提交。
- 所有公开操作由 owned FIFO 任务串行，取消会传递并等待尾部；stop 永久拒绝新入口并 cancel/join 所有 HTTP/SQL/vault 正面事实尾部，不关闭借用资源。026 owner 仍负责与 Lifecycle resume 串行及关闭原库前的整体 join。
- vault 前后最后一次异步检查是原 Store 的 same-SQL current-ready 只读门，要求原始 signed raw、当前未 closing、原 generation/key/parent 及 TTL 一致；之后仅同步核对运行状态、完整 tuple 与当前时钟，再写 vault 或返回 ready。

## 审阅问题闭合

| 问题 | 实际修复与回归 |
| --- | --- |
| C52-1 丢失 ready 后直接收到可信 closing | 可关闭原 attempt，无虚构 ready；knownAbandoned 不证明历史从未 commit。 |
| C52-2 Watch/auth ID 碰撞污染 Store | 同 SQL 检查全部相关 ID，并在 COMMIT 前完整验证；碰撞不新增行、保留原 Watch bytes。 |
| C52-3 已 closing 后晚到 ready 被接受 | active accept 在同 SQL 拒绝 closing；原首次 ready 和 closing 仍可历史读取。 |
| C52-4 SQL/vault 回调跨过 TTL | pre-vault、readback 和已 join vault 后均重验当前时钟；过期不返回 ready。 |
| C52-5 旧 attempt 搭配新 generation 发 HTTP | 构造、签名、HTTP 前校验原 attempt 完整 tuple/generation；真实回归为零额外签名/HTTP。 |
| C52-6 vault 等待中原 attempt 已可信撤销 | 真实 HeldVault + Node revoke + 第二 recover 先红后绿；vault 后 same-SQL 门拒绝 ready，保留并 join 已准入的正面 write。 |

## 验证与交接

本轮冻结输入下，完整 Core **323/0**（44 Core、194 Store、68 Session、17 Sync）和完整 AccountKit **80/0**（含26项专用控制流程）是两个实际命令，合计 **403/0**。四项最低 iOS17/watchOS10 sim/device AccountKit 产品编译均 exit0。运行前后207条输入的 mode/blob/size/hash 与 source 一致，无漂移；源码双审同时核对53条证据哈希。

Backend 本轮未改；Node **228/0**（193 top-level）保留 `1c41d88277025b1101a5c5b0e5b61c6b35ee3bb2` 独立历史层，49条实际 Backend 输入与当前 source 相同，未重跑也未计入403。更早317/321 Core、624/628整轮与各次 RED 保留原层次，不累计成当前一次通过。

当前只交付本机 HTTP/SQLite/受控 verifier 软件。same-SQL 门是当前 ready 的线性化检查，不持有跨 vault/网络/独立身份来源的锁，也不保证之后状态不变；已经准入的 vault 正面写入可以跨过 closing/TTL，必须 join 并保留事实，不能宣称回滚或 SQL/vault/时间全局原子性。

真实 Apple、Keychain、iCloud/CloudKit、Health、WC、签名安装、本人设备、账号和部署验证延后；四 SDK 仅证明编译。production trust/provider/bootstrap 默认 Unavailable；026 仍负责原资源装配、renew/abnormal UI 接线、全部 owned catalog 擦除和整包验收。作者停写等待 final 双审，不合并、推送、归档或推进 dev/release/main。
