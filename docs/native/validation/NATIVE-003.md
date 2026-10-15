# NATIVE-003 验证与接入合同

作者 /root/transactional_store；工作分支 feat/transactional-match-store；base f2cf0786fa57f846001a8df67d1861803f4a090d。最初源码68fc13bae9c26127edf820fd9c5aad77e6295816，经双审发现的恢复边界已修于245252e075487235c27811b493f9bcf518133379。后续文档不改变构建输入；最终文档/集成头由主代理登记。

## 范围与接口

系统SQLite3与CryptoKit，无第三方。MatchStore actor独占连接，事务内同步执行、无await；核对WAL和synchronous=FULL，SQL prepare/bind/step/finalize错误抛出，事务失败rollback，显式close检查结果，析构兜底关闭。使用绑定参数与显式UTF8/Blob长度，不用SQL字符串拼接业务输入。

- `matchIDs()` 从主表发现已持久化意图/比赛。调用端重启只保留DB URL即可枚举，再读snapshot与pendingPackets；无第二份UserDefaults索引。
- 原记录端先以generation0保存无许可、无事实的StartIntent；固定matchID/recordingDeviceID/starter，intentID全库唯一。真实可信网络adapter返回permit后才生成start；接收端首次收到合法已开始包可同事务保存descriptor和完整facts，不要求本机先有意图。
- StoreCommit原子保存descriptor、新不可变facts、stable commandID/receipt和匹配的outbox。多连接以BEGIN IMMEDIATE内generation CAS防覆盖。包必须完整匹配本次descriptor/facts，不能只相信caller给的checksum。生产API不采纳内存staging；调用端只有拿到成功receipt才替换staging并反馈。
- 相同commandID必须复用第一次完整请求，包括expectedGeneration、事件顺序、包ID/key；异请求报commandConflict。查首次receipt在CAS前，但还核对当前descriptor身份、所承诺原facts、对应outbox和receipt内容仍完整；缺失/损坏报blocking诊断，不伪保存。后续permit升级与追加修订保留旧原facts，因此正常旧receipt仍可重试。
- 事件ID全局唯一，完全相同canonical bytes幂等；异payload或跨match碰撞保留原事实并隔离新bytes，事务失败、不ACK。修订/删除tombstone全部追加，乱序/修订先到/跨writer同sequence不被SQL约束丢弃，最终由MatchReplay诊断与重算。
- receive核对版本、checksum与可信adapter传入的peer/localDevice/match。事实和固定接收receipt事务落盘后才返回DurableACK；ACK丢失重传仍返回原ACK，但先核验descriptor/原facts仍存在且内容正确。receipt存在但事实缺失不假ACK。
- acknowledge精确匹配packetID/checksum/接收设备，仅标记该包并保留包与ACK；错误ACK失败、重复幂等。传输完成不是持久ACK；任意部分ACK不完成比赛。
- 被正确拒绝的JSON/version/checksum/route包保存非阻塞audit；合法事实及正确重试不被坏包污染。事实冲突、已存payload损坏、凭据对应事实缺失是blocking；StoreSnapshot.replay及保存完成凭据会拒绝未解决blocking，raw bytes保留，不静默挑赢家。
- 正常本地end仍endedPendingSync。只有可信完整保存adapter提供且匹配当前全事实集的TrustedCompletionEvidence可保存；新增修订使旧证据失效。异常终结/缺start/迟到普通end复用核心incomplete规则。本地仓储不写releaseRequested/releasedConfirmed，不释放本场或后场后台锁。

checksum不是身份认证；系统库也不验证远端同账号、设备配对、后台许可真假或手机更正权限，后续可信adapter必须完成这些工作。DevelopmentStartFixture仍显式是模拟数据。无网络、WatchConnectivity、CloudKit、HealthKit原始样本或实际UI保存入口。

## 测试与真实红绿

XCTest共62个独立方法：29仓储（TransactionTests8、RecoveryTests10、TransportTests11）与原MatchCore33；变体不额外计方法。全部仓储使用真实随机临时SQLite文件和关闭重开；不是内存仓储或mock SQL。

