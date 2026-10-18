# 原生开发准备检查

当前检查日期：2026-10-18（上海；历史原检查为2026-10-14/16）。历史证据日期不改写。bootstrap见[NATIVE-000](native/tasks/NATIVE-000.md)，首次同步见[GIT-001](native/tasks/GIT-001.md)，M1 / M2快照见[GIT-002](native/tasks/GIT-002.md)、[GIT-003](native/tasks/GIT-003.md)，当前治理见[GIT-004](native/tasks/GIT-004.md)。

M4已按用户继续无需本人协助部分的指令进入[NATIVE-020](native/tasks/NATIVE-020.md)工程规划，登记基线`dev=33c5664da5e8c6fbae78891cf15035768c6d6b56`。对应[子计划](superpowers/plans/2026-10-18-native-m4.md)/[冻结合同](native/contracts/m4-account-lock-cloud.md)先安排021真实HTTP/文件SQLite控制后台与022独立持久云台账并行，随后023唯一核心作者完成schema4、原StartIntent、签名控制、同Session云导入和双证据completion。024 SDK适配、025单工程/UI所有者和026实际环境/设备验收分层推进；本次六文档不实现M4能力，不改下列历史测试层次。

结论：M1与M2的006/007/011/009/012、M3的013/014/015/017已双审集成并同步。本次核对时的已验证产品组合 `dev=origin/dev=b0070c90d91bf9d7741b7a7ed24165f1ad27383d`，实际merge单轮252项宿主测试（44 Core + 106 Store + 46 Session + 17 MatchSync + 39 Presentation）、8项最低SDK产品、2个无签名App及iOS / Watch各1项XCUI spot通过。后续本批纯文档合并会推进实际dev/origin HEAD，以Git现场为准。主线复用同一SQLite facade / Session / MatchSync，采集gateway、transport及生产trusted peer仍unavailable。017作者此前双端各9项XCUI及375pt深色最大字体1项视觉检查保留其输入层次，旧009证据不改写。历史M1的70项与M2的166项等证据仍只证明当时组合，见各任务验证卡及当前治理台账。

008最终`6e86e8f1ac647b02b8f1ef407226a10398c5d998`已编译双审；010最终`cdbafb7822ca2371a3d1eaa6da8b95e54da78f2f`本机部分已双审，105 input / 157 evidence已核，212是历史分层累计。016最终`001f9a3bff46856fa7845c4243603f131f26f5bf`已双审，21项host fake-driver测试和iOS17/watchOS10两sim / 两device最低SDK编译通过。018从已验证b0070c9独立合入016 / 010及019测试兼容修复，source `72846583e503349d117dac84e42fde746d384fee`双审PASS，单次331host / 14最低SDK / 2无签名simApp通过；两generic设备App与两端UI按[GIT-004](native/tasks/GIT-004.md)分层登记，最终 `891000e1842f21f4a594a1d29168974debed68b9` 已源码 / 最终双审PASS，作者clean停写。用户已授权跳过本人协助项继续推进；签名、安装、HealthKit / GPS、后台 / 锁屏 / 恢复和WC真通信仍待真机，008/010/016/018保留候选，不提前入dev。Xcode27.0 / Swift6.4可用，最低iOS17/watch10不升级，原始505449规划基线见[NATIVE-013](native/tasks/NATIVE-013.md)。

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
| 原生工程 | 013/014/015/017已双审集成；当前实际merge252宿主/8SDK/2App及两端各1UI spot通过 | 主线unavailable采集/传输/生产trust；016已编译双审，018本机final已双审及331全量通过，真机门槛保留 |
| Xcode / 运行环境 | Xcode 27.0（27A266a）/ Swift 6.4；上述产品组合自动验证与 iOS 27 / watchOS 27 模拟器复验通过；最低 iOS 17 / watchOS 10 已编译 | 未实际运行最低系统；无签名 SDK 构建不替代真机能力验收。历史 Desktop FinderInfo / codesign 失败及隔离重跑保留于 GIT-002 |
| 签名与 CloudKit | 仅配置本地 Bundle ID 占位，未注册；本人Team/profile/能力签名与CloudKit容器未验收 | 010可审配置/指引本机部分完成；安装/授权待本人，CloudKit留M4 |
| 唯一比赛锁后台 | M4合同冻结严格控制DTO、设备key持有证明、原子锁/当前状态证明及生命周期；尚无软件实现和已部署环境 | 021先交Node22.23.1内置HTTP/experimental SQLite的真实本地reference authority，worker并发/丢响应/重开；026再验Serverless适配/持久配置/TLS与真实服务，不能把本地SQLite称生产部署 |
| 私有云与业务事务 | M4固定独立云queue、稳定account/cloudSpace私有zone、epoch写入fence与opaque token；尚未实现 | 022持久stage，023同业务facade事务合并facts/tombstone+token；024真实CloudKit/CKAsset、026账号/配额/冲突验收；peer ACK不代替云proof |
| 真机行为 | 本人设备协助延期；真实采集/后台/锁屏/恢复及配对同步未验 | 008/010/016/018保留，不提前入dev。WC transferFile不支持Simulator，fake/SDK/两sim UI不替代真通信 |
| Git 与远端 | 三永久分支；dev已同步b0070c90d91bf9d7741b7a7ed24165f1ad27383d；main/release仍59edac8原型，release尚无原生冻结候选 | 已授权public同步，PR/CI/server保护未配置；代码同步不等于发布 |

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

