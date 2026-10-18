# NATIVE-035：SQLite 读故障测试协调

状态：源码双审 PASS，作者交付并停写；最终文档增量审阅、实际合并与清理由主代理完成。

- 负责人：`/root/m3_ui`；非作者审阅：`/root`（质量）、`/root/m2_review`（规格）。
- 初始 base / dev 目标：`71251f9afbb299e97344ff082c1d83bf17a110df`；最终已验证 dev 目标：`bcf211d5f1c5ee1e5179ca4b4e37121ae1edbccf`。
- 分支：`test/m4-presentation-read-fault`；独占工作树：`/Users/liam/.codex/worktrees/m4-presentation-read-fault/20260830_足球记录`。
- attachment：`01a15065-98f1-7cf2-909b-f0088d457b66`，createdAt `1792350198`；初始 HEAD 与 base 相同且 clean。
- 测试提交：`cdab2d13bdb1464bf5bf2fcc13bdc13d39f9ad58`；按主代理指令普通 no-ff 同步已验证 dev 后，冻结 source：`9d4069de17f8274df38e7662445d9b22f42ff551`。同步只接收 034 后台运维与文档，native / scripts/native 输入零差异。

只修改 `native/Modules/MatchPresentation/Tests/MatchPresentationTests/SyncStatusTests.swift` 与本任务 task / validation 两文档。未改产品、工程、包或脚本，未写 023 工作树，未合入 023 源码。

`settle()` 的计数稳定不代表异步写任务已经停止；外部 SQLite 单次改表遇活动写锁会返回 `SQLITE_BUSY`。测试显式持有真实 writer，验证原注入方式返回 5；随后只在该错误发生时协作让出，并以单调时钟 5 秒期限等待锁释放。其他 SQL 错误立即失败。注入和恢复均断言真实 `ALTER` 成功，继续验证旧成功清空、未知计数、原始事实未变及后续本机提交与真实 peer ACK 恢复。没有忽略错误、任意 sleep、伪造 UI 状态或删除强断言。

最终本任务 dev 与 exact committed `094c690775809eb9ce40d82d19a139ff5d9ea4d3` 临时 Git archive 各自 focused 1 项及完整 Presentation 39 项通过；历史快照仅验证测试兼容，不代表接受依赖或 023 最终通过。SDK / 设备不适用于本次 test-only 改动。root 与 m2 已对 exact source / 最终目标分别给出 PASS，root 独立 full 39 项通过。详见[验证记录](../validation/NATIVE-035.md)。

主代理负责最终双审、任务分支 no-ff 合入 dev、实际 merge 复测与同步；023 消费该已审测试后再判断其完整交付。任务提交被必要目标接收、无活跃依赖且证据保存后，才原生归档并安全 `git branch -d`。作者未推进永久分支、推送或归档。
