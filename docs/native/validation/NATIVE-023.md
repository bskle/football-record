# NATIVE-023 验证

执行中。原始基线 `8d6ec935efa060ab462b2913ab8460734871ff40`。

树外证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-023`。六项 Git 输入已保存；红绿、工具与最终输入 manifest 随实际执行补充。未经执行、双审、合并的项目不记通过。

## 023.1

- 红：MigrationV4Tests 实际运行 1 项，版本 3→4 的两个断言失败。
- 绿：迁移 / legacy / sync compatibility / recovery 过滤回归单轮 Store 36、Session 7，合计 43 项 / 0；覆盖 v0～3 三故障点 rollback/reopen、future5 和 partial4 保留文件、原 legacy blobs。
- 首轮绿发现旧 schema2 降级 fixture 未移除新增 v4 表；已仅调整 fixture，原始失败日志保留 `023-1-green-attempt1.log`。
- 未改变旧 Canonical encoder；真实设备不适用此纯 SQLite DDL 检查。

## 023.2 原启动纵向

- 固定 Node public vector：有效 receipt 验签红→绿；完整 canonical intent/body/signing bytes 比对，错误环境、意图、签名和 DER 拒绝。
- authority 原结果 / control 持久化红→绿；绑定后单独 fixture permit 启动绕过红→绿。附加协议由同 SQLiteSessionRepository facade 实现，SessionRepository 必需方法不变。
- 真实 Node 子进程 + 文件 DB + 原 Session：单轮 5/0，涵盖 HTTP start、acquire COMMIT 丢响应后本地重开同 ID、异常终结后旧 acquire 不复活、status timeout、原签名 relay / nonce 重放拒绝。
- 完整 Core 包实际 host 回归见 `023-2-core-regression.log`；原 M3 fixtures 与原 wrappers 保持。
- harness 首次换行与退出故障、一次 Swift async 短路编译错误原日志保留，均已修复并重新运行。真实 Apple / SDK 与 WC relay 未测试。

## 审阅期修复：live-lock 坏时间

root 只读预审指出未验签 observedAt/expiresAt 可先做 Int64 溢出减法。新增坏 wire 测试在独立进程实测 signal 5 红；先限制客户端时间与所有服务器时间为非负 JS safeInteger 后安全抛错绿 1/0。原 HTTP 正常时间不改称失败。证据 `023-2-live-overflow-red.log` / `green.log`。

## 审阅期修复：已知终态与离线恢复

- root/m2 预审的已知 authority terminal 不得续采；已有合法比赛允许全程离线，不能把 status timeout 当终结。
- 真实 Node + 文件 SQLite + TrackingGateway：在线获知终态的重开恢复红（续采/替代 start）→绿；全 HTTP 单轮 9/0，包含已知 terminal 离线重开、recover callback 门闩之后拒替代、网络 status 失败仍同 match/recorder 恢复并建合法新 segment。
- 新开首次物理 start 仍须 fresh held；未知旧 start 仅 reconcile 原 token。terminal/release 作为持久 fence，dispatch、planRecovery、callback 和 replacement 读同 facade，网络在 queue 外。
- `023-2-fence-core-regression.log` 完整 Core 包当前单轮通过（其中含本树尚在后续 slice 的 2 项 cloud 事务测试；不当作已提交 cloud slice 完成）。真实 Workout/设备仍留 024/026。

## 023.3 Core 事务 checkpoint（纵向仍在执行）

- 云 facts/cursor/first receipt 原子性、四个 SQL fault close/reopen、双连接 CAS、原 receipt 历史只读及 generation reset：选测通过；坏 canonical scope/deletion 实际红 1 项 / 2 断言后补 validating decode。
- cloud-only / release-only 保持 pending；绑定后两种 legacy completion API 均拒绝绕过；双 proof 才完成，纠错失效旧 completion 后可用新 cloud proof 结合永久 release 重建。
- 当前完整 Core 包单轮 235/0（Core44 / Store127 / Session47 / Sync17），原始日志 `023-3-core-checkpoint.log`。schema0～3、fault、partial4/future5 与原 canonical 回归均在本轮。
- 未知云比赛仅写同 facade 的只读 `cloud_history_v4`；原 acquire 验签只授原 match/recorder 历史读取，保留原 epoch，无合成 permit，不进入 matchIDs/录制恢复候选。此为历史恢复，不是原 Workout 恢复；025 应通过 `cloudHistoryV4(scope:)` 展示。
- AccountKit CloudLedger bridge / normal HTTP / abnormal 本地事务和完整纵向尚在后续执行，本 checkpoint 不表示 023.3 全部完成。

## 023.3 同 facade 云 / 控制纵向

- 已普通 no-ff 合入 root 已验证 dev `204ea7a8c2b0d6f514fc6d4653aec9b6379a2a15`（GIT005 / NATIVE029），本树 merge `0c2d02b631b23ca3107463feaffe389839292737`。
- AccountKit 完整单轮 17/0（真实 Node HTTP 10 / CloudLedger + Session 桥 7）；Core 完整单轮 236/0（44 / 128 / 47 / 17）。日志 `023-3-account-final.log` / `023-3-core-final.log`。
- normal 双 proof、服务 terminate COMMIT 丢响应、文件 DB 重开、同 ID 恢复、下一场及旧 terminate 重放不碰新锁；normal raw Watch PoP 经手机 opaque HTTP relay，手机自身 PoP 被拒，原 nonce 重放拒。真正 WC relay 仍属 026。
- abnormal 在 HTTP 前把本地 incomplete、稳定 control intent、v2 command receipt 与 business outbox 放同一事务；六故障点 close/reopen 证明全有或全无，同 Session 原 token 收尾。
- terminal 仅来自 signed live-status、无 terminate receipt 时可开始下一场，但不造 normal release/completed；新 Session 普通 quick 在未 recover 前也读持久 terminal 拒绝。
- 云历史真实 HTTP 查询原 acquire，原 receipt 已 terminal 仍只读；缺原 receipt 整批停 token；显式 tombstone 不复活，`cloudDeletionsV4(scope:)` 给 025 同 facade 展示删除状态。已提交 receipt 在身份暂停后只读重放，新 batch 仍停写。
- 保留测试错误记录：原测试 SQL 误用不存在的 locks 表造成 fixture unwrap trap；修为 active_locks + checked unwrap。完整回归曾挂测试 Process.waitUntilExit，经自身进程采样确认后改三秒有界 terminationHandler；这些轮次未计通过。新增 SQL fault fixture 曾遗漏业务 outbox，修为原 v2 完整 seed 后全绿。
- 生产 Bootstrap、原 v2 canonical / 路由 / ACK 未变；真实 Apple / CloudKit / Keychain / Workout / 配对设备未验。

## 023.5 auth / 状态持久 checkpoint（生命周期纵向仍在执行）

- 真实 Node HTTP auth 宿主 2/0：challenge字符串UTF8 hash同时绑定 Apple nonce与原设备PoP；首次COMMIT丢响应按原auth requestID / key / canonical digest重开recover同session，错误key停写；文件DB扫描无原JWT/code/credential token。设备私钥与credential由注入接口持有，真实Keychain留024。
- 同文件Store生命周期选测3/0：auth accept三个fault/reopen保持原attempt；默认关闭分析、重复计数ID和关闭清队列；签名backendDeleted后方可本地擦业务，cloud/health独立pending且重开保留256-bit capability，revision CAS拒旧写。
- 原始红绿与测试编译/故障名修正日志均保留 `023-5-auth-*` / `023-5-lifecycle-state-*`。迁移/删除真实HTTP及全包回归尚待，未把此checkpoint计作023.5全部完成。

- auth未知结果补测：真实 Node beforeCommit 后401不能证明原请求未提交，client持久保留原attempt并限制新auth ID/challenge；实际红2断言→绿，auth单轮3/0。明确 knownRevoked/knownExpired可解除原attempt并暂停旧身份。后台永久absence防迟到补口由root独立032处理，未消费未审wire。
- 原 Store / v2 新业务也受持久 suspended 与迁移fence限制；新增直接Store绕过红→绿，生命周期Store选测单轮4/0。附加LifecycleInboundCoordinator共用同Session账号队列，不扩大原协议。
