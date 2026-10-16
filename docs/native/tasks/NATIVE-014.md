# NATIVE-014 — 持久同步仓储

状态：源实现、作者验证及源提交双审 PASS，文档收尾完成后待主代理最终检查与集成；未合入。

| 登记项 | 本任务事实 |
|---|---|
| 作者 / 主代理 | `/root/m3_store` 唯一写入；`/root` 统筹双审、验证与合并 |
| 基线 / 合并目标 | `dev`，完整 SHA `58ccd9d55fa693d333d6df95ff68442dd7ce2a3b`；合并目标 `dev` |
| 分支 / worktree | `feat/durable-sync-store`；attachment `01a14378-8771-7542-b269-924b1a553aae`；createdAt `1792133334` |
| 实际目录 / 初始 HEAD | `/Users/liam/.codex/worktrees/durable-sync-store/20260830_足球记录`；上述基线，写入前 clean |
| 唯一写入 | `native/Packages/MatchCore/**`、必要 `scripts/native/verify.sh`、本卡、014 验证卡及实施小计划 |
| 禁止写入 | App、工程、Presentation、根 AGENTS、其他合同及历史任务卡；不撤销他人成果 |
| 前置 | NATIVE-013 双审并实际合入上述基线；冻结合同 [m3-durable-sync.md](../contracts/m3-durable-sync.md) |

交付 schema3 additive 迁移、不可变 route、独立 sequence、完整事实 receive、固定首次 ACK/receipt、显式映射 ACK 与持久同步状态。不实现 WCSession、分片调度或 Session 通知。

实施见 [小计划](../../superpowers/plans/2026-10-16-durable-sync-store.md)。先红测、后实现；提交精确路径及 Conventional Commits。作者不得 merge/push/archive。双审、实际 merge 和生命周期由主代理后续登记。

验证证据保存在树外 `native-validation/NATIVE-014/`，不只依赖 ignored 构建目录。纯 Store 真机不适用；SQLite 故障注入不等于物理断电、压力或真实设备传输验证。

## 作者交付

源提交：`91e9ee84a5524e9c9e3272bcd53d7c70d85ee658`（15 个源/测试/新 fixture 文件）。实际全量脚本 exit 0：44 Core + 95 Store + 36 Session + 22 Presentation = 197 项宿主 XCTest、6 项最低系统 SDK 产品编译、2 个无签名模拟器 App 构建。原 8 个 v1 fixture SHA256 不变。详见 [验证卡](../validation/NATIVE-014.md)。

树外证据包含该 source 的全部 158 个 Git 输入、193 个输入/日志文件的 SHA256 清单；`manifest.json` SHA256 为 `80532473d4bd0e94f2a7a104c343ad3b6c5420d1919ad44a9bba0f3722c9c73f`。实际路径为 `native-validation/NATIVE-014/source-91e9ee8/`，绝对根见验证卡。主代理已确认质量审与独立规格审对该 source / target `58ccd9d55fa693d333d6df95ff68442dd7ce2a3b` 均 PASS。作者保存证据后只提交本卡、验证卡及小计划，停止写入；文档最终检查、合并 SHA 和生命周期由主代理登记。

## 015 交接

- `MatchStore.init(url:syncEnvironment:)` 的兼容默认值为 `.production`；route/receive/ACK 的 production 调用 fail-closed。开发库必须在本机创建 Store 时显式传 `.development(databaseNamespace: 本机实际namespace)`；授权 namespace 只与本机配置比较，两端使用各自独立 namespace。首次调用还把账号/pair/epoch/稳定设备绑定到新增本地 context，不从 incoming 数据反向配置。
- 新 DTO / `PeerTrustProvider` / `UnavailablePeerTrustProvider` 在 MatchStore；本任务未添加 `MatchSync`、`SyncRepository`、`SyncInboundCoordinator`、分片算法或 Session 行为，均由015基于已审源接手。
- schema3 已预建空表 `sync_delivery_v3(delivery_id PRIMARY KEY, match_id, record BLOB, checksum)` 与 `sync_fragments_v3(fragment_id PRIMARY KEY, match_id, record BLOB, checksum)`，全列 NOT NULL。015可在 record 内持久化合同约定的稳定分片、尝试和期限字段，不在已发布schema3上静默补表。014另有 `sync_ack_controls_v3`、`sync_context_v3` 与不可变记录的 `sync_registry_v3`；SQL 仍只经唯一 MatchStore actor。
- 原 `pendingBusinessOutbox` 继续返回原业务项。新 route/ACK 不修改原业务 outbox；发送必须使用保存的 canonical 原包。完整源快照先检查 closure，missing-parent 只给 ancestryIncomplete，不消费 sequence。
- 当前没有 M4 server release-proof 校验入口。测试分别证明 held+本地 completion proof 不回退，以及已存 unsupported released projection 在 receive 时 fail-closed、原字节和首次 ACK 台账保留；没有把 completion proof 当作后台释放许可。
