# NATIVE-035：SQLite 读故障测试协调

状态：排障与红绿验证中，尚未交付。

- 负责人：`/root/m3_ui`；非作者审阅：`/root`、`/root/m2_review`。
- base / dev 目标：`71251f9afbb299e97344ff082c1d83bf17a110df`。
- 分支：`test/m4-presentation-read-fault`。
- 独占工作树：`/Users/liam/.codex/worktrees/m4-presentation-read-fault/20260830_足球记录`。
- attachment：`01a15065-98f1-7cf2-909b-f0088d457b66`，createdAt `1792350198`；初始 HEAD 与 base 相同且 clean。
- 只写 `SyncStatusTests.swift` 与本任务 task / validation 两文档。无产品、工程、包或脚本变更；不写 023 工作树。

按 systematic-debugging 先核原始失败与 Git 输入，再以真实 SQLite 锁协调关闭故障注入竞争；保留注入成功、unknown 清旧成功与原始事实恢复的断言。分别在本任务 dev 与 exact committed `094c690775809eb9ce40d82d19a139ff5d9ea4d3` 的临时 Git archive 验证 focused / 全 Presentation；该历史快照只验证测试兼容，不是已接受依赖或 023 最终通过。仅测试改动，SDK / 设备不适用。

主代理负责双审、no-ff 合并、实际 merge 复测及清理；作者不推进长期分支。
