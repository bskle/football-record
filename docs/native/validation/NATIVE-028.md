# NATIVE-028 验证记录

日期：2026-10-19，上海。状态：下列首次候选证据属于 `6d87b95b8a9bc25b387d104d52e4e64e52799ff0`，其 root + m2 审阅结果为 BLOCK（Q28-1真实采集metadata兼容）。当前修复另记末节；首次证据和manifest保留原样。不宣称真实HealthKit或M4完成，不合dev、不push、不archive。

## 输入与所有权

| 输入 | 值 |
|---|---|
| 完整 base / 登记目标 | `204ea7a8c2b0d6f514fc6d4653aec9b6379a2a15` |
| 首切片 | `8d8e8e7e1184968e9511d228bd81dafe4352db61` |
| 最终可审HEAD | 树外 `input-manifest.json` 与 `final-head.txt`；不在本提交写自身SHA |
| 分支 / attachment | `feat/m4-healthkit-deletion` / `01a14ff9-ea8d-7db2-9b92-43f615b27a92` |
| worktree | `/Users/liam/.codex/worktrees/m4-healthkit-deletion/20260830_足球记录` |
| 作者 / 审阅 | `/root/m4_sdk_preflight`；root + m2 尚待exact审阅 |
| 产品输入 | 独立模块12文件SHA256，`product-inputs-before-final.json`；最终命令后复核全等 |

只写新 `native/Modules/HealthKitDeletion/**` 与自身任务/验证卡；无外部SwiftPM依赖，不改Core/AccountKit/CloudSync、008/018采集候选、App/project/scheme/entitlements或脚本。普通业务擦除目录外的SQLite仅保存本地删除控制事实。当前App source和完整UUID/metadata选择都不上传后台/云。

## 最终同输入实际命令

| 层次 | 原命令 / 树外日志 | 实际结果 |
|---|---|---|
| 完整host | `swift test --package-path native/Modules/HealthKitDeletion --scratch-path /private/tmp/football-m4-028-host`；`028-final-host.log` | 单轮26/26，14 Ledger + 10 Service + 2 Driver，0 failure，exit0 |
| iOS17 simulator | `xcrun swift build --package-path native/Modules/HealthKitDeletion --target HealthKitDeletion --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-ios-sim`；`028-final-ios-sim.log` | Build complete，exit0 |
| iOS17 device SDK | 同package/target，`--triple arm64-apple-ios17.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-ios-device`；`028-final-ios-device.log` | Build complete，exit0 |
| watchOS10 simulator | 同package/target，`--triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-watch-sim`；`028-final-watch-sim.log` | Build complete，exit0 |
| watchOS10 device SDK | 同package/target，`--triple arm64-apple-watchos10.0 --sdk "$(xcrun --sdk watchos --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-watch-device`；`028-final-watch-device.log` | Build complete，exit0 |

Xcode27.0（27A266a）/ Apple Swift6.4，原版本输出在initial-tools/initial-swift。五份最终日志无warning。四triple实际编译真实条件编译SDK分支；最低runtime、arm64_32设备执行及签名/entitlements未由此证明。第一轮17项及首次四SDK日志单独保留，不与26项累计或冒充最终同输入。

## 红绿与故障证据

| 行为 | 证据与最终断言 |
|---|---|
| 完整选择/独立确认 | `028-1-models-red.log`，2项/13 assertions runtime红；canonical domain覆盖请求ID/时间/全部target，UUID排序、metadata原值；空/重复UUID/超256/坏ID/时间/同ID异选择拒绝 |
| 独立文件台账 | `028-1-ledger-red.log`，8项/9 failures runtime红；`028-1-ledger-green.log` 8/8；业务目录擦除后控制请求与确认仍在，原bytes/digest重开不变 |
| 所有权/坏库 | 控制URL拒绝位于业务擦除目录，flock单owner，close再open；未来schema/损坏原文件保留，无reset/rebuild |
| callback服务与predicate | `028-2-service-predicate-red.log`，17项/14 failures runtime红；`028-2-service-predicate-green.log` 17/17。未确认0calls、真实只读SQL连接观察executing/attempt/digest已COMMIT后才调driver |
| timeout/迟到/并发 | 同未决attempt不重复发；两个service共享同ledger单赢家；超时awaitingOutcome，迟到/duplicate不覆盖首次终态；close/reopen新attempt只用原scope，旧owner结果不推进新attempt |
| COMMIT故障 | submit前回滚/后丢响应保留原请求；begin前后故障均0 SDK调用；callback成功COMMIT前失败重开retry0不编造首次数量；callback COMMIT后丢响应恢复原receipt且不再调用driver |
| 持久不一致 | `028-2-persisted-boundaries-runtime-red.log`，13项/4 failures纯runtime红；未知confirmation字段、executing/issue不一致、回执时间错误在恢复前fail-closed且DB原bytes不变。原先两个STRICT BLOB fixture写错类型的诊断日志另保留，不算目标红证据 |
| callback时钟 | `028-2-callback-time-red.log`，1项/3 assertions runtime红；实际callback时间早于原Health确认不得产生receipt |
| 权限/数量 | denied/undetermined独立Health失败；负数或超target数invalidResponse；success count0只记该scope本次本机结果，绝不推断全库空、读权限或其他分项完成 |
| source/逐tuple范围 | 当前App source AND OR(逐UUID AND match/recorder/segment)；交叉组合与第三UUID不匹配，Phone/Watch source异同明确处理，不静默过滤扩大或清空选择 |

