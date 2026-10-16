# 原生开发准备检查

当前检查日期：2026-10-16（上海；原检查为 2026-10-14）。历史证据日期不改写。bootstrap 见 [NATIVE-000](native/tasks/NATIVE-000.md)，首次同步见 [GIT-001](native/tasks/GIT-001.md)，M1 快照见 [GIT-002](native/tasks/GIT-002.md)，当前治理见 [GIT-003](native/tasks/GIT-003.md)。

结论：M1本地基础与M2的006/007/011/009/012均已双审集成。本次登记`dev=origin/dev=505449279d6461436a051b5e6bc43324d805e3e0`，实际merge通过166项宿主测试（44 Core + 64 Store + 36 Session + 22 Presentation）、6项最低SDK产品和2个无签名App，含012恢复只读/原请求重试修复。009既有双端完整7项XCUI与视觉证据保留，主线仍用`UnavailableWorkoutGateway`。历史M1组合`f94c915f5d2486ba1ff54471de9de98bc7fdc4d0`的70项测试及四项构建是当时证据，见[工程](native/validation/NATIVE-001.md)、[事件引擎](native/validation/NATIVE-002.md)、[仓储](native/validation/NATIVE-003.md)、[采集合同](native/validation/NATIVE-004.md)。

008最终`6e86e8f1ac647b02b8f1ef407226a10398c5d998`已编译双审；010最终`cdbafb7822ca2371a3d1eaa6da8b95e54da78f2f`（source `834cac5`）本机可完成部分已双审，105 input / 157 evidence已核。212是旧Core/Workout184 + 当前Presentation22/Integration6分层累计，不是一次全212；两sim/两device SDK无签名App与两端各3项UI通过。签名、安装、HealthKit、GPS、后台、锁屏和恢复仍待真机，008/010未入dev。用户明确“先跳过需要我协助部分，往下推，后续再做相关测试”；按[M3子计划](superpowers/plans/2026-10-16-native-m3.md)推进无设备工作，013仍为规划，014—018尚未创建，016/018真机门槛延期保留。当前规划快照见[NATIVE-013](native/tasks/NATIVE-013.md)。Xcode27.0 / Swift6.4可用；最低iOS17/watch10不升级。

## 开发依据

- 以 `docs/0-产品方案.md` 为主，后续用户明确修改优先于旧版交互描述。
- 首版为 iPhone + Apple Watch；Swift 6、SwiftUI；最低 iOS 17、watchOS 10。
- 首版免费，不加入广告、订阅、静止五分钟自动暂停。
- 比赛状态与上下场状态独立；暂停冻结比赛计时与上场计时，恢复后保持原上场状态。
- 下场时比赛继续运行，健康数据不因下场停止。
- 手表第一页合并比赛主页与实时数据，两个操作位为上下场、比赛控制。
- 快速记录使用四个按钮：我进球、我助攻、进球、失球；单击记录、支持撤销；乌龙类型保留在赛后编辑或补录。
- iPhone 支持完整赛后时间线编辑，包括修正真实比赛结束时间；修正后重算比赛及出场时长，不能只改显示文本。
- 联系作者使用已提供的 QQ 群二维码和 `japdie19450815@qq.com`。
- 一场比赛只有一个事件写入设备；手机与手表可以共享业务逻辑，界面相似不代表允许两个设备同时写入。
- 开始比赛按方案必须联网获取唯一锁；比赛中及结束可离线，待同步和锁释放按原方案处理。

## 异常场景规则

| 场景 | 规则 | 状态与影响 |
|---|---|---|
| 结束时间改早，已有事件落在结束之后 | 保留原始事件，标记超出有效范围，保存前展示影响；不计入本场统计，允许继续纠正事件；未闭合出场按新结束时间闭合；保留原始 HealthKit 数据 | 正常流程可以先开发，时间纠错实现时补齐验证 |
| 原记录 Watch 永久损坏或丢失，无法结束活动比赛 | 手机可标记异常结束，保留已有数据，明确标记不完整；后台确认后原子释放该场锁；不接管继续采集、不更换 recordingDeviceID、不伪装正常完成 | 2026-10-14 用户已确认，已写入产品方案 0.10.3；无需再次确认 |

编辑比赛时间只改变 App 中的比赛事实与统计范围，不自动改写 Apple 健康中的原始 Workout。

异常结束在本地持久化后仍可处于待同步状态，不能据此直接释放后台锁。原设备恢复和迟到上传保留在原比赛，不自动恢复为进行中或正常完成，也不影响后续新比赛的锁。

## 工程前置