当前事实以上文/[GIT-004](native/tasks/GIT-004.md)为准；NATIVE-013与009截图等保留为历史证据。[M3合同](native/contracts/m3-durable-sync.md)已由014/015实现不可变完整快照、原outbox/receipt保留、持久ACK与同Session接收桥，017呈现持久状态。M4前生产permit/trusted peer unavailable，Debug两隔离DB及稳定身份fixture持续标“开发模拟锁 / 开发配对”，只证明协议。peer ACK不等于云已同步/后台终结，不制造completed或释放锁。005/006/007/011/012/GIT-003及013/014/015已归档安全删分支；旧五树和017仍queued且实际active，分支保留不盲重试；008/010/016/018因设备验收依赖保留；019已合018、实际归档并安全删分支。

[会话采集合约](native/contracts/m2-session-capture.md)固定先保存后反馈、采集持久对账、v1→v2兼容和原outbox，012补齐恢复fail-closed与原请求重试。010本机整包已双审，真实设备项延期；017已完成共享工程装配，018在独立树串行接手Apps / 工程所有权。

| 证据层级 | 当前状态 | 通过门槛 |
|---|---|---|
| 已编译 | 该产品组合实际merge单轮252宿主/8SDK/2App；016独立21host/四最低SDK；008/010历史分层证据如上 | fake driver / SQLite不证明实际HealthKit或WC通信，分层累计不当单次总数 |
| 已模拟器 | 017实际merge两端各1UI spot；作者此前各9项XCUI及375pt视觉检查保留层次；009 / 010历史证据见各验证卡 | 最低runtime、真人VoiceOver及触觉未验；Simulator不支持WC transferFile真实通信 |
| 待真机 | 用户暂不能连机，实际签名 / 安装、授权 / 采集 / 恢复及WC真通信均未验 | 018后续逐场景绑定设备 / OS / SHA / 时间 / 结果；008/010/016/018此前不入dev |

生产开赛 provider 在 M4 前 unavailable；Debug 使用独立 DB / 专用入口并持续标注“开发模拟锁”，不能算真实锁或完整 E2E。本地普通结束保持 `endedPendingSync`，不释放后台锁、不制造 `completed`。iPhone17使用手动HKWorkoutBuilder+CoreLocation，Watch10使用live session；权限拒绝不撤销已存比赛，无样本不填0。完整赛后编辑/生涯/路线分析仍留M5，本轮不改产品范围。

## M4 可继续事项与保留门槛

021～023必须交付实际可运行、可关闭重开和故障验证的软件，不能用空接口覆盖整个M4。旧acquire receipt与fresh live-lock状态分开，已终结锁不复活；CloudKit proof先单独持久，正常后台释放且当前完整facts/captureDigest匹配后才创建CompletionProofV2。正常/丢失七天迁移、分项删号和默认关闭的匿名分析均有明确任务及验收；auth和delete的COMMIT丢响应恢复不能依赖已撤销凭据或重建账号。

真实Apple登录/撤销、iCloud双身份、Team/签名/容器、Watch自身或手机代理联网、CloudKit保存与服务释放、两机迁移和删除分项仍待024/026实际环境。SDK编译、fake driver和本地HTTP不互相替代，也不替代008/010/016/018物理门槛。用户无需再次批准工程选择；涉及本人设备/账号步骤留清单后续集中验收，其他已授权工作继续。
