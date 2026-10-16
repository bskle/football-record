# 球历原生工程

正式名称为“球历” / `football-record`，Xcode 技术名为 `FootballRecord`。使用 Xcode 27、Swift 6，最低 iOS 17 / watchOS 10。打开 `FootballRecord.xcodeproj`，选择 `FootballRecord-iOS` 或 `FootballRecord-Watch` 共享 scheme 与对应模拟器。iPhone target 嵌入现代单目标 Watch App。

当前任务已将共享会话接入原生记录页面：Watch 为比赛/实时状态与四快记两页，iPhone 为比赛、历史、生涯、设置四标签，历史仅展示已保存事实骨架。赛后纠错、分析与路线页面留 M5。App、共享页面及测试均显式注册到实际 target，不能以文件存在替代编译。

正式入口的开赛服务在 M4 前明确不可用，保留原开赛意图供重试，不会偷偷取得模拟许可。010本地候选在Debug设置/Watch入口提供两种明确环境：纯界面演练使用独立数据库及Unavailable gateway；真实设备验收使用固定可重开数据集及实际HealthKit/定位适配器，**会真的写入健康运动数据**。两者持续显示“开发模拟锁”，不能代表生产开赛锁或跨设备E2E。环境偏好保存，当前比赛只扫描实际数据库恢复；真实记录活跃、未知、待关联或锁未释放时，不能切换或新建演练。结束先进入 `endedPendingSync`，不会因本机保存而冒充完整完成、释放锁或立即另开一场。

## 验证与证据

在仓库根目录运行：

```sh
NATIVE_BUILD_ROOT=/tmp/football-record-check scripts/native/verify.sh
```

脚本依次执行 MatchCore / MatchStore / MatchSession 共享包宿主 XCTest、Store 与 Session 的双端最低部署 SDK 编译、MatchPresentation 宿主 XCTest及双端最低部署 SDK 编译、两个App无签名Simulator构建，随后增加WorkoutCapture及Apps内AppIntegration的宿主回归/双端SDK编译（共十项SDK）。任一步失败返回非零。产物和日志可用独立 `NATIVE_BUILD_ROOT` 指定；Desktop FinderInfo 影响代码签名时使用 `/tmp`，不清除源码 xattr 或他人产物。

实际 UI 验收需使用已安装 runtime 的模拟器 UDID，脚本不创建、重配或删除模拟器：

```sh
NATIVE_UI_BUILD_ROOT=/tmp/football-record-ui scripts/native/ui-test.sh Watch WATCH_SIMULATOR_UDID
NATIVE_UI_BUILD_ROOT=/tmp/football-record-ui scripts/native/ui-test.sh iOS IPHONE_SIMULATOR_UDID
```

两端 scheme 均含 XCUI target。UI 脚本实际 launch/tap/swipe、核对按钮 frame/已保存显示变化并导出 xcresult 截图与可访问性树。`ONLY_ACTIVE_ARCH=YES`限定测试设备架构。UI执行使用Xcode正常Simulator ad-hoc签名，让其生成simulated application identifier/entitlements；不使用真实Team/profile/证书。无签名iPhone真实模式启动在HKSource的失败及同源ad-hoc定点通过均保留，不算真实授权证据。仅运行集成用例可加`NATIVE_UI_TEST_CLASS=NativeIntegrationUITests`。测试启动参数仅在 Debug 生效，dataset、失败注入和固定测试 clock 不进入生产入口。纯宿主或 SDK 构建不替代实际 UI 启动，更不证明 HealthKit、GPS、后台或触觉手感。

基础已集成事实及证据见 [NATIVE-006](../docs/native/validation/NATIVE-006.md)、[NATIVE-007](../docs/native/validation/NATIVE-007.md) 与 [NATIVE-011](../docs/native/validation/NATIVE-011.md)。009基线的158宿主、六SDK、双App及两端七XCUI证据见[NATIVE-009](../docs/native/validation/NATIVE-009.md)。010候选4a90组合已执行204宿主、十SDK、双sim/双generic实际设备SDK无签名构建；最终同步source834包含已审012修复；本轮Presentation22+Integration6，未变化184项沿用旧源，累计覆盖212而非单轮全跑。两端App及实际交互的精确来源见[NATIVE-010](../docs/native/validation/NATIVE-010.md)。历史 M1 组合 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 的 70 项测试仅是当时证据，不是当前测试数或原生 UI 验收。