内部SQL故障注入只在@testable测试入口可用，生产public initializer没有fault参数。受控driver不实例化HealthStore；SDK默认executionEnabled=false，constructor无HealthStore副作用，未调用query/delete/requestAuthorization。SDK source/type/metadata/predicate固定，分享状态只描述write/sharing权限，无读权限推断。SDK headers的实际路径与SHA256在 `sdk-header-inputs.json`，覆盖iPhoneOS/WatchOS的HKQuery/HKHealthStore/HKSource；官方依据见模块README。

## 后验与保留

026从原采集registry映射明确范围及028的requestID/selectionDigest/confirmation/per-scope receipt；025提供实际独立确认UI。本模块不推进后台身份、CloudKit或普通本地删除。真实Phone/Watch App source归属、sharing权限、签名/entitlements、本人明确确认后的目标Workout删除与设备间同步均未验；需要真实用户操作的门槛留026。未删除关联quantity/route样本，也没有这种能力或完成声明。SDK候选在真实门槛前留树，不合dev/release/main。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-028`。保留initial/final六项Git输入、完整红绿与最终日志、12产品输入SHA256、SDK header输入、`input-manifest.json`与`evidence-manifest.json`。最终manifest绑定实际HEAD与原文件hash；作者不自行合并、推送、归档或删除分支。

## Q28-1 修复记录（当前）

重新执行基线：本树原HEAD `6d87b95b8a9bc25b387d104d52e4e64e52799ff0`，原base `204ea7a8c2b0d6f514fc6d4653aec9b6379a2a15`。root指定最新已验证target `36daa5526aac447cedab8c0b636c2db80b09cfa6`；其native相对base零差异，先提交clean修复checkpoint再ordinary merge，不消费未审031。

- `Q28-1/q281-actual-metadata-runtime-red.log`：新增3项测试均实际运行失败于028构造器invalidRequest，包含真实Session start/recover/restart；不是编译红。最初fixture过早close共享Core库的诊断另存，不算P1目标红例。
- `Q28-1/q281-raw-tuple-fidelity-red.log`：放宽opaque metadata后，真实token与字节上界已绿，Unicode不同原字节被Swift String相等错误合并的1项tuple断言红。
- `Q28-1/q281-interop-green.log`：3/3、0 failures、exit0；真实派生token、斜杠/空格/Unicode/组合形式、canonical原值、控制ledger确认重开、逐目标匹配与0/NUL/4096字节边界通过。tests-only Core/MatchSession，产品target不依赖Core。

修复clean checkpoint：`76002b2fc24d223506b04a356a6a26c5ba0d55fb`；普通merge source：`a94280190bb18c910f8cf50038888fafdef3074a`，父提交为checkpoint与exact target `36daa5526aac447cedab8c0b636c2db80b09cfa6`。target的native相对base204零差异，未消费031；`sync-proof.json`保存父提交与输入全等。

| 本轮同source验证 | 命令 / Q28-1日志 | 实际结果 |
|---|---|---|
| 完整host | `swift test --package-path native/Modules/HealthKitDeletion --scratch-path /private/tmp/football-m4-028-q281-host`；`q281-final-host.log` | 单轮29/29：3 CaptureInterop + 14 Ledger + 10 Service + 2 Driver；0 failures、exit0 |
| iOS17 simulator | `xcrun swift build --package-path native/Modules/HealthKitDeletion --target HealthKitDeletion --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-q281-ios-sim`；`q281-final-ios-sim.log` | fresh scratch，exit0 |
| iOS17 device SDK | 同package/target，`--triple arm64-apple-ios17.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-q281-ios-device`；`q281-final-ios-device.log` | fresh scratch，exit0 |
| watchOS10 simulator | 同package/target，`--triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-q281-watch-sim`；`q281-final-watch-sim.log` | fresh scratch，exit0 |
| watchOS10 device SDK | 同package/target，`--triple arm64-apple-watchos10.0 --sdk "$(xcrun --sdk watchos --show-sdk-path)" --scratch-path /private/tmp/football-m4-028-q281-watch-device`；`q281-final-watch-device.log` | fresh scratch，exit0 |

五份本轮最终日志均无warning，实际工具版本另存本轮initial-tools/initial-swift。13份模块输入同步前/后/命令后全等；tests-only依赖的34份Core Package/Sources文件SHA256与原base204已提交源一致，`reviewed-test-dependency-inputs.json`逐项记录。`package-description.json`证明产品target不依赖Core，测试target使用MatchCore/MatchSession。SwiftPM describe产生的两文件自建缓存已移至树外保留，路径与hash另记；不作为产品输入。最终文档提交只更新两张028卡，final HEAD/clean/15个任务文件及source输入绑定于本轮 `input-manifest.json`，全部本轮证据hash列于 `evidence-manifest.json`。

新证据位于上述根的独立 `Q28-1/`，旧两个manifest hash由 `retained-previous-manifest-hashes.json`复核保留。新一轮root + m2 source/final审阅尚待进行。未执行HealthStore/query/delete/权限请求；SDKNSPredicate只按原值传参并编译，不称真实SDK匹配或删除已验。旧26与新29不累加。