| 日志（tdd目录内NATIVE003前缀） | 真实红阶段 / 后续结果 |
|---|---|
| behavior-red / transaction-green | 可编译空仓储5测试因notFound失败；SQLite实现后5通过 |
| transport-red / transport-green | 6测试验证空收包/ACK未保存与无诊断失败；实现后累计11通过 |
| recovery-red / recovery-green | 尚未保存完成凭据、缺列schema未被拒绝真实失败；修复后累计18通过 |
| intent-red / intent-green | 同intentID改绑另一match被接受1失败；唯一约束后22通过（含双连接并发） |
| review-red / durable-review-red / review-complete-green | 恢复发现空结果、凭据早返而facts/outbox缺失或损坏、坏wire审计阻断合法事实；修复后29仓储+33核心通过 |
| global-id-red / review-complete-green | 跨match同eventID被保存并ACK，2断言失败；全局唯一和隔离后通过 |

api-red/first-red为target目录或编译诊断，不能算断言级红阶段。recovery-red还包含一条错误测试假设（初建空库rollback后文件必须非空）；已改为实查user_version0/schema表数0。preservation-red最初把SHM字节视为不可变，SQLite读取会改变read-mark，已纠正为核对DB/WAL原内容与SHM文件保留，不把该测试假设计为源码缺陷。

覆盖：permit前稳定意图恢复；事务事件后/outbox后/commit前三处失败全回滚、无成功receipt；commit后响应丢失关闭重开同命令幂等；双连接同generation并发仅一赢家；进球/undo/重开/原包重传不复活；接收落盘后ACK丢失重传；错误/部分/重复ACK；错peer/version/checksum/JSON；事实冲突、packetID/key碰撞、全局事件ID；修订先到和跨来源sequence；迁移故障原schema/version回滚、未知未来版本DB/WAL/SHM保留、部分schema、坏JSON/坏checksum/物理损坏；完成凭据新增revision失效、异常终结迟到normal end不升级不放锁。

## 自动构建与持久证据

最终构建输入为245252e075487235c27811b493f9bcf518133379；该源码已获/root质量、/root/environment_check规格复审PASS。2026-10-15T20:34:51Z（上海2026-10-16凌晨）执行 `NATIVE_BUILD_ROOT=/tmp/football-record-native003-reviewed scripts/native/verify.sh`，退出0。62 XCTest零失败，两个MatchStore SDK编译均Build complete，两个App均BUILD SUCCEEDED，末行为Native verification passed。环境为Xcode27.0（27A266a）/Swift6.4（Swift6模式、tools6.0），macOS arm64宿主；最低iOS17/watchOS10。脚本按顺序执行全部检查，任一步失败退出非零。App仅消费MatchCore，显式库编译确保SQLite/CryptoKit在两个SDK可编译。bash -n与git diff --check通过。

持久证据根目录：/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-003/。20261015T203451Z/含5份最终日志；tdd/保留各轮真实原始日志（含标明已纠正的编译/测试假设日志）。SHA256.json核对28份证据文件；BUILD-INPUTS-SHA256.json绑定上述源码HEAD与31份源码、测试、manifest、脚本及工程输入，不随worktree归档丢失。

最终swift-test.log SHA256为e8f8ea226c79e986d08a3f295e8f976080f3cb87b26a375ba565ff9a3c32f511；两个新库SDK日志分别为ce3298545e3ce7121d6f4e750a004a69cd4a14e9882f4ecfacf4479a6ee02471、4641c7f6d8176cc68403f0e7b8a1c8beb8190dc25e1974de8eba6a09af5ac50d；完整清单含两个App日志。未把SDK编译说成设备安装、进程崩溃或真实服务验收。

## 限制

schema仅实现未发布空库v0→v1创建，schema与user_version同事务；不虚构已发布旧schema迁移。未知未来版本/损坏不删库重建。SHM为SQLite可变锁索引，不宣称字节永恒不变。冲突阻塞后保留原始事实和隔离bytes，恢复/用户纠错界面留后续阶段，不自动清除诊断。

只有macOS宿主故障注入和SDK编译；没有模拟器业务运行、真机、进程被系统杀死/物理断电、存储压力、签名、实际网络/设备同步/账号/采集/分发证据。用户暂不能连接真机不阻止本纯仓储任务，真机采集验收仍按后续里程碑。作者不merge/push长期分支；待双审及主代理实际合并验证后清理worktree。
