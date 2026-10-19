# 球历原生工程

正式名称为“球历” / `football-record`，Xcode 技术名为 `FootballRecord`。使用 Xcode 27、Swift 6，最低 iOS 17 / watchOS 10。打开 `FootballRecord.xcodeproj`，选择 `FootballRecord-iOS` 或 `FootballRecord-Watch` 共享 scheme 与对应模拟器。iPhone target 嵌入现代单目标 Watch App。

当前任务已将共享会话接入原生记录页面：Watch 为比赛/实时状态与四快记两页，iPhone 为比赛、历史、生涯、设置四标签，历史仅展示已保存事实骨架。赛后纠错、分析与路线页面留 M5。App、共享页面及测试均显式注册到实际 target，不能以文件存在替代编译。

当前026临时集成候选保留025的账号入口、明确重载与独立Debug演练；默认生产许可、采集、传输和可信配对仍 unavailable，不实例化018旧 `AppAssembly` 的真实SDK资源。018/037的采集、设备同步和恢复桥作为已审依赖保留，须经026同门装配后才接入；本次依赖合并不表示整包已通过。结束先进入 `endedPendingSync`，只有当前完整云证明与原正常释放均确认才可 completed；peer ACK不能替代任何一项。

## 验证与证据

在仓库根目录运行：

```sh
NATIVE_BUILD_ROOT=/tmp/football-record-check scripts/native/verify.sh
```

脚本组合现有 Node reference authority、Core共享包、CloudSync、AccountKit、MatchPresentation及候选 WorkoutCapture / DeviceSync / AppIntegration 的宿主回归与最低SDK构建，并编译两个无签名Simulator App。026后续按实际依赖继续补齐矩阵；脚本命令清单不代表本轮已执行或通过。任一步失败返回非零。产物和日志可用独立 `NATIVE_BUILD_ROOT` 指定；Desktop FinderInfo 影响代码签名时使用 `/tmp`，不清除源码 xattr 或他人产物。

实际 UI 验收需使用已安装 runtime 的模拟器 UDID，脚本不创建、重配或删除模拟器：

```sh
NATIVE_UI_BUILD_ROOT=/tmp/football-record-ui scripts/native/ui-test.sh Watch WATCH_SIMULATOR_UDID
NATIVE_UI_BUILD_ROOT=/tmp/football-record-ui scripts/native/ui-test.sh iOS IPHONE_SIMULATOR_UDID
```

两端 scheme 均含 XCUI target。UI 脚本实际 launch/tap/swipe、核对按钮 frame/已保存显示变化并导出 xcresult 截图与可访问性树。`ONLY_ACTIVE_ARCH=YES`限定测试设备架构。当前保留025的无签名UI命令、Mac监督fixture、绝对时间与实际安装容器/私有pin核验。历史010的HKSource/ad-hoc结果保留原输入层次；旧 `NativeIntegrationUITests` 属018设备候选，尚未完成本次账号装配复验，不能当当前入口验收。测试启动参数仅在 Debug 生效，dataset、失败注入和固定测试 clock 不进入生产入口。纯宿主或 SDK 构建不替代实际 UI 启动，更不证明 HealthKit、GPS、后台或触觉手感。

基础已集成事实及证据见 [NATIVE-006](../docs/native/validation/NATIVE-006.md)、[NATIVE-007](../docs/native/validation/NATIVE-007.md) 与 [NATIVE-011](../docs/native/validation/NATIVE-011.md)。009基线的158宿主、六SDK、双App及两端七XCUI证据见[NATIVE-009](../docs/native/validation/NATIVE-009.md)。010候选4a90组合已执行204宿主、十SDK、双sim/双generic实际设备SDK无签名构建；最终同步source834包含已审012修复；本轮Presentation22+Integration6，未变化184项沿用旧源，累计覆盖212而非单轮全跑。两端App及实际交互的精确来源见[NATIVE-010](../docs/native/validation/NATIVE-010.md)。历史 M1 组合 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 的 70 项测试仅是当时证据，不是当前测试数或原生 UI 验收。

## 事实、事务和展示边界

`MatchDescriptor` 固定 matchID、recordingDeviceID 与原 `StartIntent`。不可变 `MatchEvent`、追加修订及采集 revision 是事实；`MatchReplay` 从事实与展示时间派生比分、比赛/上场双时钟及诊断，不按秒落库。暂停冻结双时钟且保留场上状态；上下场仅影响上场时长，不能冒充 Workout 暂停。四快记共享 1000ms guard，撤销仅针对最后一次快记并以追加 revision 保留审计，撤销后可立即纠正。

