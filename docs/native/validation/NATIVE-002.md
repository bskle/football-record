# NATIVE-002 验证记录

日期：2026-10-15；作者 /root/match_engine；原始base b7729b75ff29fccb578ec204438aa37dc3ab2136，分支feat/match-event-engine。构建输入提交 e92c52f2ad13244e904201fc57ce22819c972957；后续文档不改变构建输入。源码已获 /root 质量和 /root/environment_check 规格双审 PASS，最终文档与实际集成由主代理登记。

## 实际命令与结果

工作目录为 /Users/liam/.codex/worktrees/match-event-engine/20260830_足球记录。沿用 Xcode27.0（27A266a）/ Swift6.4，Swift6模式、tools6.0，最低iOS17/watchOS10，macOS14宿主。仅系统 Foundation / CryptoKit / XCTest，无第三方依赖；原有身份与Xcode配置不变。

最终 scripts/native/verify.sh 退出0，原始日志 native/.build/logs/20261015T112011Z/。脚本依次运行共享包 swift test（scratch-path为native/.build/SwiftPM）、FootballRecord-iOS和FootballRecord-Watch共享scheme的generic Simulator构建，CODE_SIGNING_ALLOWED=NO。完整逐字命令位于脚本与日志。

XCTest运行33个独立测试方法/0失败：CommandTests9、CompletionTests7、ReplayTests17。生命周期损坏导入测试内部另有5种删除/时间颠倒输入变体，不额外计为独立测试方法；尾部Swift Testing的0 tests表示该runner无用例，不替代XCTest结果。两个SDK日志均输出 BUILD SUCCEEDED，总入口为 Native verification passed。三条App Intents元数据提取提示与工程壳相同，没有为消除提示添加能力。bash -n、git diff --cached --check通过，交付文档前另做整体diff check。

这是macOS宿主行为测试与双SDK编译，没有运行双端设备业务测试、签名、真机采集、网络、存储或分发验收。

## 持久证据

根目录：/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-002/。20261015T112011Z/为最终逐步构建日志；tdd/为各轮原始红绿与完整脚本输出。SHA256.json为27份日志清单，BUILD-INPUTS-SHA256.json为已构建源码/manifest/测试/脚本清单。证据副本不会随worktree归档删除。

| 最终日志 | SHA256 |
|---|---|
| swift-test.log | 002b3a20bc4461822ee45bedeb12a3ee40078643edae29c60e4cfd178dec3306 |
| ios-build.log | 839f4d1db26f04f1ed8509fb8b74a48178f7cdd88049d777638b2eab8030e76d |
| watch-build.log | 5cf01963325600ab67223f795b8510e0bd47693d6860622c5e4db07695feb248 |

## 红绿回归

最初缺接口的编译失败日志（red、commands-api-red、completion-api-red）单列保存，不称为断言级红阶段。下表文件均位于tdd/且有NATIVE002-前缀：

| 红日志 | 真实失败与后续绿色结果 |
|---|---|
| behavior-red.log | 可编译空回放：12测试41断言失败；实现后首组12通过 |
| edge-red.log / overflow-red.log | 异常终结被越过、同意图多时间共3断言失败；Int.max revision原实现signal5；修复后完整24通过 |
| snapshot-red.log / revision-clock-red.log | 失球球队快照1失败；改恢复/延后结束使用旧时钟2失败；修复后分别24/25通过 |
| order-red.log | 同刻enter/goal更正移过end：4断言失败；根事实顺序修复后26通过 |
| lifecycle-red.log | 6测试15失败，覆盖起止删除/颠倒与手机部分日志跨来源序号；修复后32通过 |
| no-start-red.log | 完全无start的手机异常终结抛requiresActiveMatch；nil计时和迟到恢复实现后33通过 |
| unknown-impact-red.log | 未知时长预览漏确认1失败；修复后33通过 |
| restart-red.log | 缺start异常终结后start成功且修改staging，2断言失败；最终完整脚本33通过及双SDK成功 |

最终还覆盖首发/替补、多次/重复/缺失上下场、未闭合结束、跨日暂停交集、场内外比分与同刻序列、乌龙不计个人普通进球、四快记/助攻、999ms拒绝与1000ms接受、撤销立即改正/持续/恢复/结束清除、乱序重传与编码、同ID冲突、修订分支/循环/缺父/删除、结束改早/暂停内结束/越界、状态乘实际出场生涯、正常pending/凭据/锁独立、异常终结迟到普通end。没有独立权威finalScore或scoreBaseline。

## NATIVE-003 接入契约

- MatchDescriptor固定StartIntent、matchID、recordingDeviceID、首发、许可与独立后台锁。MatchEvent是不可变Codable/Sendable事实；仓储保存所有原始版本，不能以有效事件覆盖日志。sequence在sourceDeviceID内唯一；更正用新ID、前版本ID与递增revision。根事实sequence/sourceDeviceID/eventID在同occurredAt下决定业务顺序；修订sequence保留追加审计含义。完全相同重传幂等，跨来源同序号合法，同来源异事实同序号诊断冲突。
- LiveMatchRecorder是staging值：复制、生成事实、一笔事务保存descriptor/事实/outbox、成功后替换状态再反馈。事务失败不得反馈保存成功。当前没有SQLite/outbox/ACK清理或崩溃恢复实现。
- MatchReplay.replay(descriptor:events:now:completionEvidence:)确定性纯回放；正常本地end默认endedPendingSync，不进生涯。可信完整保存/durable ACK适配器完成实际工作后才调用TrustedCompletionEvidence.acceptedByCompleteSaveBoundary。凭据绑定matchID、当前正常终结ID与去重原始全集canonical SHA256；乱序/相同重传版本不变，新增事实/修订/删除使旧证据失效。核心不验证保存或ACK真伪，后台锁确认独立。
- StartIntent先持久化；真实网络适配器验证许可后才调用TrustedStartPermit.acceptedByTrustedNetworkBoundary。DevelopmentStartFixture带developmentSimulation标记，不是真实锁证据。手机更正/异常终结授权由已认证可信应用边界提供，不改变recordingDeviceID或接管采集。
- PostMatchEditor返回待保存提议/ReplayImpact。start/end可以改时间，不可删除、颠倒或改到未来；损坏输入诊断conflict，任何已知终结阻止再次start。异常终结不可普通修订成completed。暂停平台的比赛时间映射要求明确occurredAt，不猜测。
- 手机完全缺start可保留可信异常终结：incomplete+missingStart，不造开始；matchElapsed快照仅此场景可nil；未知matchDuration/appearanceDuration/elapsed(at:)为nil，timingComplete=false。影响差值未知为nil并要求确认。迟到start/score恢复计算但仍incomplete，不改变后台或新比赛锁。
- completed且实际出场才进入出场/胜率/体能，平局进入分母；completed未出场仅计记录场次。pending/incomplete/conflict/未结束排除生涯。健康值缺失nil，不提供假0或修改HealthKit样本。

## 限制

纯业务引擎没有设备能力变更，用户暂不能连接真机，本任务真机不适用。事务中途失败、持久日志重启/迁移/损坏恢复、outbox持久化ACK属于NATIVE-003；真实锁、账号、HealthKit/Workout恢复/设备通信属于后续阶段。开发许可、保存断言工厂及SDK构建不能替代这些证据。作者未推进长期分支、push、上传或发布，也不宣称M1全部完成。
