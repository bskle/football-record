# 球历原生工程

正式名称为“球历” / `football-record`，Xcode 技术名为 `FootballRecord`。使用 Xcode 27、Swift 6，最低 iOS 17 / watchOS 10。打开 `FootballRecord.xcodeproj`，选择 `FootballRecord-iOS` 或 `FootballRecord-Watch` 共享 scheme 与对应模拟器。iPhone target 嵌入现代单目标 Watch App。

当前任务已将共享会话接入原生记录页面：Watch 为比赛/实时状态与四快记两页，iPhone 为比赛、历史、生涯、设置四标签，历史仅展示已保存事实骨架。赛后纠错、分析与路线页面留 M5。App、共享页面及测试均显式注册到实际 target，不能以文件存在替代编译。

正式入口的开赛服务在 M4 前明确不可用，保留原开赛意图供重试，不会偷偷取得模拟许可。Debug 版本可从设置或 Watch 入口新建独立开发演练，持续显示“开发模拟锁”。每个演练使用实际独立 namespace、数据库和设备 identity；这不是真实开赛锁、真实运动采集或跨设备 E2E。结束先进入 `endedPendingSync`，不会因本机保存而冒充完整完成、释放锁或立即另开一场。

## 验证与证据

在仓库根目录运行：

```sh
NATIVE_BUILD_ROOT=/tmp/football-record-check scripts/native/verify.sh
```

脚本依次执行 MatchCore / MatchStore / MatchSession 共享包宿主 XCTest、Store 与 Session 的双端最低部署 SDK 编译、MatchPresentation 宿主 XCTest及双端最低部署 SDK 编译、两个 App 无签名 Simulator 构建。任一步失败返回非零。产物和日志可用独立 `NATIVE_BUILD_ROOT` 指定；Desktop FinderInfo 影响代码签名时使用 `/tmp`，不清除源码 xattr 或他人产物。

实际 UI 验收需使用已安装 runtime 的模拟器 UDID，脚本不创建、重配或删除模拟器：

```sh
NATIVE_UI_BUILD_ROOT=/tmp/football-record-ui scripts/native/ui-test.sh Watch WATCH_SIMULATOR_UDID
NATIVE_UI_BUILD_ROOT=/tmp/football-record-ui scripts/native/ui-test.sh iOS IPHONE_SIMULATOR_UDID
```

两端 scheme 均含 XCUI target。UI 脚本实际 launch/tap/swipe、核对按钮 frame/已保存显示变化并导出 xcresult 截图与可访问性树。`ONLY_ACTIVE_ARCH=YES` 限定实际测试设备架构。测试启动参数仅在 Debug 生效，dataset、失败注入和固定测试 clock 不进入生产入口。纯宿主或 SDK 构建不替代实际 UI 启动，更不证明 HealthKit、GPS、后台或触觉手感。

基础已集成事实及证据见 [NATIVE-006](../docs/native/validation/NATIVE-006.md)、[NATIVE-007](../docs/native/validation/NATIVE-007.md) 与 [NATIVE-011](../docs/native/validation/NATIVE-011.md)。009最终组合源码 `117c4c42744a96fd5fa695671accee7a843d08df` 已通过158项宿主测试、六项最低部署SDK编译、双App构建及Watch/iPhone各七项实际XCUI；准确输入、runtime、截图及最低系统/真机限制见 [NATIVE-009](../docs/native/validation/NATIVE-009.md)。历史 M1 组合 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 的 70 项测试仅是当时证据，不是当前测试数或原生 UI 验收。

## 事实、事务和展示边界

`MatchDescriptor` 固定 matchID、recordingDeviceID 与原 `StartIntent`。不可变 `MatchEvent`、追加修订及采集 revision 是事实；`MatchReplay` 从事实与展示时间派生比分、比赛/上场双时钟及诊断，不按秒落库。暂停冻结双时钟且保留场上状态；上下场仅影响上场时长，不能冒充 Workout 暂停。四快记共享 1000ms guard，撤销仅针对最后一次快记并以追加 revision 保留审计，撤销后可立即纠正。

`LiveMatchRecorder` 只 staging。`MatchSession` 串行编排请求，`MatchStore` 用系统 SQLite WAL / synchronous=FULL 事务保存事实、采集操作、首次 receipt 与 outbox。UI 只接受已提交 snapshot/receipt，成功触觉只由首次确认 receipt 触发；失败不采纳 staging，不用旧点击快照覆盖已到达的更新。响应不明保留原完整 request 原样重试；只有明确 stale 且持久 command 查无提交，才刷新后分配新 command。

006 已实现 additive v1→v2 迁移和采集元数据落盘，保留 v1 canonical 请求、包和 receipt 兼容。`CaptureRevision` 保留同场/同设备下真实 Workout 关联和已知或未知窗口、缺口；未得到实际 Workout UUID 不造 segment。持久 `CaptureOperation` 在事务外执行/对账，未知保留 `needsReconciliation`，保存待解锁保留 `savedAwaitingLink`，不盲建第二个 Workout。011增加严格的未创建证明：同token原start持久notCreated、无正向观测/真实窗口或片段并通过完整历史校验时，才允许取消未决finish；迟到矛盾原始观测保留并阻断该证明。一般unknown仍继续对账。正常结束不制造 `completed`；完整保存凭据同时绑定当前业务事实与完整采集 digest。

没有可信 peer 时业务变更保留 `unrouted` outbox，不制造手机目标或把传输成功当持久 ACK。旧包/ACK API保留完整性校验；实际同账号认证、配对、传输和可信 ACK 来源仍待 M3。checksum 仅校验完整性。生产许可、账号、后台唯一锁与云仍待 M4。

`MatchPresentation` 直接消费已集成 `MatchSession`，只投影事实并处理保存/重试/只读状态。心率、GPS、距离和速度走独立可选内存展示通道，缺失显示“未记录/不支持”，真实零值与未知分开，不进入业务 snapshot/outbox。009 默认装配 `UnavailableWorkoutGateway`；bootstrap 保留 gateway 注入接缝供010在 Apps/工程层装配已审适配器，许可与 namespace 隔离固定，不接受外部伪许可。

## 签名与真实采集

`com.example.footballrecord` 与 `com.example.footballrecord.watchapp` 是本地开发占位 Bundle ID，尚不代表注册。009 未加 HealthKit/真实定位 entitlement，也未连接008。010将准备设备集成候选；真实采集相关实现须经对应真机验收后才进入 `dev`，不以 SDK/模拟器或 fake 代替真实授权、锁屏保存、GPS、后台和恢复证据。

用户连接配对 iPhone / Watch 后，在 Xcode 登录本人 Apple 账号、为两个 target 配置所属 Team、App ID 和签名，设备解锁并信任 Mac，按系统提示开启开发者模式。正式 Bundle ID 同时更新两 target 与 `WKCompanionAppBundleIdentifier`。账号授权、Team 归属和真机签名由用户条件决定，无签名构建不证明设备安装或付费分发资格。