`LiveMatchRecorder` 只 staging。`MatchSession` 串行编排请求，`MatchStore` 用系统 SQLite WAL / synchronous=FULL 事务保存事实、采集操作、首次 receipt 与 outbox。UI 只接受已提交 snapshot/receipt，成功触觉只由首次确认 receipt 触发；失败不采纳 staging，不用旧点击快照覆盖已到达的更新。响应不明保留原完整 request 原样重试；只有明确 stale 且持久 command 查无提交，才刷新后分配新 command。

006 已实现 additive v1→v2 迁移和采集元数据落盘，保留 v1 canonical 请求、包和 receipt 兼容。`CaptureRevision` 保留同场/同设备下真实 Workout 关联和已知或未知窗口、缺口；未得到实际 Workout UUID 不造 segment。持久 `CaptureOperation` 在事务外执行/对账，未知保留 `needsReconciliation`，保存待解锁保留 `savedAwaitingLink`，不盲建第二个 Workout。011增加严格的未创建证明：同token原start持久notCreated、无正向观测/真实窗口或片段并通过完整历史校验时，才允许取消未决finish；迟到矛盾原始观测保留并阻断该证明。一般unknown仍继续对账。正常结束不制造 `completed`；完整保存凭据同时绑定当前业务事实与完整采集 digest。

没有可信 peer 时业务变更保留 `unrouted` outbox，不制造手机目标或把传输成功当持久 ACK。旧包/ACK API保留完整性校验；实际同账号认证、配对、传输和可信 ACK 来源仍待 M3。checksum 仅校验完整性。生产许可、账号、后台唯一锁与云仍待 M4。

`MatchPresentation` 直接消费已集成 `MatchSession`，只投影事实并处理保存/重试/只读状态。心率、GPS、距离和速度走独立可选内存展示通道，缺失显示“未记录/不支持”，真实零值与未知分开，不进入业务 snapshot/outbox。010仅在App层接入已审WorkoutCapture：每App生命周期同一个metrics channel/factory/gateway，其历史设备候选使用真实gateway；当前026默认入口不创建该factory/gateway，生产许可仍由Bootstrap固定unavailable。UI-only装配始终Unavailable，不静默降级真实模式。恢复信号在初始化/命令busy期间排队，并回到同model/MatchSession；没有直接驱动第二次Workout开始。许可及namespace隔离固定，不接受外部伪许可。

## 签名与真实采集

`com.example.footballrecord` 与 `com.example.footballrecord.watchapp` 是本地开发占位 Bundle ID，尚不代表注册。018依赖保留010原有HealthKit entitlement文件和Info用途/后台声明原bytes；本轮 `project.pbxproj` 不绑定这些entitlement，也不启用HealthKit/BackgroundModes capability，不表示权限已获或真实SDK已配置。无签名generic实际设备构建可运行`scripts/native/verify-device-candidate.sh`，产物Info及配置entitlement检查不等于真实签名entitlement/profile或安装。本026候选在真实门槛前不入dev/release/main；依赖文件存在不代表签名或能力验收。操作步骤、固定真实数据集、结束仍held不能另开场、免费普通能力支持与全部物理pending矩阵见[设备准备](../docs/native/device-setup.md)。

用户连接配对 iPhone / Watch 后，在 Xcode 登录本人 Apple 账号、为两个 target 配置所属 Team、App ID 和签名，设备解锁并信任 Mac，按系统提示开启开发者模式。正式 Bundle ID 同时更新两 target 与 `WKCompanionAppBundleIdentifier`。账号授权、Team 归属和真机签名由用户条件决定，无签名构建不证明设备安装或付费分发资格。


## M3 同步状态（NATIVE-017）

默认 App 使用同一个 SQLiteSessionRepository facade 创建 MatchSession 与 MatchSyncService。生产信任、传输和采集仍为 unavailable，开赛许可仍不可用。AppBootstrap.composition 返回同一 repository/session/sync/model，供独立集成模块注入适配器；生产模式忽略注入的开发 trust，不绕过 M4 开赛许可。替换装配前必须 await 旧 model.shutdown()。

记录页面区分本机已保存、待传/等待对端持久确认、对端已保存、同步错误、云未接通、后台待终结。读库错误清除旧的成功结论与计数；ACK 不增加记录反馈、不释放后台锁、不把 endedPendingSync 改为 completed。同步重试不改业务时钟、事件或持久退避预算。

