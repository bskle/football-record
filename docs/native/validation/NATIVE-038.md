# NATIVE-038 验证

作者本机验证完成，等待root+m2 exact source/final双审；不提前填写PASS。source `e39cc2b24499404fd38b76e932a3c4b0ab702d5f`，final仅本卡和[任务卡](../tasks/NATIVE-038.md)，actual final SHA/治理记录位于树外。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-038`。current target `0744708e4b4cf892e36e6cce18135b4815de2f24`；original base及执行时target为e3。`source-whole-target074-manifest.json` SHA256=`48ca3d5769d9e5007ee6662fd5a1c55835f6ba45742a5c152653c577c683b856`，覆盖9Git source files、30evidence hashes、89conservative build和98host inputs；六Git输入、实际工具版本、前后输入hash及原日志另存。原e3-target source清单保留，不覆盖历史证据。

## TDD实际结果

| Slice | API红与runtime红 | 最小检查实现后 |
|---|---|---|
| 原facade/Session context | 缺overload编译红；无检查委托原internal constructor的runtime红4项/7失败 | Bootstrap4/0；七种错装配不close，不建新资源 |
| 持久身份准入投影 | 缺API/helper编译红；委托旧confirmIdentity的runtime红11项/29失败 | AccountStatus11/0 |
| 原scope lifecycle投影 | 缺API/helper编译红；委托旧setCloudScope的runtime红8项/13失败 | LifecycleStatus8/0 |

API缺失与runtime失败分开保存，不把缺API当运行反例，也不宣称旧公共API已经存在。新增checked API在TDD最小stub阶段委托原unchecked行为后运行有意义边界断言，失败后才加入检查。内部delayed-read overload与public路径共用检查，测试只延迟真实SQLite快照；公开路径固定读取其持有的SQLite facade，不开放verified bool或任意读取器。

覆盖同一SQLite路径不同连接、同facade不同Session、recording持错repo、status持错actor和close一次语义；exact binding各字段及旧generation、missing/suspended、原UTF8与Swift Unicode等价差异；pause/stop/refresh/reload/newer admission及持久suspend期间迟到结果；pending/waiting/默认Unavailable；真实已shutdown RecordingModel与requiresReload单调门。Unicode binding负例使用synthesized Codable形成legacy/malformed DTO，仅验证raw证据不能被等价字符串替代，不改变现有wire ID语法。

scope覆盖current binding、真实持久deletion saga与suspended retained原scope、NFC/NFD zone及错账号/空间/epoch/generation、stopped/refresh/newer/durable-change期间旧投影；真实SQLiteCloudLedger旧读延迟不能覆盖新scope，旧云结论清空且account准入不产生副作用。

## 固定source完整宿主与最低SDK

Swift6.4 / Xcode27.0，原部署版本不升级。实际一次fresh `xcrun swift test --package-path native/Modules/MatchPresentation --scratch-path <evidence>/build-final-host`：**74项/0失败**，原02563全部在同轮内。分项为AccountStatus11、Bootstrap4、Composition2、DevelopmentAuthorityScenario14、LifecycleStatus8、Projection4、RecordingModel8、RecordingRecovery8、SyncStatus15；不将依赖包或旧615/591相加。

| 产品target | 最低triple | 结果 |
|---|---|---|
| MatchPresentation | arm64-apple-ios17.0-simulator | fresh Build complete / exit0 |
| MatchPresentation | arm64-apple-watchos10.0-simulator | fresh Build complete / exit0 |

实际SDK命令为 `xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --triple <triple> --sdk <actual path> --scratch-path <fresh path>`。完整SDK路径/命令/时间/exit/input hashes在对应command JSON，无签名或设备安装。

| 原日志 | SHA256 |
|---|---|
| final-host.log | 3c6d131f94e7476bce7a006de3e4460d61a92728583138bef4a443f8597573fd |
| final-ios-sim.log | 6efd4d51fbdba96443b6157c9d3f84633239cab4054a7b772cd716092ea5db86 |
| final-watch-sim.log | f2180e2b502a112e22073c25a7f8d5bb897ff46c3ff12bdc847ebfff052462b3 |

各日志存在两个既有Core诊断：`MatchSession/LifecycleInboundCoordinator.swift:23/:33` 的unused repository binding（诊断和snippet各出现一次，共4处warning文字）。该文件source/base原bytes相同，038源无新增warning/error；不因本任务跨界修改Core。

## 精确输入与限制

`source-git-proof.json`核原base e3、分支/clean及Core/AccountKit/CloudSync/Apps/工程tree零变。`target074-compatibility.json`核e3→074仅GIT008六文档，九owned路径和全部89build/98host输入零delta，common runtime tree相同；按root指令不将纯docs同步进分支，不重复编译。最终两卡不改变产品/测试/计划输入，final manifest另证全部hash一致，五本地文档链接和diffcheck均核验。

硬件不适用：本任务是纯查询/装配校验，无真实账号、认证、SDK或设备执行；没有重跑App/XCUI/依赖测试包。checked presentation projection不替代AccountService/WatchRegistrationService、Core Session准入或云授权，原production/defaultUnavailable与025 Debug隔离语义保持。026完整组合、真实环境、签名/部署与本人设备仍待，不以74/两SDK提前宣布M4或026完成。作者clean停写，不merge/push/archive或推进长期分支。
