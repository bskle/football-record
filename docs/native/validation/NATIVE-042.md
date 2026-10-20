# NATIVE-042 验证

source `fd4f0a94ca2b7a338e595fd7bbb32dfe4c1e196d` 已 root + cloud exact 双审 PASS_SOURCE_HELD_026_ONLY。final 仅本卡与[任务卡](../tasks/NATIVE-042.md)，产品/测试/[计划](../../superpowers/plans/2026-10-20-m4-session-retirement.md)不变；作者停写后交同 HEAD 最终窄审。原 base2cab、登记 held026 target1e522与后续实际组合分别记录，不将旧验证层当作本轮。

## 实际红绿

| 层次 | 实际结果与原证据 |
|---|---|
| 基线 | root 冻结238 runtime inputs；既有 Core257 / Presentation74 为历史基线，不是042新运行 |
| Session API/运行 | 缺 API 编译红与运行红分开；最低空边界后1项6处失败 →最初4/0，随后补至7/0 |
| Model API/运行 | 缺 beginRetirement 编译红；运行4项12处失败 →4/0；后补反馈派生 history 与自身 updates 注册，6/0 |
| 原 A 不可被 B 取代 | `retained-observation-red.log` 两项4失败（1 unexpected）：写失败后恢复用 B.unknown 覆盖 A.running、不同 settled 误清 A →修后9/0 |
| permit 派发前门禁 | `permit-dispatch-red.log` 原 intent COMMIT 回包挂起期间退役，仍新派发1次而非0；1项1失败 →修后10/0 |
| monotonic B 不能当原 A 证明 | `retained-normalization-red.log` 一项两处失败，覆盖 savedAwaitingLink 和 stopped+captureFailed；修后18原 CaptureReconciliation +11 Retirement 同轮29/0 |

5621 检查点 Core264/0、Presentation78/0属于旧 source。c9 fresh full 的唯一失败是旧 lost-wake 测试要求额外 reconcile；同测试原 `[start, finish]` 与同 token 断言通过。最终保留挂起 projection/并发 end 时序及这两条断言，增加原 A.running 持久、无冗余同 op reconcile 和 finish settled，取代过时调用次数；`lost-wake-sql-replay-green.log` 单测通过。旧 `final-core-host.log`、`final-commands.json`、`final-inputs.json`完整保留，首命令失败后其余七命令未运行，不视为旧全矩阵通过。

所有原日志保留，包括缺 API 编译红和真实运行断言红；事后整理的 provenance 明确标注时间，不追造 before-input 证据。原 source 规范化/数据库重试红绿见树外 `source-evidence-notes.json`。

## 最终 source 的完整相关验证

本轮命令、argv、exit、耗时、logSHA 和前后输入见 `source-fd4f0a9-commands.json`，运行输入见 `source-fd4f0a9-inputs.json`。每命令241项 native/backend/scripts 精确 Git bytes，before/post0；不是重跑所有独立 Node/Cloud/Account suite。

| 实际命令层 | 结果 |
|---|---|
| `swift test --package-path native/Packages/MatchCore` | 268/0 =44 Core +149 Store +58 Session +17 Sync |
| `swift test --package-path native/Modules/MatchPresentation` | 80/0 =原74 +新6 |
| `MatchSession` arm64-apple-ios17.0-simulator | fresh，exit0 / Build complete |
| `MatchSession` arm64-apple-watchos10.0-simulator | fresh，exit0 / Build complete |
| `MatchPresentation` arm64-apple-ios17.0-simulator | fresh，exit0 / Build complete |
| `MatchPresentation` arm64-apple-watchos10.0-simulator | fresh，exit0 / Build complete |
| FootballRecord-iOS generic iOS Simulator | CODE_SIGNING_ALLOWED=NO，exit0 / BUILD SUCCEEDED |
| FootballRecord-Watch generic watchOS Simulator | CODE_SIGNING_ALLOWED=NO，exit0 / BUILD SUCCEEDED |

两条完整宿主命令一轮合计348/0；四个最低模拟器 SDK 产品和两个 unsigned App 为另外六条编译命令，不拼入测试数。实际 App Info 最低版本为 iOS17.0/watch10.0。保留未改 Core LifecycleInboundCoordinator 第23/33行 unused 警告及 AppIntents metadata 等原工具诊断，不称零诊断。

新 Session11项覆盖原 perform/reconcile 正向结果 join、写前失败首次抛错/后续仅 SQL 保存、COMMITlost 原 canonical 读回、原事实不被其他 settled 或 pending-save 归一化吞掉、已派发 permit 迟到与退役前 intent 回包后不能新派发、并发退役/结束 stream、初始 updates 读取 join 和原 Lifecycle facade仍可用。新 Model6项覆盖直接 prepare、load/history、既有 UI 快照/指标清除、反馈派生 history、自身 updates 注册以及 SyncStatus 注册 join/正常独立复启。旧恢复/ACK/同 token lost-wake 断言保留。

## 来源与限制

树外 `native-validation/NATIVE-042/source-aggregate-manifest.json` SHA256 `94b4267f2263e72a37b66319693606efa6f5b432fcd1ec7641e7c7d4e28a3d3e` 绑定42证据；`source-git-proof.json`绑定20 owned paths/6 Git对象、mode/blob 与 clean。root source review SHA256 `ef1304a94c2226c897a32402bc3df1575e1c6f29fee52447b7049a873582ce80`；cloud source review SHA256 `e28c426cf88f58957ebf498065623cbe450fbb977af2cb0e479bbbea98b49659`。final aggregate另核仅两卡差异与42原证据/241运行输入不变，不改 source 清单、自引用最终SHA或重复测试。

运行 gateway/SQL 及循环门闩均为本机受控测试；没有 Simulator 启动或 UI 操作，没有真实 provider/采集 SDK/权限/HealthStore/WC/账号/本人设备/部署。数据库写失败只表示保留内存原观测并阻断成功，不能承诺崩溃后尚未写入的回调仍在。退役成功表示自身工作排空与已有返回事实的持久证明，不冒称 physical Workout 已保存或所有本地数据已删除。026仍须按 beginRetirement →原 Session.retireBusiness →Model.shutdown 顺序组合，保留原 Saga facade，完成全部叶节点 current-zero、catalog及真实环境门槛后另行关闭。M4未完成，未晋长期分支、未发布。
