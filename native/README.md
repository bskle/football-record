# 球历原生工程

正式名称：球历 / football-record；Xcode技术名：FootballRecord。

用Xcode27打开FootballRecord.xcodeproj，选择共享scheme FootballRecord-iOS或FootballRecord-Watch与相应模拟器。最低iOS17/watchOS10，Swift6。Watch为现代单目标App，iOS构建并嵌入Watch产品。两个App实际消费MatchCore/AppIdentity，目前界面仍只有“开发预览”空状态，没有正式开赛入口。

在仓库根目录执行 scripts/native/verify.sh，依次运行共享包swift test、iOS Simulator与watchOS Simulator无签名构建，任一步失败返回非零。产物、DerivedData和日志位于忽略的native/.build/，可用NATIVE_BUILD_ROOT=/absolute/path改为独立目录。仅宿主行为测试可执行 swift test --package-path native/Packages/MatchCore。

## 共享引擎与保存边界

NATIVE-002实现纯内存比赛事件引擎与33个独立XCTest方法；App仍是预览壳。MatchDescriptor固定matchID/recordingDeviceID和稳定StartIntent；不可变MatchEvent保存原事实与追加revision。MatchReplay.replay(descriptor:events:now:completionEvidence:)确定性计算双轴区间、比分、出场、生涯及诊断，无Timer累计时长。

LiveMatchRecorder/PostMatchEditor只产生待保存事实与影响预览。应用复制staging值，事务保存descriptor/事实/outbox，成功后才替换状态并反馈成功；NATIVE-003负责事务库与故障恢复，当前不能把内存追加说成已保存。sequence在sourceDeviceID内唯一，修订使用根事实sequence/sourceDeviceID/eventID保留同刻业务顺序。start/end可改时间、不可删除或颠倒；损坏导入诊断conflict，已知终结禁止再次start。

正常本地结束先为endedPendingSync，不进入生涯；可信完整保存/durable ACK适配器完成实际工作后才调用TrustedCompletionEvidence.acceptedByCompleteSaveBoundary。凭据绑定matchID、当前终结ID、去重原始事实全集canonical SHA256；乱序/相同重传不失效，新增事实/修订使旧凭据失效。核心不实现保存或ACK验证，完成与后台锁释放独立。

先保存StartIntent，真实网络适配器验证许可后才调用TrustedStartPermit.acceptedByTrustedNetworkBoundary。DevelopmentStartFixture带developmentSimulation标记，不代表真实锁或E2E证据。手机赛后更正/异常终结授权由已认证应用边界提供，不能接管采集。异常终结保持incomplete与原记录设备，迟到end不能晋级completed；后台锁状态独立，不由本地结束推定释放。

手机完全没有start也可保留可信异常终结：incomplete+missingStart，不造开始；matchElapsed快照此时可nil，matchDuration/appearanceDuration/elapsed(at:)未知为nil，timingComplete=false。迟到start/score恢复计算但仍incomplete，未知影响差值nil并要求确认。暂停期间允许比分补记，双时长冻结、场上状态保留，下场不暂停比赛。completed且实际出场才计出场/胜率/体能；未出场completed仅计场次，健康缺失返回nil。

工程基础与引擎只是M1部分交付。实际证据见 [NATIVE-002验证](../docs/native/validation/NATIVE-002.md)；不代表可靠事务保存、真实采集、联网锁或完整M1验收。

## 签名与真机

com.example.footballrecord和com.example.footballrecord.watchapp是本地开发占位Bundle ID，不代表已注册。没有Developer Team、entitlements、HealthKit、CloudKit或Sign in with Apple能力。WKCompanionAppBundleIdentifier与iOS占位ID一致；正式配置时同步修改两个target及该键。

用户能连接配对iPhone/Watch后，在Xcode登录Apple账号，为两个target配置本人Team、正式App ID与签名，设备解锁并信任Mac、按提示开启开发者模式后运行。账号授权与Team归属由用户完成，无签名SDK构建不能证明签名安装或付费分发资格。

签名安装、真实启动、配对通信、采集、后台恢复、联网锁与分发留后续阶段。本任务纯业务引擎没有设备能力变更，真机验证不适用。工程壳原始启动证据见 [NATIVE-001验证](../docs/native/validation/NATIVE-001.md)。
