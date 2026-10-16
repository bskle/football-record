# NATIVE-014 — 持久同步仓储验证

状态：作者验证完成；主代理已确认源提交 `91e9ee84a5524e9c9e3272bcd53d7c70d85ee658` / target `58ccd9d55fa693d333d6df95ff68442dd7ce2a3b` 的质量审与独立规格审均 PASS。文档最终检查与集成由主代理执行，未合入 dev；作者未 push、merge 或 archive。

## 输入与证据

- 基线：`58ccd9d55fa693d333d6df95ff68442dd7ce2a3b`；源提交：`91e9ee84a5524e9c9e3272bcd53d7c70d85ee658`，分支 `feat/durable-sync-store`。
- 专属目录：`/Users/liam/.codex/worktrees/durable-sync-store/20260830_足球记录`；worktree attachment `01a14378-8771-7542-b269-924b1a553aae`。
- 树外证据：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-014/source-91e9ee8/`。
- `input/repository/` 保存 source 完整 158 个 Git blob 输入；`input/git-input-manifest.json` 记录 Git blob、mode、字节数和 SHA256。`manifest.json` 覆盖193个输入/日志文件，逐项重算全部匹配；其 SHA256 为 `80532473d4bd0e94f2a7a104c343ad3b6c5420d1919ad44a9bba0f3722c9c73f`。清单自身不计入自己的文件列表。
- `logs/` 保存实际红测、迭代绿测、独立 fixture 生成结果及完整 verify 输出；`logs/full-verify/` 为完整脚本的逐命令日志，来源 `/tmp/football-record-NATIVE014-build/Full/logs/20261016T071309Z`。`summary.json` 记录命令、结果与限制；编译器/系统版本在 `input/`。

## 实际自动验证

命令：`NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE014-build/Full bash scripts/native/verify.sh`，exit **0**。2026-10-16 执行，所有构建都使用专属 `/tmp`，不依赖 Desktop FinderInfo。

| 范围 | 实际结果 |
|---|---|
| Core / Store / Session 宿主 XCTest | 44 + 95 + 36 = **175**，0 failures |
| Presentation 宿主 XCTest | **22**，0 failures；总计 **197** |
| 最低 SDK 产品编译 | MatchStore / MatchSession / MatchPresentation 各 iOS17 与 watchOS10 simulator triple，共 **6** 项通过 |
| App 无签名构建 | FootballRecord-iOS / FootballRecord-Watch，generic simulator，CODE_SIGNING_ALLOWED=NO，共 **2** 项 BUILD SUCCEEDED |
| Git / fixture | `git diff --check`、精确stage白名单通过；原8个v1 fixture SHA256相对基线未变 |

## 红绿与边界

| 证据日志 / 测试组 | 证明内容 |
|---|---|
| `red-initial.log`、`red-receive.log` | 新 API/类型缺失的真实初始红测，随后实现迁移和接收 |
| `red-original-facts-migration.log` | 真实 v1→v3 故障曾留下v2、首次route曾遗漏原outbox承诺事实；统一BEGIN和原事实复验后闭环 |
| MigrationV3Tests / 旧迁移回归 | v0/v1/v2在各v3故障点恢复原版本、schema和原文件bytes；未来schema4、partial schema3拒绝且不修补；旧v1 canonical/receipt/ACK继续可重试 |
| SyncRoutingTests | 原command→route→ACK→原command lookup/retry合法、原outbox raw/hash/state不变、lost response返回同包；冻结全事实/完整祖先链；sequence独立于generation；缺事件父不路由/不耗序；namespace/peer/account/epoch/有效期不改绑 |
| SyncReceiveV2Tests | R2全链→R1旧prefix→R2重传、缺口收敛、首次receipt跨重开/本地CAS固定；真fork/缺父/跨match/global ID/索引重用拒绝；损坏facts/revision/registry/inbox/control时不ACK；原wire/Pair/closure严格检查 |
| `red-ack-state.log` | malformed ACK原文审计、未知match不能返回“0待传”成功状态；修复后通过 |
| `red-absence-contradiction.log` | incoming正面采集证据与011负面证明相矛盾时，完整raw保留，业务事务回滚；重开后原cancel lookup/retry均blocking |
| `red-terminal-body.log` | 正常/异常终结snapshot route→receive→ACK；结构校验采用有限事实时点而非开赛/接收墙钟；独立Body解码器校验 |
| `red-transient-retry.log` | SQL/连接/故障注入失败回滚后可重试，不把暂时事务失败永久标成事实损坏 |
| SyncCompatibilityTests | ACK只确认显式映射项，完整快照不顺带确认后来未路由outbox；foreign/v1 ACK不能确认v2；postMatch/abnormal权限保留；tombstone不复活；remote release/proof/verifiedNetwork/伪造development permit不产生完成或解锁 |

新固定wire fixture由独立Python脚本构造，没有调用产品encoder生成预期字节；生成脚本保存在 `input/generate-wire-fixtures.py`。包含正常终结事实、r1/r2完整链及实际观察segment标识：

| Fixture | 文件 SHA256 |
|---|---|
| `sync-v2-ended-capture-packet.json` | `4af1726a49beb6920b062ad957ee71786bf305950ed28af8419e48ef4f6393c6` |
| `sync-v2-ended-capture-ack.json` | `2e87fc0cf57fdc57f2066ddd972048bc2007bd0a682a715fa0ec5442a01dacd3` |

## 适用范围与限制

纯 Store/value/SQLite 改动，**真机不适用**；本任务没有设备适配、能力配置或签名变更。故障注入不等于物理断电、压力、真实配对传输或后台可靠性验收；最低系统仅编译，未实际运行。本次未实现 WCSession、分片/重试调度、Session通知、UI或M4生产信任。

本地 held + 有效 completion proof 保留已有完成状态；当前没有可信server release入口，遇无法验证的已存 released projection 保持原字节/原ACK台账并fail-closed。没有从peer ACK、completion proof或自报descriptor推导后台释放。正式装配生产trust继续unavailable；开发授权不等于生产账号/配对认证。
