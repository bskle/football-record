# 原生开发准备检查

当前检查日期：2026-10-19（上海；历史原检查为2026-10-14/16/18）。历史证据日期不改写。bootstrap见[NATIVE-000](native/tasks/NATIVE-000.md)，首次同步见[GIT-001](native/tasks/GIT-001.md)，M1 / M2快照见[GIT-002](native/tasks/GIT-002.md)、[GIT-003](native/tasks/GIT-003.md)，M3历史治理见[GIT-004](native/tasks/GIT-004.md)，M4责任补充见[GIT-005](native/tasks/GIT-005.md)，历史本地交付见[GIT-006](native/tasks/GIT-006.md)，当前交接见[GIT-007](native/tasks/GIT-007.md)。

截至2026-10-19，[GIT-007](native/tasks/GIT-007.md)登记 `dev=origin/dev=2642b426ee0ade276316a348537f72c0b2a1ed8a`。023执行source `5ee7bd33721a9015e23dfe23fd0e31c15fafd211`、final `f7f7a3bceb3000fd6d655d4724089601870eeb4d` 已root+m2 whole exact PASS；actual merge2642全树等于f7，root单轮591/0（Node161、Core包257=44/149/47/17、Cloud80、Account54、Presentation39）、12最低sim SDK产品和2无签名generic sim App通过并同步，原生树已归档/安全删分支。223产品输入及19份merge日志绑定本轮，094失败/27d570/早期选测保留旧层不混入。

034本机ops readiness（Node145/0）、035 Presentation测试竞争修复（39/0）、036 Watch登记闭合恢复参考后台（Node161/0）各自已双审、actual merge验证、同步、原生实际归档与safe-d，完整SHA见GIT-007；034备份点恢复不证明持续durability/RPO/epoch高水位或实际部署。024/025已正式各树推进：base17f+accepted whole023 f7，输入产品与actual2642相同；仍无final/未入dev，不计在途selected结果。024默认无真实SDK调用、候选待026，025尚待完整UI/Debug纵向和两端Debug/Release构建/UI验收，entitlements仅reserved。

008/010/016/018/028仍held，02829host/四SDK不代替真实设备；旧queued五树+017 active保留。所有真实SDK/账号/设备/签名/安装/部署、026 owned catalog组合擦除仍延后，生产Unavailable且M4未完成。此次仅七文档，不重跑产品/SDK，不操作用户设备。

结论：M1与M2的006/007/011/009/012、M3的013/014/015/017已双审集成并同步。历史已验证App组合 `b0070c90d91bf9d7741b7a7ed24165f1ad27383d`，实际merge单轮252项宿主测试（44 Core + 106 Store + 46 Session + 17 MatchSync + 39 Presentation）、8项最低SDK产品、2个无签名App及iOS / Watch各1项XCUI spot通过。当前M4模块证据见上文；本批文档合并后的实际dev/origin HEAD以Git现场为准。主线复用同一SQLite facade / Session / MatchSync，采集gateway、transport及生产trusted peer仍unavailable。017作者此前双端各9项XCUI及375pt深色最大字体1项视觉检查保留其输入层次，旧009证据不改写。历史M1的70项与M2的166项等证据仍只证明当时组合，见各任务验证卡及当前治理台账。

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
| 原生工程 | 023已actual merge2642：591/0、12最低sim SDK产品、2无签名generic sim App；历史b0070c9 App252仍独立保留 | 本机控制/同facade纵向通过不等于SDK/设备E2E；024/025在途，生产Unavailable，008/010/016/018仍held |
| Xcode / 运行环境 | Xcode 27.0（27A266a）/ Swift 6.4；上述产品组合自动验证与 iOS 27 / watchOS 27 模拟器复验通过；最低 iOS 17 / watchOS 10 已编译 | 未实际运行最低系统；无签名 SDK 构建不替代真机能力验收。历史 Desktop FinderInfo / codesign 失败及隔离重跑保留于 GIT-002 |
| 签名与 CloudKit | 仅配置本地 Bundle ID 占位，未注册；本人Team/profile/能力签名与CloudKit容器未验收 | 010可审配置/指引本机部分完成；安装/授权待本人，CloudKit留M4 |
| 唯一比赛锁后台 | 034/036已入dev，023实际merge本轮Node161；无已部署生产环境 | 034仅匹配配置/权限、备份点恢复与隔离TLS smoke；持续durability/RPO/epoch高水位、真实Apple及部署留026 |
| 私有云与业务事务 | 023同facade本机软件已双审入dev，当前merge单轮Cloud80/Account54；024 CloudKit SDK仍在独立树进行 | 真实CloudKit/iCloud与026全owned catalog+staging+Store组合清理仍待；saga/capability/028 selection继续保护 |
| 真机行为 | 本人设备协助延期；真实采集/后台/锁屏/恢复及配对同步未验 | 008/010/016/018保留，不提前入dev。WC transferFile不支持Simulator，fake/SDK/两sim UI不替代真通信 |
| Git 与远端 | 三永久分支；dev已同步2642b426ee0ade276316a348537f72c0b2a1ed8a；main/release仍59edac8原型，release尚无原生冻结候选 | 已授权public同步，PR/CI/server保护未配置；代码同步不等于发布 |

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