## 事实、事务和展示边界

`MatchDescriptor` 固定 matchID、recordingDeviceID 与原 `StartIntent`。不可变 `MatchEvent`、追加修订及采集 revision 是事实；`MatchReplay` 从事实与展示时间派生比分、比赛/上场双时钟及诊断，不按秒落库。暂停冻结双时钟且保留场上状态；上下场仅影响上场时长，不能冒充 Workout 暂停。四快记共享 1000ms guard，撤销仅针对最后一次快记并以追加 revision 保留审计，撤销后可立即纠正。

`LiveMatchRecorder` 只 staging。`MatchSession` 串行编排请求，`MatchStore` 用系统 SQLite WAL / synchronous=FULL 事务保存事实、采集操作、首次 receipt 与 outbox。UI 只接受已提交 snapshot/receipt，成功触觉只由首次确认 receipt 触发；失败不采纳 staging，不用旧点击快照覆盖已到达的更新。响应不明保留原完整 request 原样重试；只有明确 stale 且持久 command 查无提交，才刷新后分配新 command。

006 已实现 additive v1→v2 迁移和采集元数据落盘，保留 v1 canonical 请求、包和 receipt 兼容。`CaptureRevision` 保留同场/同设备下真实 Workout 关联和已知或未知窗口、缺口；未得到实际 Workout UUID 不造 segment。持久 `CaptureOperation` 在事务外执行/对账，未知保留 `needsReconciliation`，保存待解锁保留 `savedAwaitingLink`，不盲建第二个 Workout。011增加严格的未创建证明：同token原start持久notCreated、无正向观测/真实窗口或片段并通过完整历史校验时，才允许取消未决finish；迟到矛盾原始观测保留并阻断该证明。一般unknown仍继续对账。正常结束不制造 `completed`；完整保存凭据同时绑定当前业务事实与完整采集 digest。

没有可信 peer 时业务变更保留 `unrouted` outbox，不制造手机目标或把传输成功当持久 ACK。旧包/ACK API保留完整性校验；实际同账号认证、配对、传输和可信 ACK 来源仍待 M3。checksum 仅校验完整性。生产许可、账号、后台唯一锁与云仍待 M4。

`MatchPresentation` 直接消费已集成 `MatchSession`，只投影事实并处理保存/重试/只读状态。心率、GPS、距离和速度走独立可选内存展示通道，缺失显示“未记录/不支持”，真实零值与未知分开，不进入业务 snapshot/outbox。010仅在App层接入已审WorkoutCapture：每App生命周期同一个metrics channel/factory/gateway，生产与真实验收用该真实gateway；生产许可仍由Bootstrap固定unavailable。UI-only装配始终Unavailable，不静默降级真实模式。恢复信号在初始化/命令busy期间排队，并回到同model/MatchSession；没有直接驱动第二次Workout开始。许可及namespace隔离固定，不接受外部伪许可。

## 签名与真实采集

`com.example.footballrecord` 与 `com.example.footballrecord.watchapp` 是本地开发占位 Bundle ID，尚不代表注册。010本地候选已配置两App普通HealthKit entitlement和读/写、WhenInUse定位用途；Watch为workout-processing，Phone真实路线后台为location；没有Always/audio/HealthKit Background Delivery。无签名generic实际设备构建可运行`scripts/native/verify-device-candidate.sh`，产物Info及配置entitlement检查不等于真实签名entitlement/profile或安装。候选在真机门禁前不入dev、不推送。操作步骤、固定真实数据集、结束仍held不能另开场、免费普通能力支持与全部物理pending矩阵见[设备准备](../docs/native/device-setup.md)。

用户连接配对 iPhone / Watch 后，在 Xcode 登录本人 Apple 账号、为两个 target 配置所属 Team、App ID 和签名，设备解锁并信任 Mac，按系统提示开启开发者模式。正式 Bundle ID 同时更新两 target 与 `WKCompanionAppBundleIdentifier`。账号授权、Team 归属和真机签名由用户条件决定，无签名构建不证明设备安装或付费分发资格。
