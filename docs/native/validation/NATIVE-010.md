# NATIVE-010 设备集成候选验证

作者`/root/m2_recording_ui`，创建base/目标dev=`2e1f9c42f4398a50b66765a0f37f90ced95a7554`。已审008 `6e86e8f1ac647b02b8f1ef407226a10398c5d998`由主代理普通合入后初始组合=`3a9d567362f4415146352acb706e586704c6f00c`。任务branch `test/m2-device-integration`。主代理将已验证dev `505449279d6461436a051b5e6bc43324d805e3e0`（含已审012与GIT003纯治理）普通同步，**最终冻结源码=`834cac56522d88f7b11adf2c1cb98be1e3a5fca6`**；根质量及规格两名非作者均对此source确认PASS。最终文档增量审阅待决；本地候选待物理gate，不合入/推送dev、不归档。

## 最终834受影响复验

冻结105项编译/测试输入，`inputs-834cac5.json` SHA256=`f27c1416d7d0586f2d6c36f3c21e77562fe7623c9188af7b3454c44abf297f89`。源码与008/Core精确对应已审1ae/4a；与4a相比仅Phone说明、UI签名脚本及012的Presentation源/测试5条输入路径变化。Core/Workout67文件逐SHA256比对完全相同，因此未重复无变化全矩阵。

| 检查 | 本轮实际结果及来源 |
|---|---|
| Presentation / AppIntegration宿主 | 22+6=28项，零失败；`affected-834/`日志，命令exit0 |
| 未变化宿主与累计覆盖 | Core44 + Store64 + Session36 + Workout40共184项沿用下述4a90实跑；与本轮28累计212，**不是834同轮运行全212** |
| 两Simulator App | iOS / Watch无签名BUILD SUCCEEDED，实际最低部署17/10 |
| 两generic实际设备SDK App | iOS / Watch无签名BUILD SUCCEEDED，`device-source/logs/20261016T043540Z`；最终Info和最小配置entitlement检查通过，签名entitlement/profile/安装未验 |
| 45mm Watch实际UI | 当前Xcode ad-hoc脚本新增3项通过，零失败，35.87秒；`ui-source/20261016T043542Z-Watch` |
| 390pt iPhone实际UI | 当前ad-hoc脚本新增3项通过，零失败，48.57秒；`ui-source/20261016T043655Z-iOS` |
| 部署SDK来源 | 4a90已实跑十项SDK；012对应Presentation双SDK另有已审[012证据](NATIVE-012.md)，最终受影响App实际编译。未把它们冒称834同轮十项重跑 |

本轮受影响入口脚本保存在外部`final-834cac5/verify-affected-834.sh`，依次运行实际Presentation/Integration宿主及两端generic Simulator App；设备候选仍用仓库`scripts/native/verify-device-candidate.sh`，两端UI用当前`scripts/native/ui-test.sh`及`NATIVE_UI_TEST_CLASS=NativeIntegrationUITests`。新增UI核对真实SQLite中场下事实重开、UI-only启动及真实模式偏好重启（不开始Workout）。

最终证据在下述持久目录`final-834cac5/`：105项输入、`source-comparison.json`、本轮host-sim-affected/unsigned-device日志、双端xcresult/截图/AX及结果索引。后续文档提交只绑定source/head和文件hash，不改变编译输入。

本轮命令全部exit0；运行前后105项输入逐SHA256相同。`evidence-index.json`关联source、28本轮/212累计、全部6张图；`evidence-sha256.json`保存证据hash；`candidate-apps/`持久保留双端无开发者签名App供核对，不用于设备安装或分发。当前工具链Xcode27.0(27A266a)/Swift6.4，真实Team/证书未访问。

以下PNG相对持久目录`final-834cac5/`：

| 实际画面 | 路径 |
|---|---|
| iPhone真实模式重开、修正后的模拟锁说明 | `iOS/attachments/2DB5D4DC-02D0-4415-8AFF-D38B6EE6050C.png` |
| iPhone UI-only记录启动 | `iOS/attachments/05504283-3640-49DA-A972-2320DA2D1DE5.png` |
| iPhone原库场下事实重开 | `iOS/attachments/05B1CAC4-7D63-451C-A7B6-4E560A0EC1D3.png` |
| Watch真实模式重开，不开始Workout | `Watch/attachments/CE2E17EC-2E2A-4CEC-9CFD-9DF665D6E240.png` |
| Watch UI-only记录启动 | `Watch/attachments/2CF3A6FB-DE3E-4B64-9B78-BCBEA757B2CA.png` |
| Watch原库场下事实重开 | `Watch/attachments/69E9E99F-3D32-4F53-A89B-0354EEEFB219.png` |

作者实际查看真实模式两端图；Phone不再否定真实健康数据，模拟锁与真实验收模式同时可识别。每端xcresult及AX完整保留，实际朗读/触觉仍未执行。



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

主代理/规格审指出Phone旧development说明否定真实运动数据，f3facc3改为“独立开发记录与模拟开赛锁，采集方式见当前环境”。真实模式会真的写健康。Phone说明与012当前组合按顶部受影响矩阵复验，未把4a90旧结果倒写为窄修后通过。

## 证据、资源与物理gate

持久目录`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-010/`。`source-4a90bc5/`含104项inputs/环境、完整host-sdk-sim/unsigned-device阶段日志、Watch-green与iOS-unsigned-two-green-one-crash的xcresult/附件、真实ips及iOS-ad-hoc-preference-green结果。后续每轮按真实source分别保存。

候选App路径：`/tmp/football-record-NATIVE010/device-source/DerivedData-iOS/Build/Products/Debug-iphoneos/FootballRecord.app`及`DerivedData-Watch/Build/Products/Debug-watchos/FootballRecordWatch.app`；它们未签名，仅SDK产物。打开项目与本人设备步骤见[准备指南](../device-setup.md)。

010继续串行使用并保留009三个自有Simulator：Watch45mm `9E47C372-0445-4B7D-9280-01FA43DDC981`、iPhone390pt `3094D821-E635-477D-B735-3B6F85039A24`、mini375pt `BCF44456-964D-40C7-B810-AE9C369C1CDD`。未改用户配对、未下载runtime或删除设备。实际UI只iOS27/watchOS27；最低iOS17/watch10仅编译。

本人Team、唯一ID/profile/签名/安装、HK真实授权/拒绝、心率/GPS/路线、后台/锁屏保存/解锁关联、恢复/强退/重启、等待授权终结/迟到SDK、触觉/VoiceOver朗读全部pending。指南逐项保留矩阵，模拟器/fake/无签名SDK不替代物理。结束仍held不能绕锁另开；生产完整许可与释放待M4。作者不merge/push长期分支、不归档；候选保留本地待真机。
