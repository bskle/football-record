# NATIVE-035 验证记录

冻结 source：`9d4069de17f8274df38e7662445d9b22f42ff551`；最终 dev 目标：`bcf211d5f1c5ee1e5179ca4b4e37121ae1edbccf`。证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-035`。

## 因果与红绿

初始 dev 与历史 094 的测试 Git blob 同为 `ebef7a736f9b196bcc100c0850f5eed7c4c80d66`。提供的 023 focused 旧日志为 1 项 / 6 处断言失败：首项改表返回 `SQLITE_BUSY(5)`，其余五项由故障未真正注入引起。主代理也报告旧全量同一失败；本任务没有将该报告算作自己的运行。作者原样各跑 7 次均绿，保留间歇性结果，不据此声称修复。

`DevelopmentSyncPair.settle()` 观察计数，未停止接收和定时任务；`syncStateV3` 的事务使用 `BEGIN IMMEDIATE`。外部注入连接无 busy handler，因此与活动 writer 竞争时不能保证立即改表成功。六个相关路径在两 SHA 下的 Git blob / SHA-256 / 原字节保存在 `causal-inputs/` 与 `causal-inputs.json`。

受控红测在 exact 094 隔离快照中显式获取真实 writer 锁，原单次注入返回 5；旧 helper 实际 1 项 / 1 失败（`red-controlled-history094.log`，exit 1）。修复后同一场景等待首次真实 BUSY expectation（2 秒边界），明确 ROLLBACK 释放锁，再真实改表成功。helper 仅重试 BUSY，以 `ContinuousClock` 5 秒截止，其他错误或期限耗尽返回错误并由断言失败；没有固定 sleep。恢复改表也使用同一协调。

测试继续断言真实 SQLite 读失败清除旧成功、状态为 blockedIntegrity、计数未知且 peerPersisted 为 false；恢复后原事件一致，新的合法本机提交和真实远端 ACK / 事件一致性恢复。

## 最终自动验证

每条命令、cwd、exit 与耗时在同名 JSON 及 `command-results.json`；raw log 保留完整输出。focused 使用 `swift test --filter SyncStatusTests.testRealSQLiteReadFailurePublishesUnknownThenRestoredFacts`，full 使用不加 filter 的 `swift test`；package 为 `native/Modules/MatchPresentation`，scratch 分别为 `/private/tmp/football-record-NATIVE035-build/dev` 和 `history094`。

| 输入 / 独立单轮 | 结果 | raw log |
|---|---|---|
| 本任务 dev + 最终测试，focused | 1 项，0 失败，exit 0 | `final-dev-focused.log` |
| 同输入，完整 Presentation | 39 项，0 失败，exit 0 | `final-dev-full.log` |
| exact 094 archive + 同一最终测试，focused | 1 项，0 失败，exit 0 | `final-history094-focused.log` |
| 同历史输入，完整 Presentation | 39 项，0 失败，exit 0 | `final-history094-full.log` |

这些是分别运行，不相加为一次 80 项。最终 dev 测试运行于 71251 基线加最终测试；随后普通同步 bcf 只带入 034 运维 / 文档，全部 native / scripts/native 字节相同，故准确复用本轮测试输入。`git diff --check` 通过。仅测试改动，未重跑 SDK / App / 模拟器或真机；无需用户协助。

历史 archive `094c690775809eb9ce40d82d19a139ff5d9ea4d3` 的完整 310 文件审计见 `history094-snapshot-audit.json`，唯一 overlay 是 owned `SyncStatusTests.swift`；exact tar 与哈希已保存。没有读取作者未提交文件或修改 023 树，不将该旧 runtime 称作 023 最终交付。

## 审阅与冻结证据

root 质量与 m2 规格均对 source `9d4069d…` / target `bcf211d…` 正式 PASS，记录为 `review-root-source.json`、`review-m2-source.json`；root 独立完整 Presentation 39 项 / 0 失败（其日志与 exit 见质量审阅记录）。最终两文档改动后由两位审阅者再检查 exact final；产品 / 测试字节继续冻结。

Source manifest：`source-9d4069d/manifest.json`，84 个 Git 输入、65 份冻结证据，SHA-256 `96760d94788c56a067586bfba01b1ca90d1148fbb947b5fd65b26d9c7a7ee8d2`，作者逐 blob / hash / size 核过。`inputs[].path` 相对该 manifest 目录的 `inputs/`；`evidence[].path` 相对 NATIVE-035 证据根。最终 manifest 另存 `final-<最终提交短 SHA>/manifest.json`，复制相对目标的 3 个任务路径，并逐项列出原 84 输入的 final Git 对照；除 task 文档外，其余 83 个 Git blob 保持相同，另新增 validation 文档。原 manifest / raw logs / 已冻结证据不回写。

未合并长期分支、未推送、未归档；最终增量双审与实际合并 / 复测 / 清理归主代理，尚不据计划宣布完成。