| 项目 | 检查结果 | 处理阶段 |
|---|---|---|
| 原生工程 | 006/007/011/009/012已双审集成，当前实际merge166宿主/6SDK/2App通过 | 主线unavailable采集gateway；014/015纯同步、017状态UI先行，真实采集/传输留设备包 |
| Xcode / 运行环境 | Xcode 27.0（27A266a）/ Swift 6.4；上述产品组合自动验证与 iOS 27 / watchOS 27 模拟器复验通过；最低 iOS 17 / watchOS 10 已编译 | 未实际运行最低系统；无签名 SDK 构建不替代真机能力验收。历史 Desktop FinderInfo / codesign 失败及隔离重跑保留于 GIT-002 |
| 签名与 CloudKit | 仅配置本地 Bundle ID 占位，未注册；本人Team/profile/能力签名与CloudKit容器未验收 | 010可审配置/指引本机部分完成；安装/授权待本人，CloudKit留M4 |
| 唯一比赛锁后台 | 原方案定义了职责，尚无接口实现及运行环境 | 确定工程接口与供应商，开始比赛链路联调前部署 |
| 真机行为 | 本人设备协助延期；真实采集/后台/锁屏/恢复及配对同步未验 | 008/010保留待真机；016/018同样不提前入dev。WC transferFile不支持Simulator，fake/SDK/两sim UI不替代真通信 |
| Git 与远端 | 三永久分支；dev同步505449279d6461436a051b5e6bc43324d805e3e0；main/release原型基线，无原生候选；PUBLIC/ADMIN已核 | 已授权同步，PR/CI/server保护未配置；双审及实际merge复验继续，代码同步不等于发布 |

供应商和后续模块拆分由开发者按方案决定；[NATIVE-001 子计划](superpowers/plans/2026-10-15-native-foundation.md) 已固定单个共享 SwiftPM 包的工程边界，NATIVE-003 已实现系统 SQLite 事务库并完成故障与重开测试。系统杀进程、物理断电和真机存储压力尚未实测。正式名称已确定为球历 / `football-record`；图标、未来付费边界、热图和 PC 路线不再次阻止开工。

## 首批验证

1. 比赛事件先持久化再反馈，暂停/继续与上下场独立计时。
2. 比赛结束时间修正覆盖暂停区间、跨日、未闭合上场以及超出范围事件。
3. Watch 真实 Workout 能在后台采集，崩溃后恢复；拒绝权限时业务记录仍可用、健康数据标为未记录。
4. Watch 与 iPhone 的持久化确认、重试和去重，不丢事件、不产生重复进球。
5. 开始比赛锁、离线结束、重新联网释放锁与 CloudKit 私有同步。
6. 手机异常结束、离线待同步、重复请求和原 Watch 迟到数据的处理，不接管采集、不重新激活旧比赛、不影响新比赛锁。

官方实现依据：

- [HealthKit Workout 与后台运行](https://developer.apple.com/documentation/healthkit/running-workout-sessions)
- [Workout 恢复](https://developer.apple.com/documentation/healthkit/hkhealthstore/recoveractiveworkoutsession(completion:))
- [WatchConnectivity 官方真机示例](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
- [CloudKit 配置](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app)

## M2 历史证据与当前 M3 执行边界

当前事实以上文/NATIVE-013为准；009截图等保留为历史组合证据。[M3合同](native/contracts/m3-durable-sync.md)固定不可变完整快照、原outbox/receipt保留、持久ACK与同Session接收桥。M4前生产permit/trusted peer unavailable，Debug两隔离DB及稳定身份fixture持续标“开发模拟锁 / 开发配对”，只证明协议。peer ACK不等于云已同步/后台终结，不制造completed或释放锁。005/006/007/011/012/GIT-003已归档安全删分支；002/003/004/GIT-002/009共五旧树queued且实际active，保留不盲重试；008/010有设备依赖保留。

[会话采集合约](native/contracts/m2-session-capture.md)固定先保存后反馈、采集持久对账、v1→v2兼容和单机未路由outbox，012补齐恢复fail-closed与原请求重试。010本机整包已双审，真实设备项延期保留；未来017/018串行接手Apps/工程所有权。

| 证据层级 | 当前状态 | 通过门槛 |
|---|---|---|
| 已编译 | 当前dev实际merge166宿主/6SDK/2App；008/010分层自动证据如上，010两sim/两device SDK App通过 | fake driver / SQLite不证明实际HealthKit；分层累计不当单次总数 |
| 已模拟器 | 009历史双端各7项XCUI与视觉见[009验证](native/validation/NATIVE-009.md)；010当前两端各3UI通过 | 最低runtime、真人VoiceOver及触觉未验；Simulator不支持WC transferFile真实通信 |
| 待真机 | 用户暂不能连机，真实授权/后台/采集/恢复均未验 | 010逐场景设备/OS/SHA/时间/结果；此前008/010设备实现不入dev |

生产开赛 provider 在 M4 前 unavailable；Debug 使用独立 DB / 专用入口并持续标注“开发模拟锁”，不能算真实锁或完整 E2E。本地普通结束保持 `endedPendingSync`，不释放后台锁、不制造 `completed`。iPhone17使用手动HKWorkoutBuilder+CoreLocation，Watch10使用live session；权限拒绝不撤销已存比赛，无样本不填0。完整赛后编辑/生涯/路线分析仍留M5，本轮不改产品范围。