M3历史事实见[GIT-004](native/tasks/GIT-004.md)，当前M4交付见上文/[GIT-007](native/tasks/GIT-007.md)；NATIVE-013与009截图等保留为历史证据。[M3合同](native/contracts/m3-durable-sync.md)已由014/015实现不可变完整快照、原outbox/receipt保留、持久ACK与同Session接收桥，017呈现持久状态。M4前生产permit/trusted peer unavailable，Debug两隔离DB及稳定身份fixture持续标“开发模拟锁 / 开发配对”，只证明协议。peer ACK不等于云已同步/后台终结，不制造completed或释放锁。005/006/007/011/012/GIT-003及013/014/015已归档安全删分支；旧五树和017仍queued且实际active，分支保留不盲重试；008/010/016/018因设备验收依赖保留；019已合018、实际归档并安全删分支。

[会话采集合约](native/contracts/m2-session-capture.md)固定先保存后反馈、采集持久对账、v1→v2兼容和原outbox，012补齐恢复fail-closed与原请求重试。010本机整包已双审，真实设备项延期；017已完成共享工程装配，018在独立树串行接手Apps / 工程所有权。

| 证据层级 | 当前状态 | 通过门槛 |
|---|---|---|
| 已编译 | 该产品组合实际merge单轮252宿主/8SDK/2App；016独立21host/四最低SDK；008/010历史分层证据如上 | fake driver / SQLite不证明实际HealthKit或WC通信，分层累计不当单次总数 |
| 已模拟器 | 017实际merge两端各1UI spot；作者此前各9项XCUI及375pt视觉检查保留层次；009 / 010历史证据见各验证卡 | 最低runtime、真人VoiceOver及触觉未验；Simulator不支持WC transferFile真实通信 |
| 待真机 | 用户暂不能连机，实际签名 / 安装、授权 / 采集 / 恢复及WC真通信均未验 | 018后续逐场景绑定设备 / OS / SHA / 时间 / 结果；008/010/016/018此前不入dev |

生产开赛 provider 在 M4 前 unavailable；Debug 使用独立 DB / 专用入口并持续标注“开发模拟锁”，不能算真实锁或完整 E2E。本地普通结束保持 `endedPendingSync`，不释放后台锁、不制造 `completed`。iPhone17使用手动HKWorkoutBuilder+CoreLocation，Watch10使用live session；权限拒绝不撤销已存比赛，无样本不填0。完整赛后编辑/生涯/路线分析仍留M5，本轮不改产品范围。

## M4 可继续事项与保留门槛

023本机同facade/控制/闭合恢复已whole双审并实际合入；591/0是2642本轮，不是历史或各任务相加。024客户端AS/Keychain/CloudKit在其16路径内推进，默认SDK执行关闭，须两个模块×四triple共8项最低sim/device编译；025在39精确UI/App/工程路径内推进，独占共享工程但不得写无真实值的reserved entitlements。024/025都未final/未入dev，运行中的选测不作为完整交付。

008/010/016/018/028及024 SDK候选真实门槛前保持独立树；026仍须验真实Apple/Keychain/iCloud/CloudKit/Health/WC、签名/安装/后台与部署，并聚合完整owned ledger catalog、024 owned staging、023 Store，保护独立saga/capability/028 selection。033单文件逻辑擦除不等于组合完成；034一致备份点恢复不等于持续durability/RPO或epoch高水位保全。main/release仍原型，无原生冻结候选；用户既有推进/同步授权不新增审批。
