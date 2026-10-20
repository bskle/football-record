# NATIVE-045 验证

source `f7fdca78f635618ef837a85496058ab8f3fe6cbc` 已 root + cloud exact 双审 PASS_SOURCE_HELD_026_ONLY。final仅本卡与[任务卡](../tasks/NATIVE-045.md)，产品/测试/[计划](../../superpowers/plans/2026-10-20-m4-store-erasure-validation.md)不变；作者clean停写后交同HEAD最终窄审。base2cab与登记held026 target3a2a保留，后续实际接收由root核验。

## 实际红绿

| 层次 | 原证据与结论 |
|---|---|
| 工具限制 | `api-red.log` 是受限sandbox不能写Swift缓存的环境失败，不能当产品/API红 |
| API编译 | 正常工具链的 `api-compiler-red.log` 实际缺 `LocalBusinessErasureWitnessV4` 编译红，exit1 |
| 历史completed反例 | `runtime-red.log` 最小历史状态实现 **9项52失败/0unexpected**；同inode恢复旧行、34表逐表残留、witness/错误proof/布局不能被历史completed放行。实际三源 before/post hash及副本保留 |
| 首修 | `focused-green-attempt.log` **9/0**，属于中间源码 |
| typed损坏边界 | `expanded-red.log` **12项1失败**，原Saga损坏抛DecodingError；最小包装typed corruptControl后 `focused-green.log` **12/0**。对应副本为运行后、修复前保存，未追造全量before快照 |

最终新增14项由下面完整Core同轮执行。包括原 Store 实际提交行 →删号擦除 →同inode原行恢复、全部34表即使坏payload仍阻断、normal-intent/migration-checkpoint原LIKE谓词（含大小写）、原parent/digest/rawscope/进度/capability、签名/原control/binding改绑、未知/未来DDL保原file/catalog/version、原擦除COMMIT丢响应、两连接后续读检测与只读不触写故障、raw Unicode zone NFC/NFD不混域、原 concrete wrapper、frozen-v1真实迁移后擦除/读回。重复/重开验证的保留控制 bytes、原 receipt/capability/progress/revision均不变。

## exact source 完整相关验证

`source-commands.json` 记录三命令实际argv、exit、耗时和logSHA；`source-inputs.json` 绑定239项 native/backend/scripts 精确Git bytes/mode/blob。每命令before/post0，源码冻结，未拼接不同source计数。

| 命令层 | 实际结果 |
|---|---|
| `swift test --package-path native/Packages/MatchCore` | 单命令四 executable：44 Core +163 Store +47 Session +17 Sync = **271/0** |
| MatchSession arm64-apple-ios17.0-simulator | fresh，exit0 / Build complete |
| MatchSession arm64-apple-watchos10.0-simulator | fresh，exit0 / Build complete |

271包含原Store149+新14；042独立 source 的新增 Session/Presentation 不在本轮基线，不相加成新整包数。保留原 LifecycleInboundCoordinator 第23/33行 unused repository 警告，不称零诊断。没有启动Simulator、实际SDK/provider/账号/Health/WC/设备操作；两最低SDK仅编译。

## 来源与限制

树外 `native-validation/NATIVE-045/source-aggregate-manifest.json` SHA256 `a49e05eaeacdfae0a55a1574178f39a960c95ffe11a2be8bde3d0c0c74eb85a4` 绑定29证据、7owned/3Git/239runtime；4本地链接通过。root source review SHA256 `b28bdc4f0c4876ed2a476f2360470815f86bf681ceafffadb8ad1e674e83f75e`，cloud source review SHA256 `5397da1057fe3dbc2fd1979e462021ac5e173468fb9a0d8ac7eff16ca94c2a0f`。最终aggregate另核两卡与原29证据/239输入零差异，不改source清单、自引用最终SHA或重复测试。

只读witness只表示一次原连接SQL快照：返回后再恢复旧行，须下一次fresh验证才发现。026需先排空写入者并在所有aggregate/reopen入口检查；本任务不重擦、不进独立删除分项、不新建DB/连接/receipt、不改变Saga/capability/选择。catalog、跨叶节点当前零、最终关闭、真实环境及026整包验收均未由此证明。候选held026，未推进长期分支、未发布，M4未完成。
