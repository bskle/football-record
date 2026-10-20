# NATIVE-047 validation

source `bbf421b9783d04c1b099c0bbeff08fd821832f94` 已root+m2双非作者审PASS，held026；final仅两卡待窄审，复用同源验证而不重测。依据 [任务卡](../tasks/NATIVE-047.md) 与 [实施计划](../../superpowers/plans/2026-10-20-m4-cloud-erasure-reopen.md)。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-047`。`source-aggregate-manifest.json` SHA `6b119a8f73de9d0167aa09c5ec1535e70a2bc07a123f85a27153b2e74ec4f311`；43evidence、5完整Git对象、6owned、240runtime、5commands及6本地链接已核。

| 实际层次 | 结果 |
|---|---|
| upstream026旧反证 | exact源/测试/report/log保留，2tests/6fail/0unexpected；logSHA `141f2e8353a0867600918b1f5912a3334258a50cf03c6970c3a223e01c424276`，不计047通过 |
| 047 API编译红 | 新initializer缺失编译失败，单独保留，不称runtime |
| 047真实运行红绿 | 普通init/fresh erase委托占位10tests/26fail/0unexpected，原两source+测试逐hash副本保留；最小修后10/0 |
| 新source完整Cloud | 一次fresh97/0、0unexpected（原87+新增10）；logSHA `b76c3bedfa9974feb02b0d93b32b6761642c1b48fccf73865e73b6a94a95f93f` |
| 最低产品 | iOS17/watch10各simulator/device SDK共4fresh CloudSync产品，全部exit0，无实际设备执行 |

`source-commands.json`保留5实际argv/SDK路径/logSHA，逐命令240inputs before/post0。实际回归包括：同inode丢receipt/fence且恢复upload保全阻断、v3不迁移/重删、missing不创建、empty不初始化、future/unknown/malformed/symlink原件保全、enqueue/stage/scopeIssue普通write拒绝、other scope原bytes、firstreceipt/currentzero、beforeCommit rollback与COMMIT丢响应重开、known live WAL和原分解Unicode requestID。原normal initializer主体除private false-mode赋值逐bytes等effectiveBase，全部原Cloud/migration回归保留。新source矩阵无warnings。

source审阅：root `review-source-root.json` SHA `cc79f358d4b7b9fff71a33d5e0e5e06b5d3cb5d5bd9f72960aa1699f8fb93444`；m2 `review-source-m2.json` SHA `0cebc63acec22496a0a0b8ce2a92e69365a159e13045dee8c89533fb732c2bc7`，均PASS_SOURCE_HELD_026_ONLY。final同HEAD审阅和实际集成状态待root执行，不预填已合并。

known WAL/SHM允许原SQLite协调/恢复，不承诺其bytes/inode不变；live WAL测试为另一原连接存活，beforeCommit/COMMITlost为确定性故障，不是进程崩溃或物理掉电证明。026仍须证明原catalog/file ownership、gate并join全部写者、保留firstreceipt后只走replay-only及聚合全部owned组件。无App/Package/工程或SDK业务调用变更，无真实CloudKit/账号/签名/安装/本人设备/部署/whole026验收；本软件数据库控制测试无需设备操作，最低SDK仍已实际编译。
