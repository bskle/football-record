# 原生开发准备检查

检查日期：2026-10-15（原检查为 2026-10-14）；bootstrap 事实以 [NATIVE-000](native/tasks/NATIVE-000.md) 为准。

结论：产品正常流程足够明确，可以开始原生工程与比赛事件引擎开发；当前交付物仍是浏览器原型。2026-10-15 实查 Xcode 27.0（27A266a）、Swift 6.4 可用，先前的许可阻塞已解除；尚未建立原生工程，不能声称原生构建通过。正式名称为球历 / `football-record`。

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
| 原生工程 | 当前没有 Swift、Xcode 工程、原生 entitlements 或 XCTest；已有代码是 Vanilla JS 原型 | 新建 iOS/watchOS 工程与共享事件模型属于开发工作 |
| Xcode | 2026-10-15 实查 Xcode 27.0（27A266a）/ Swift 6.4 可用；尚未建立原生工程或验证其构建 | 建立 iOS/watchOS 工程后执行原生构建与测试 |
| 签名与 CloudKit | 本项目未配置开发团队、Bundle ID、CloudKit 容器和能力权限 | 真机、Apple 登录及 CloudKit 联调前配置 |
| 唯一比赛锁后台 | 原方案定义了职责，尚无接口实现及运行环境 | 确定工程接口与供应商，开始比赛链路联调前部署 |
| 真机行为 | 用户暂不能连接真机；真实心率、GPS、后台运行、崩溃恢复和跨设备可靠同步尚未验证 | 不阻塞 M1；M2 起使用配对 iPhone / Watch 验收，签名指导随工程交付 |
| Git 与远端 | `dev/release/main`、原型 tag、文档 worktree 已建立；`origin` 已登记为 public 仓库，当前只读、`gh` 未登录，尚未推送 | 用户已明确选择 private，当前仍为 public，待仓库管理员操作并确认私有；private 状态确认且远端写权限落实前不推送。本地按授权继续 |

供应商和后续模块拆分由开发者按方案决定；M1 子计划须固定共享 SwiftPM 包与事务仓储选型；该子计划由后续工程代理在独立分支/worktree 产出。正式名称已确定为球历 / `football-record`；图标、未来付费边界、热图和 PC 路线不再次阻止开工。

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
