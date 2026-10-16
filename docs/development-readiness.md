# 原生开发准备检查

当前检查日期：2026-10-16（上海；原检查为 2026-10-14）。历史证据日期不改写。bootstrap 见 [NATIVE-000](native/tasks/NATIVE-000.md)，首次同步见 [GIT-001](native/tasks/GIT-001.md)，M1 快照见 [GIT-002](native/tasks/GIT-002.md)，当前治理见 [GIT-003](native/tasks/GIT-003.md)。

结论：M1 本地基础与 M2 的采集事务（006）、共享会话（007）、未创建采集收尾修复（011）、双端记录 UI（009）已双审集成。登记时核对 `dev=origin/dev=2e1f9c42f4398a50b66765a0f37f90ced95a7554`，该已验证产品组合的实际 merge 复验为 44 Core + 64 Store + 36 Session + 14 Presentation = 158 项宿主测试、6 项 SDK 产品编译、2 个 App 无签名构建及每端 1 项 XCUI 通过。App 已接入 Core / Store / Session / Presentation 的记录页面，009 使用 `UnavailableWorkoutGateway`；浏览器原型保留。历史 M1 组合 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 的 70 项测试及四项构建仍是当时证据，见 [工程](native/validation/NATIVE-001.md)、[事件引擎](native/validation/NATIVE-002.md)、[仓储](native/validation/NATIVE-003.md)、[采集合同](native/validation/NATIVE-004.md)。

008 真实适配已编译、最终双审通过并保留任务分支；010 正在独立临时树准备真实 gateway / 能力配置 / 操作指引。用户暂不能连接真机，相关签名、安装、HealthKit、GPS、后台、锁屏和恢复均未验收，008 / 010 尚未入 `dev`。执行顺序与设备门槛见 [M2 子计划](superpowers/plans/2026-10-16-native-m2.md)。2026-10-15 实查 Xcode 27.0（27A266a）/ Swift 6.4 可用；正式名称为球历 / `football-record`。

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
| 原生工程 | 006 / 007 / 011 / 009 已双审合入当前 `dev`；158 项宿主测试、6 项 SDK 产品、2 个 App 及两端各 1 项 XCUI 实际合并复验通过，已有原生记录入口 | 009 尚用 unavailable 采集 gateway；008 / 010 真机采集门槛保留，M3 接实际设备传输 |
| Xcode / 运行环境 | Xcode 27.0（27A266a）/ Swift 6.4；上述产品组合自动验证与 iOS 27 / watchOS 27 模拟器复验通过；最低 iOS 17 / watchOS 10 已编译 | 未实际运行最低系统；无签名 SDK 构建不替代真机能力验收。历史 Desktop FinderInfo / codesign 失败及隔离重跑保留于 GIT-002 |
| 签名与 CloudKit | 仅配置 `com.example.footballrecord` / `.watchapp` 本地 Bundle ID 占位，未注册；本人 Team / profile / 实际能力签名与 CloudKit 容器均未验收 | 010 正在独立树准备最小 HealthKit / 定位 / 后台配置及具体指引，不能据此宣称签名或安装通过；CloudKit 留 M4 |
| 唯一比赛锁后台 | 原方案定义了职责，尚无接口实现及运行环境 | 确定工程接口与供应商，开始比赛链路联调前部署 |
| 真机行为 | 用户暂不能连接真机；真实心率、GPS、后台 / 锁屏、崩溃恢复和跨设备可靠同步尚未验证 | 006 / 007 / 011 / 009 已完成适用自动 / 模拟器验证；008 已编译双审留分支，010 最终包尚在准备，相关配对 iPhone / Watch 实测通过后才入 dev |
| Git 与远端 | 三条长期分支与原型 tag 已同步；登记时远端 `dev` 已核对为 M2 记录 UI 实际合并 `2e1f9c42f4398a50b66765a0f37f90ced95a7554`，`main` / `release` 仍为原型基线，默认分支为 `main`；`PUBLIC` / `ADMIN` 已核对 | 继续按任务双审及实际合并验证推进；旧 private 意向已被覆盖。代码同步不等于原生分发，PR、CI 与服务端保护规则尚未配置 |

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

## M2 当前执行边界（GIT-003）

[会话采集合约](native/contracts/m2-session-capture.md) 固定先保存后反馈、采集持久操作对账、v1→v2兼容和单机未路由outbox；不能以随机peer绕过M1包约束。006 / 007 已合并验证，008 / 009 按冻结接口并行完成适用交付；011 的严格未创建证明修复已集成。009 现已合并并把 Apps / 工程所有权串行交给 010，010 仍在独立树准备设备包。

| 证据层级 | 当前状态 | 通过门槛 |
|---|---|---|
| 已编译 | 已验证产品组合：158 宿主测试、6 SDK、2 App；008：40 模块 + 144 核心宿主测试及两端模拟器 / 设备 SDK 编译，最终双审通过 | 008 证据仅 fake driver + 真实 SQLite 跨层，无实际 HealthKit；010 最终整包仍在准备 |
| 已模拟器 | 009：390pt iOS 27 与 45mm watchOS 27 各完整 7 项 XCUI，另有 375pt 深色最大字体定点视觉；实际 merge 每端 1 项 XCUI 复验 | 记录于 [009 验证](native/validation/NATIVE-009.md)；最低系统 runtime、真人 VoiceOver 朗读及触觉手感未验 |
| 待真机 | 用户暂不能连机，真实授权/后台/采集/恢复均未验 | 010逐场景设备/OS/SHA/时间/结果；此前008/010设备实现不入dev |

生产开赛 provider 在 M4 前 unavailable；Debug 使用独立 DB / 专用入口并持续标注“开发模拟锁”，不能算真实锁或完整 E2E。本地普通结束保持 `endedPendingSync`，不释放后台锁、不制造 `completed`。iPhone17使用手动HKWorkoutBuilder+CoreLocation，Watch10使用live session；权限拒绝不撤销已存比赛，无样本不填0。完整赛后编辑/生涯/路线分析仍留M5，本轮不改产品范围。
