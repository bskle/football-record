# NATIVE-010 M2设备集成执行计划

> **For agentic workers:** 使用 superpowers:executing-plans 逐项执行；唯一作者不变，主代理与规格代理双审。

**Goal:** 在本地候选接入已审真实采集模块，形成可打开、可签名配置、可重启恢复的设备验收包；无设备部分一次完成。

**Architecture:** 两App实际复用 `Apps/iOS/Integration` Swift包，负责环境偏好、固定真实验收dataset、数据库扫描门禁、恢复请求排队和内存metrics映射。每App生命周期只持有一个真实channel/factory/gateway，Bootstrap保持原生产许可；所有恢复通过同RecordingModel/MatchSession，禁止直接新建Workout。

**Tech Stack:** Swift6、SwiftUI、HealthKit/CoreLocation、现有SQLite/MatchSession/MatchPresentation/WorkoutCapture；iOS17/watch10。

创建base/目标dev=`2e1f9c42f4398a50b66765a0f37f90ced95a7554`；已审008=`6e86e8f1ac647b02b8f1ef407226a10398c5d998`；主代理普通合并后的初始组合HEAD=`3a9d567362f4415146352acb706e586704c6f00c`。唯一作者 `/root/m2_recording_ui`；其他作者写独立树，不撤销其改动。所有权限定Apps、工程、Configuration、UITests、scripts/native、nativeREADME、本计划/010卡/010验证、device-setup；不改三个共享模块/Core/母计划/AGENTS。

## 1. 登记与红绿回归

- [ ] 独立提交本计划与010卡，报告SHA供根/规格窄审。
- [ ] 新建 `native/Apps/iOS/Integration/Package.swift`（产品AppIntegration，依赖现有三个包），测试位于 `Tests/AppIntegrationTests/IntegrationTests.swift`。
- [ ] 先写红测：偏好重新打开保留原真实模式和固定dataset；无效偏好失败而非fallback；active/unknown/savedAwaitingLink/未解锁记录禁止离开真实环境；米/秒单位与0/缺失/unsupported；恢复请求在attach前或busy期间保留，ready后仅用同一个恢复闭包。
- [ ] 命令 `swift test --package-path native/Apps/iOS/Integration --scratch-path /tmp/football-record-NATIVE010/IntegrationHost`；先证明红，再实现最小策略至全绿。

## 2. 唯一生命周期与实际App接线

- [ ] `Sources/AppIntegration/IntegrationPolicy.swift`：Codable模式偏好只存环境与UI演练dataset，不存currentMatch；真实dataset固定 `device-acceptance-v1`，namespace沿Bootstrap canonical前缀。启动和切换扫描该实际SQLite的全部match，任何错误/未释放锁/活动或待核对采集均保守阻断切换，恢复只能原dataset。
- [ ] `Sources/AppIntegration/RecoveryInbox.swift`：内存pending标记在初始化前排队；attach后busy不消费，待可用再load。并发回调合并但执行期间的新请求保留下一轮，禁止新Session/factory。
- [ ] `Sources/AppIntegration/MetricsMapping.swift`：仅内存映射HR原值、distance/1000、speed*3.6，GPS为定位精度文字；无效数未记录、unsupported保留、实际0保留。
- [ ] `Sources/AppIntegration/AppAssembly.swift`：实际创建 `LiveMetricsChannel()` → `AppleWorkoutDriverFactory(metrics:channel)` → `AppleWorkoutGateway(factory:factory)`，同实例注入AppBootstrap真实模式；独立UI-only模式仍Unavailable。只创建一个当前DB协调器，缓存/复用该环境模型；环境切换先完成扫描门禁。默认/偏好错误显示失败，不降级fixture。
- [ ] 修改两App入口并显式链接AppIntegration；恢复/metrics任务由App生命周期持有。Watch新增 `WorkoutRecoveryDelegate.swift`，`handleActiveWorkoutRecovery()`送同一个inbox，环境加载前也不丢失。
- [ ] 修改两端已有页面开发入口：明确真实验收与纯UI演练，真实模式持续开发模拟锁；新建UI演练也受真实DB门禁。显示失败原因和重新核对，不清数据/造UUID/绕锁。

## 3. 工程与设备候选

- [ ] 传统PBXGroup/package产品明确注册；每新增代码实际target编译。两App ordinary HealthKit entitlement；Info.plist配置share/update用途和WhenInUse定位。Watch `WKBackgroundModes=workout-processing`，Phone实际路线后台所需 `UIBackgroundModes=location`；不加Always/audio/background-delivery，不编造Team。
- [ ] `scripts/native/verify.sh`保留158现有回归/六SDK/双sim，加入WorkoutCapture40、AppIntegration有意义宿主回归及双SDK。`scripts/native/verify-device-candidate.sh`构建generic iOS/watch实际设备无签名候选，检查最终Info/entitlements/17与10最低部署；未签名不宣称profile/安装。
- [ ] `native/UITests/NativeIntegrationUITests.swift`新增双端实际纯UI smoke与Debug固定验收环境重启测试：用任务自有设备和隔离偏好suite，真实模式只验证环境恢复/入口，不以模拟器授权成功证明HK。

## 4. 验证、指南与交付

- [ ] 执行新增红绿、完整198既有host+实际新增数、八SDK及双sim/generic实际设备App构建；最终检查plist/entitlement。
- [ ] 两端各运行新增UI smoke/重启用例，保存xcresult、PNG、AX与输入hash；只用三个既有任务自有sim，不改用户pairs/下载runtime/删除设备。
- [ ] 写 `docs/native/device-setup.md`：无设备可完成范围、候选路径、Xcode打开、本人账号/未知Team、自动签名、两唯一BundleID相容、配对/信任/DeveloperMode。引用已核Apple primary当前免费普通HK/background支持，不要求先付费；profile/sign/install仍待设备。
- [ ] 设备矩阵逐项pending：账号/签名/安装、写入/拒绝/定位、锁屏保存和解锁关联、路线/后台、恢复/强退/重启、等待授权时结束及迟到回调、物理触觉。不把fake/SDK/simulator算设备通过。
- [ ] 按计划/源/最终docs分Conventional Commits；全部输入/日志/xcresult保存工作树外NATIVE010。交两名非作者审阅，报告clean后停止。候选保留本地，真机gate前不merge/push长期分支、不归档。