Debug UI 参数 `--ui-scenario sync-pending|sync-retry|sync-saved|sync-terminal` 使用两个实际隔离的本机 SQLite 和稳定 identity 文件；`--ui-dataset` 相同则重开同一组。持续显示开发模拟锁/开发配对；这是本机 fake transport 协议演练，不能证明真实 WatchConnectivity 通信。原 `other-device` 是同库只读观察情景，不能作为双库证据。

UI 验证仍使用实际已存在 simulator UDID；可通过 `NATIVE_UI_TEST_FILTER=FootballRecord-iOS-UITests/NativeRecordingUITests/testPersistentSyncPendingRetryAndPeerSaved`（Watch 对应 target）执行定点复验。最低 iOS17/watchOS10 仅编译，当前 iOS27/watchOS27 模拟器不替代最低系统运行、真人 VoiceOver、触觉或真机验收。

## M4 账号与生命周期界面（NATIVE-025）

默认账号入口保持服务尚未接通。`AppBootstrap.accountContext` 的账号、生命周期、录制模型共用原 facade 与具体 Session；生产不接受开发配置替换 provider。Phone 设置提供账号、迁移、四组删除与默认关闭的统计；Watch 显示紧凑登记状态。删除结果独立展示后台与 Apple 撤销、CloudKit、本地数据和本 App 健康运动；本地一项必须包含 Store 和已登记 transport。重开后查询原 saga / 原 scope，不能重新拼出删除范围。

Debug 的本机纵向测试必须由 Mac 监督已审 Node HTTP fixture；App 只读取私有配置并使用公开 auth、Watch submit/recover、原 Session 和受控文件云台账。配置与凭据不进入发布资源、日志、URL 或业务数据库。每次监督进程使用新独立 dataset；同进程内重开复用持久身份、原请求与固定 receipt pin。原 key 丢失但已有记录时拒绝重建。监督进程死亡时不换 pin 复用旧数据。

```sh
NATIVE_M4_UI=1 NATIVE_UI_TEST_FILTER=FootballRecord-iOS-UITests/NativeAccountLifecycleUITests \
  NATIVE_UI_BUILD_ROOT=/tmp/football-record-m4-ui \
  scripts/native/ui-test.sh iOS IPHONE_SIMULATOR_UDID
NATIVE_M4_UI=1 NATIVE_M4_PHONE_DEVICE=IPHONE_SIMULATOR_UDID \
  NATIVE_UI_TEST_FILTER=FootballRecord-Watch-UITests/NativeAccountLifecycleUITests \
  NATIVE_UI_BUILD_ROOT=/tmp/football-record-m4-ui \
  scripts/native/ui-test.sh Watch WATCH_SIMULATOR_UDID
```

Watch 演练由 Mac 私有邮箱转交到真正的 Phone AccountKit 登记服务，非真实 WC。开发账号、配对、模拟锁与开发云标识持续可见。文件云保存回读只证明已登记演练范围；Health 删除 unavailable、未登记其他安装 / ledger / staging 不算全设备完成。正常结束先保留 endedPendingSync，当前完整云 proof 与后台原正常释放均确认后才 completed；peer ACK 不替代任一 proof。异常释放显示不完整，后续新开赛仍经 Session 的 fresh authority 检查。

配置字段及真实门槛见 [M4 capability handoff](Configuration/M4-capability-handoff.md)。最低 iOS17 / watchOS10 仍仅编译；实际 Apple / CloudKit / 签名、本人设备、后台、真人 VoiceOver 和触觉由026继续验收。


### M3 临时设备整包（历史候选源码保留）

NATIVE-018 在独立候选树将真实 WorkoutCapture / DeviceSync 与同一个 SQLiteSessionRepository、MatchSession、MatchSyncService 装配。每次切换环境都先停止旧 model、事件监听和指标监听，再关闭 facade、释放旧上下文；不缓存已 shutdown 的 model。设备验收安全扫描复用活动 facade；离线扫描只短开短关。

018历史Debug真实设备入口显示本机持久 UUID；当前账号入口尚未启用该旧路径。双方显式配对配置使用 `--sync-peer-config` JSON，详见 `docs/native/device-setup.md`。未配置、身份或配置变化、WC 配对失效均停止可信传输，本机合法记录仍可保存。传输初始化异常保留原文件并降级 unavailable。生产 trust/start permit 仍 unavailable；开发 account/pair/epoch 不是 Apple 登录。Simulator 上的受控驱动和协议演练不证明真实 WatchConnectivity；真实签名、授权和户外采集继续延期。
