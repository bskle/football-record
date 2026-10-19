# NATIVE-041 verification

source `ff5075d41d29bd9e675bd6327f9208c5d7a956d5` 已root+m2 exact source双审PASS，仅held026 retained artifact组件。final仅[任务卡](../tasks/NATIVE-041.md)与本卡，产品/测试/[计划](../../superpowers/plans/2026-10-20-m4-health-artifact-store.md)保持source bytes，final同HEAD待独立窄审。原base2cab、accepted039final7547、实际dependency merge dadb60e与登记held target27e83分层，不消费后续WIP。

## 实际红绿与诊断

| 层次 | 实际结果及原日志 |
|---|---|
| 依赖基线 | root329 inputs零差异，复用039的53/0+4SDK，不计为041新运行 |
| slice1 | 缺API编译red，最低unavailable scaffolding缺MatchStore import的历史编译诊断保留；executable red7项/11失败(7 unexpected) →green7/0 |
| slice2保全 | runtime red15项/31失败(1 unexpected) →最终15/0；原schema/canonical/owner/DB/未知文件保全与真实casealias均执行 |
| slice2故障 | 缺fault API编译red后runtime22项/30失败(1 unexpected) →22/0，8个实际child exit86 |
| slice3 | 首日志缺MatchSession import编译失败；executable28项/4断言失败，其中2条为坏JSON未typedblocked的真实反例，2条是测试误以为Foundation standardized NFC/NFD URL保留不同path的错误前提。修正前提后不将这2条称额外产品缺陷；补近16MiB和跨进程lease，最终同轮30/0 |
| 完整相关回归 | `swift test --package-path native/Apps/iOS/Integration --scratch-path /private/tmp/football-NATIVE041-host`，实际单轮 **83/0**（同轮旧53+新30）；full-host.log SHA256 `8035c8f6d99b37d1334d5e07fcec58612f640235b51de10156f72da43116e471` |

slice2-preservation-green为Swift guard各逗号表达式缺try的编译失败；green-2保留了known SHM协调bytes错误恒定断言及symlink fixture未移除既有sidecar的测试错误。按root已批准的WAL恢复边界修正，仅SQLite已知协调控制允许变化；原DB/owner/未知文件保全断言不降低。全部原日志留存，未覆写或将失败计作通过。

新30项覆盖：raw/prepared firstbytes/独立Unicode parent BLOB/不同rawscope拒绝、实际SQLite重开与丢响应、只收紧的各类预算/深路径owner写前预算、owner/DB/rootinode与祖先、未知文件/未来schema/坏canonical/known sidecar类型/格式、真实casealias与symlink、跨handle和跨进程lease、本/父目录barrier失败、完整EXCL候选与foreign目标保护、COMMIT前回滚及之后丢响应、已提交WAL缺SHM恢复、异步provider期间事务及close/换owner迟到拒绝；实际039+028准备/确认重开、原UUID/firstconfirmation、unknown interrupted不重派与旧callback不改新ledger。

完整轮9个child exit86含独立进程lease，初始化DBsync/ownersync/EXCL前/rename后parentfsync前/parentfsync后，以及SQL COMMIT前/后/后缺SHM三种。它们是受控进程退出和代码顺序证据，不是物理掉电或存储硬件durability证明。近上界原artifact为 **16776833 bytes**，写入、超限拒绝、重开、原bytes/digest一致。

## 最低 SDK 产品

每条实际命令为 `xcrun swift build --package-path native/Apps/iOS/Integration --target AppIntegration --triple <下表> --sdk <xcrun对应实际SDK路径> --scratch-path <独立fresh目录>`。完整argv、SDK路径、exit、输入及原logSHA见树外commands.json。

| Triple | 实际结果 | 原日志 |
|---|---|---|
| arm64-apple-ios17.0-simulator | exit0，Build complete | ios-sim.log |
| arm64-apple-ios17.0 | exit0，Build complete | ios-device.log |
| arm64-apple-watchos10.0-simulator | exit0，Build complete | watch-sim.log |
| arm64-apple-watchos10.0 | exit0，Build complete | watch-device.log |

四项fresh scratch，只编译AppIntegration及依赖，不运行真实SDK。保留Core LifecycleInboundCoordinator.swift第23/33行既有unused repository警告，文件输入未变，无041新source warning。未执行整App/UI或全部叶包/Node测试。

## 输入、双审与边界

source-input-manifest记录140build/148host，conservative331包含依赖原329零差异+新source/test。全host与四SDK每命令331 inputs before/post0，逐项同source Git；source-git-proof记录7Git对象/5owned、明确mode/blob和clean含ignored。source-aggregate-manifest SHA256 `642b3e53a285b28d9b9f5f73bb1e7fa2088302c8757e2191364cca9f0c3bd5bf`绑定53份原证据。root source review SHA256 `9c539b381cc3f5e019731ce9fc5cfbf9596c64f1094b302807d3f4dd04ac2cef`、m2 review `33ea4b33a6ca862c3cce31c7a4596c156e032b5c1b9b75c9ea2491c5e16149d3`均PASS_HELD_026。final增量manifest另外证明仅两卡提交、runtime/plan原bytes及source53证据不变，不回写自SHA。完整证据树外native-validation/NATIVE-041。

实现固定WAL+FULL及原SQLite恢复协议；known WAL/SHM可重建协调bytes/inode，不承诺任意坏sidecar逐bytes不变，不写clone/手工WAL重放。明确未知名字/类型/symlink、错原owner/DB、未来不支持header/schema先拒绝；坏raw/prepared typed block，不READONLY_RECOVERY转空库初始化。prepared仅自洽校验，实际parent权威仍039；full seal默认Unavailable，仅026provider读回，不自产/缓存seal。

本任务没有HealthStore查询/删除、实际平台source观测、授权、真实账号设备或物理掉电执行。controlled seal与driver fixture只验证软件契约，不证明026 production catalog/fullseal组合或全owned清除；caller仍须验收原installation/namespace/scope和全部可删根，保留saga/capability/028selection并聚合其他组件。M4未完成，未发布。
