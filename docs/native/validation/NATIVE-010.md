# NATIVE-010 设备集成候选验证

作者`/root/m2_recording_ui`，创建base/目标dev=`2e1f9c42f4398a50b66765a0f37f90ced95a7554`。已审008 `6e86e8f1ac647b02b8f1ef407226a10398c5d998`由主代理普通合入后初始组合=`3a9d567362f4415146352acb706e586704c6f00c`。任务branch `test/m2-device-integration`，最新目标治理提交`7ae65db8f662c4afcdd053f63da6462bbed57262`不改产品字节。当前源`93e17b8a9b6783cace81aec8a2e6f7a24bd24450`含Phone说明和UI脚本窄修；已审012尚待主代理同步，最终受影响组合验证和双审待决，不宣称已合入/推送或物理通过。

## 冻结4a90实际组合

输入source=`4a90bc52e9d222ed351319681c6129a90f6c1cbe`；104项编译/测试输入清单SHA256=`a7bda7e77f9d84d1ce041469edba3846bb357548d9d2cc8c092d05d191b662b5`。执行前后逐文件比对不变。

| 检查 | 实际结果 |
|---|---|
| 宿主XCTest | 204通过零失败：44 Core + 64 Store + 36 Session + 14 Presentation + 40 WorkoutCapture + 6 AppIntegration |
| 最低部署SDK | Store/Session/Presentation/WorkoutCapture/AppIntegration各iOS17 + watch10，共十项通过 |
| Simulator Apps | iPhone / Watch无签名构建通过 |
| generic实际设备SDK Apps | iPhone / Watch无签名构建通过；检查最终Info.plist最低17/10、读写/WhenInUse用途、最小后台模式、双BundleID关联与配置entitlement；没有profile/签名/安装证据 |
| 45mm Watch实际UI | 新增3项零失败：UI-only开始、原库事实重开、真实模式偏好重启但不开始Workout，37.10秒 |
| 390pt iPhone实际UI，unsigned | UI-only及原库事实重开2项通过；真实模式在HKSource初始化SIGABRT，未请求权限/开始Workout |
| 同源iPhone正常Simulator ad-hoc | 仅重验上述真实模式偏好启动1项，TEST SUCCEEDED；未改产品源码，不把它当健康授权或物理成功 |

完整组合命令 `NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE010/verify-source scripts/native/verify.sh` exit0，实际日志`logs/20261016T041823Z`；实际设备SDK命令`NATIVE_DEVICE_BUILD_ROOT=/tmp/football-record-NATIVE010/device-source scripts/native/verify-device-candidate.sh` exit0，日志`logs/20261016T041821Z`。

新增UI用`NATIVE_UI_TEST_CLASS=NativeIntegrationUITests`；实际目录`ui-source/20261016T041823Z-Watch`及`20261016T042010Z-iOS`。Phone失败不是HK权限拒绝或真实设备失败：ips堆栈为`+[HKSource _uncachedDefaultSourceWithEntitlements:] → AppleWorkoutDriverFactory.init(HealthAuthorization.swift:30)`，无签名Simulator缺失模拟App标识/entitlements。控制变量仅改Xcode `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`，同源定点通过。Xcode自身生成FAKETEAMID的Simulated.xcent仅模拟器，不代表本人真实Team或注册App ID；不接触任何账号、证书/profile。93e17b8据此把UI脚本改为正常Simulator ad-hoc；generic实际设备候选仍无签名。

## 回归、装配与边界

6项AppIntegration宿主回归：模式偏好重新打开与坏JSON/坏类型拒绝；保留真实dataset不可作为UI fixture；真实SQLite active和ended-held记录阻止离开；unknown/savedAwaitingLink/未决操作禁止切换；HR bpm/米转km/米每秒转kmh及0/缺失/unsupported；恢复请求在attach前、busy期间和执行中新请求均不丢失。原始缺API红、偏好边界红及后续绿均保留，不把包路径脚手架错误算产品红绿。

每App持有同一个真实LiveMetricsChannel/Apple factory/gateway，依Bootstrap已审接缝装配。实时值仅内存，GPS为horizontalAccuracy精度文字；没有健康数值写入业务SQLite/outbox或日志。生产许可M4前固定unavailable；UI-only模式始终Unavailable，真实模式不降级。真实验收固定namespace、偏好只存环境，不存currentMatch索引。初始化/切换扫描实际SQLite全部记录；busy及串行switch锁、扫描后同model/generation/pending再检查，阻止提交交错。Watch系统回调排队到同model.load→原MatchSession，未直接调factory或start/begin。

两App仅普通HealthKit entitlement；share/update和WhenInUse用途，Watch workout-processing、Phone实际路线所需location后台。未加Always/audio/background-delivery，Team未知、占位Bundle ID未注册。无签名最终Info及配置entitlement不证明签名App能力。

主代理/规格审指出Phone旧development说明否定真实运动数据，f3facc3改为“独立开发记录与模拟开赛锁，采集方式见当前环境”。真实模式会真的写健康。最终受影响Phone验证与012组合仍待执行，未把4a90旧结果倒写为窄修后通过。

## 证据、资源与物理gate

持久目录`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-010/`。`source-4a90bc5/`含104项inputs/环境、完整host-sdk-sim/unsigned-device阶段日志、Watch-green与iOS-unsigned-two-green-one-crash的xcresult/附件、真实ips及iOS-ad-hoc-preference-green结果。后续每轮按真实source分别保存。

候选App路径：`/tmp/football-record-NATIVE010/device-source/DerivedData-iOS/Build/Products/Debug-iphoneos/FootballRecord.app`及`DerivedData-Watch/Build/Products/Debug-watchos/FootballRecordWatch.app`；它们未签名，仅SDK产物。打开项目与本人设备步骤见[准备指南](../device-setup.md)。

010继续串行使用并保留009三个自有Simulator：Watch45mm `9E47C372-0445-4B7D-9280-01FA43DDC981`、iPhone390pt `3094D821-E635-477D-B735-3B6F85039A24`、mini375pt `BCF44456-964D-40C7-B810-AE9C369C1CDD`。未改用户配对、未下载runtime或删除设备。实际UI只iOS27/watchOS27；最低iOS17/watch10仅编译。

本人Team、唯一ID/profile/签名/安装、HK真实授权/拒绝、心率/GPS/路线、后台/锁屏保存/解锁关联、恢复/强退/重启、等待授权终结/迟到SDK、触觉/VoiceOver朗读全部pending。指南逐项保留矩阵，模拟器/fake/无签名SDK不替代物理。结束仍held不能绕锁另开；生产完整许可与释放待M4。作者不merge/push长期分支、不归档；候选保留本地待真机。
