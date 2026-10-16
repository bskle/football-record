# M2 会话、采集与事务合同

状态：NATIVE-005 已双审合入；006期间 lookup 与正交 failure 补充已由 `/root` 和 `/root/m2_review` 确认；类型是006/007的实现目标，不声称源码已存在。006完成仓储、007完成服务后，以实际可编译接口冻结为008/009共同依赖；变更由主代理先审，不从未提交工作树接线。范围见[M2计划](../../superpowers/plans/2026-10-16-native-m2.md)。

## 1. 既有事实与兼容性

M1已有 `CaptureBinding(matchID:recordingDeviceID:)`、CaptureWindow、CaptureSegment、CaptureGap、CaptureMetadata；后四者不保存健康样本。CaptureSegment.workoutID必须来自真实Workout，不能以随机ID或live session token充当。尚未取得真实UUID时只持久操作/观测状态，不造segment。多个真实Workout可归属原binding，未知窗口保持nil，片段/缺口不改变比赛clock。

现有MatchDescriptor固定StartIntent/matchID/recordingDeviceID；LiveMatchRecorder只产生staging。旧StoreCommit非空events必须带真实非空、不同来源的目标packet。M2增加版本化事务入口来支持未路由outbox，不放宽旧包路由验证、不伪造peer。

006先验证完整旧schema，在同一BEGIN IMMEDIATE事务内新增v2表和user_version，不重建/重编码旧blob；v0先按既有规则初始化再到v2，损坏/部分/未来schema显式失败并留原库。旧命令hash仍是sortedKeys JSON(StoreCommit)；旧空新字段必须省略或独立v2类型。旧packet v1 checksum、receipt查重先于generation CAS、原facts/packet/ACK字节复核保持不变；新records需同等级复核。保留afterEvents/afterOutbox/beforeCommit/afterCommit/migrationAfterSchema故障点，并扩充采集写入失败点。

## 2. 006 值类型与仓储接口

以下字段均为public只读值，需public校验构造器及校验Codable decoder；Int64不溢出，Date须finite，标识去空白后非空。Core类型在MatchCore，事务/receipt在MatchStore。

| 类型 | 必须字段 / 状态 |
|---|---|
| CaptureRevision | `id: String, binding: CaptureBinding, parentID: String?, revision: Int64, observedAt: Date, metadata: CaptureMetadata` |
| CaptureAction | `start, pause, resume, finish, recover` |
| CaptureOperation | `id: String, binding: CaptureBinding, associatedCommandID: String, action: CaptureAction, requestedAt: Date, externalToken: String`；token为该实际Workout片段首次start的稳定operationID，同一原session恢复和该片段后续动作沿用；确认恢复失败后新片段使用新start operationID/token，用作HealthKit metadata对账键，不是假Workout UUID |
| CaptureOperationState | `pending, needsReconciliation, settled, failed, cancelled` |
| CaptureOperationRecord | `operation: CaptureOperation, state: CaptureOperationState, observation: WorkoutObservation?`；请求不可改写，状态经CAS转换，观测仅含下述非健康信息 |
| CaptureOperationUpdate | `operationID: String, expectedState: CaptureOperationState, state: CaptureOperationState, observation: WorkoutObservation?` |
| BusinessDeltaV2 | `descriptor: MatchDescriptor, events: [MatchEvent], captureRevisions: [CaptureRevision]`；只业务事实/非健康关联，不含本机可执行操作及健康数值 |
| BusinessOutboxItem | `id: String, matchID: String, sourceDeviceID: String, payload: BusinessDeltaV2`；稳定canonical v2 bytes/digest，路由状态持久化，初态unrouted，不能凭传输成功视为ACK |
| StoreCommitV2 | `commandID: String, expectedGeneration: Int64, descriptor: MatchDescriptor, events: [MatchEvent], captureRevisions: [CaptureRevision], newCaptureOperations: [CaptureOperation], captureOperationUpdates: [CaptureOperationUpdate], businessOutbox: [BusinessOutboxItem]` |
| CommitReceiptV2 | `commandID: String, matchID: String, generation: Int64, eventIDs: [String], captureRevisionIDs: [String], operationIDs: [String], businessOutboxIDs: [String]`；首次COMMIT结果稳定保存 |
| CommittedCommandV2 | `request: StoreCommitV2, receipt: CommitReceiptV2`；返回保存的完整 canonical 请求与首次 receipt，命中损坏不能当 nil |
| StoreSnapshotV2 | `business: StoreSnapshot, captureRevisions: [CaptureRevision], captureOperations: [CaptureOperationRecord]`；business中的completionEvidence必须已按采集digest筛选，调用replay不能绕过失效检查 |

```swift
// 新增的公开入口；旧v1入口继续可读写/重试，不改其canonical语义。
public func committedCommandV2(commandID: String) throws -> CommittedCommandV2?
public func commitV2(_ request: StoreCommitV2) throws -> CommitReceiptV2
public func snapshotV2(matchID: String) throws -> StoreSnapshotV2
public func pendingCaptureOperations(matchID: String) throws -> [CaptureOperationRecord]
public func pendingBusinessOutbox(matchID: String) throws -> [BusinessOutboxItem]
public func saveCompletionProofV2(evidence: TrustedCompletionEvidence, captureDigest: String,
                                  expectedGeneration: Int64, now: Date) throws
// matchIDs() / snapshot() / commit() / receive() / acknowledge() 仍保留。
```

- 全局稳定ID命名空间涵盖revision/segment/gap/operation/outbox；同ID同canonical幂等，不同payload保留原行及新原bytes诊断失败，跨match碰撞同样拒绝。不得按ID覆盖事实。
- revision根为1/parentID=nil；其后只能引用同binding现有唯一head、revision=parent+1。metadata是全值快照且binding相同，不把缺口“补成”虚假连续采集。孤儿/分叉保留原bytes并标blocking；不挑最后写入者。真实修复通过追加可审事实，不静默清诊断。
- 一次事务保存descriptor、events、captureRevisions、operations/状态、command receipt和所有对应业务outbox。新增facts/revision必须被相同事务的delta完整覆盖；操作ledger是本机执行意图，不让peer收到后执行。纯操作状态变化不伪造业务event。
- `committedCommandV2` 不写入或执行 staging；缺命令返nil，命中则核对索引key、request.commandID、receipt.commandID/matchID、canonical request/hash，并与成功重试共用facts/revision/operation历史/outbox完整性验证。
- v2同command异完整请求报commandConflict；成功命令先复核首次receipt所引用的所有facts/revision/操作请求/outbox原bytes与允许的状态演进，再返回首次receipt，不先做generation CAS。staleGeneration无成功反馈；已成功后generation推进不破首次重试。
- operation请求永不可变；仅尚未执行的pending可CAS为cancelled且observation必须nil；cancelled为终态、pending查询排除，needsReconciliation除下述NATIVE-011已证明未创建例外外不得取消。终结可取消排队start/recover/resume；尚未dispatch且被最新已提交业务状态取代、已无实例或当前真实状态已满足的pending pause/resume也可取消；needsReconciliation仍必须对账。业务paused时未启动的新start保持pending，真实resume事实提交后再dispatch，未启动token不另造pause/resume操作。finish仅在对应原start已cancelled或明确notCreated时可取消。marker先赢后仍须在gateway前重读终结并对账/收尾，不伪造未创建。pending→needsReconciliation须先COMMIT再发side effect。结果已知后写settled/failed；savedAwaitingLink或不确定结果保持needsReconciliation。重启pending可首次perform；needsReconciliation只能先reconcile，不能盲perform。恢复/重试必须验证原binding、关联command及token。
- 单机没有可信peer时只unrouted；M3以真实已认证路由原子产出稳定packet并标routed，保留原outbox。该后续API不在M2伪实现；路由/ACK不能遗漏capture revisions，checksum不是身份认证。
- 现有完成凭据只绑events。006在Store层增加版本化存储proof：`evidence: TrustedCompletionEvidence, captureDigest: String`；digest对排序后的完整revision canonical集合计算，未采集空集合有明确v2域分隔。旧无采集v1凭据按原规则保持；一旦新增采集revision，旧proof失效。snapshot()与snapshotV2()都须在返回前过滤失效proof；旧saveCompletionEvidence入口遇任何capture revision均拒绝以旧格式保存，不能重新装成completed。saveCompletionProofV2同时CAS核验expectedGeneration、当前事件evidence、当前完整captureDigest及now；新proof须由真实完整保存边界确认当前事件与采集digest。M2无此边界，不能从commit/任意ACK造completed。不要通过假event更改核心hash。旧receipt不因此失效。
- 新增StoreError case：`captureConflict, invalidCaptureRevision, missingCaptureParent, captureBranch, operationConflict, invalidOperationTransition, staleCaptureEvidence`；既有invalidRequest/staleGeneration/unresolvedDiagnostics/corruptPayload继续适用。事务失败回滚；冲突/损坏原bytes和诊断按既有preservingDiagnostics语义保留。

## 3. 007 依赖注入与会话接口

MatchSession是现有SwiftPM包中的product/target，依赖MatchCore/MatchStore；下面协议不导入HealthKit/SwiftUI。SessionRepository由MatchStore适配；clock/ID/identity须Sendable且并发安全。

```swift
public protocol SessionRepository: Sendable {
    func matchIDs() async throws -> [String]
    func databaseNamespace() async -> String
    func snapshotV2(matchID: String) async throws -> StoreSnapshotV2
    func committedCommandV2(commandID: String) async throws -> CommittedCommandV2?
    func commitV2(_ request: StoreCommitV2) async throws -> CommitReceiptV2
    func pendingCaptureOperations(matchID: String) async throws -> [CaptureOperationRecord]
}
public protocol DeviceIdentityProvider: Sendable {
    func localDeviceID() async throws -> String
}
public protocol SessionClock: Sendable { func now() -> Date }
public protocol SessionIDFactory: Sendable { func nextID() -> String }
public protocol StartPermitProvider: Sendable {
    func acquire(for intent: StartIntent) async throws -> TrustedStartPermit
}
public protocol WorkoutGateway: Sendable {
    func perform(_ operation: CaptureOperation) async -> WorkoutObservation
    func reconcile(_ operation: CaptureOperation) async -> WorkoutObservation
}
```

DeviceIdentityProvider返回持久稳定的本机ID，重新启动不新造ID；丢失本机identity时不得接管旧binding。生产permit provider在M4前明确unavailable，M4可信网络边界才构造verifiedNetwork许可；UI永不构造。developmentSimulation只允许显式开发environment、独立数据库namespace和Debug入口。

| 会话类型 | 必须值 |
|---|---|
| SessionAction | `start(starter: Bool), quick(QuickRecordAction), undoLastQuick, enterField, leaveField, pause, resume, end` |
| SessionEnvironment | `production, development(databaseNamespace: String)`；每次公开异步操作在副作用前通过repository.databaseNamespace校验实际开发DB命名空间与environment匹配且不等于生产，不只信任UI标签；同步init不发起异步数据库访问。实际SQLite路径工厂构造时仅接受非空小写ASCII字母/数字/连字符/下划线namespace，拒绝生产目录的大小写/Unicode别名 |
| SessionRequest | `commandID: String, matchID: String, requestedAt: Date, expectedGeneration: Int64, action: SessionAction, eventIDs: [String], captureOperationID: String?`；start还带固定`StartIntent`，在实际实现用同名可选`startIntent: StartIntent?`，其他action必须nil |
| CapturePhase | `notRequested, pending, recording, paused, savedAwaitingLink, finished, needsReconciliation, notRecorded(CaptureFailure)`；与业务running/paused/ended分别展示 |
| SessionSnapshot | `store: StoreSnapshotV2, replay: ReplayResult, capturePhase: CapturePhase, captureFailure: CaptureFailure?, lastUndoableQuickEventID: String?`；不含HR/GPS/距离/速度，不是第二份事实库 |
| SessionReceipt | `receipt: CommitReceiptV2, snapshot: SessionSnapshot`；只有COMMIT后才能返回；start多阶段的最终业务receipt与原持久意图可按固定子command回查 |
| RecoverySelection | `none, intentAwaitingPermit(StartIntent), active(SessionSnapshot)`；异常候选抛下列明确错误 |

```swift
public actor MatchSession {
    public init(store: any SessionRepository, deviceIdentity: any DeviceIdentityProvider,
                clock: any SessionClock, ids: any SessionIDFactory,
                permits: any StartPermitProvider, workout: any WorkoutGateway,
                environment: SessionEnvironment)
    public func prepareStart(starter: Bool) async throws -> SessionRequest
    public func prepare(_ action: SessionAction, matchID: String) async throws -> SessionRequest
    public func execute(_ request: SessionRequest) async throws -> SessionReceipt
    public func recover() async throws -> RecoverySelection
    public func snapshot(matchID: String) async throws -> SessionSnapshot
    public func updates(matchID: String) -> AsyncStream<SessionSnapshot>
}
```

start固定 `commandID == startIntent.id`，eventID、operationID、outboxID由该稳定ID按用途派生；intent/start的expectedGeneration为0/1，使用原requestedAt和starter。execute先lookup保存的完整请求/首次receipt，再判断当前状态；已保存descriptor可重建规范start请求，不用最新sequence/parent/now替换原请求。

prepareStart只分配稳定请求，不写DB；首发/替补确认后execute，取消不创建意图。prepare拒绝start，避免绕过专用准备。execute(start)先以`commandID + "/intent"`持久原StartIntent，再用原intent向provider获取许可；许可匹配后以`commandID + "/start"`保存升级descriptor/start/facts+outbox+采集operation。上述两个子请求的expectedGeneration、IDs、时间一旦生成即固定并可按command回查；重复点击不新建matchID绕锁。失败待许可意图可以恢复，不当作已开赛。

业务提交队列按match串行，inFlight在任何await之前登记；新命令从最新已提交snapshot生成staging。执行侧效应脱离业务队列/SQL事务，允许end先落盘；结果回来的提交再入队并重读最新状态。UI只采用receipt.snapshot或已提交updates；提交失败不采纳staging、不成功触觉。快记跨四按钮统一按原请求时间防1000ms连击，clock回拨/非法时间按核心规则报错，不把UI禁用当唯一guard。

同request重试包含原expectedGeneration和全部payload，不用新now/ID改写。明确staleGeneration且确认该command未成功时，重新加载后用新的commandID准备新操作；先前不确定请求先查receipt，不自动重做side effect。采集结果的持久请求也遵守此规则；观测本身和原operationID保持，CAS重试不得再次启停Workout。

recover枚举全部matchIDs后读snapshot。只有唯一、无blocking诊断、本机recordingDeviceID且非终结候选可恢复；多个候选不按最近时间随选。结束/异常终结永不继续采集，迟到start/end保留原比赛但不复活，不因恢复换match/device；不写UserDefaults currentMatch或第二份比分/clock。

SessionError明确case：`permitUnavailable, identityUnavailable, wrongRecordingDevice, multipleCandidates, terminalMatch, blockedDiagnostics, requestInFlight, invalidRequest, developmentIsolationRequired`；底层MatchCommandError/StoreError原样可识别（含debounced、commandConflict、staleGeneration），UI给可重试/只读/待对账状态，不吞错当成功。

## 4. 采集观测、跨系统对账与失败语义

NATIVE-011 的唯一 needsReconciliation→cancelled(nil) 例外是 finish：其同 binding/token 的原 start 已持久化为 failed.notCreated，且原 start 的 canonical command、receipt、facts 与完整 history 均通过校验。检查所有同 token 历史，running/paused/stopped/savedAwaitingLink/linked、unknown 的实际 start/end 窗口或 routeFailed 均为正向存在证据；任何 recover 请求也使此 fresh-start 证明不成立。notCreated 自身不得携带实际窗口。已有真实 capture revision/segment 或非空缺口窗口阻止例外；segment 缺少可信 token 归属，因此同 binding 的任一真实 segment 都保守阻止取消，不能从 ID 猜归属。已有片段的 replacement token 可能继续对账，本例外不解决全部恢复收尾。

此证明须在写入、v1/v2 snapshot、pending/readback、committedCommand 与首次 receipt 重试路径一致复核。迟到正向观测与已持久 notCreated 矛盾时，保存原始 bytes 与 blocking 诊断；该已知矛盾也阻止后续取消/已取消证明的读取和重试，不静默丢弃事实。Session 仅在原 start 负证明 COMMIT 后重评估 finish 并 CAS 取消，取消 COMMIT 后才展示 notRecorded；业务仍 endedPendingSync、后台锁仍 held。一般 needsReconciliation 与其他 action 维持原规则。

负证明来源仅允许采集适配器的本实例 fresh start：尚在权限等待但 terminal 已先锁定，makeDriver 从未调用、无 recovery 请求、无正向存在观测或实际窗口，且迟到授权也不能创建。重启/一般 reconcile、构造尝试及未知外部副作用都不能推断未创建；本纯核心任务用门控 fake 验证持久推进，真实适配器与设备证明由 NATIVE-008 负责。

WorkoutObservation为Core的非健康可Codable值，字段：`operationID: String, binding: CaptureBinding, externalToken: String, observedAt: Date, outcome: WorkoutOutcome, window: CaptureWindow, failure: CaptureFailure? = nil`。outcome为`running, paused, stopped, linked(workoutID: String), savedAwaitingLink, notCreated(CaptureFailure), unknown`。CaptureFailure为`writeDenied, locationDenied, unavailable, recoveryUnavailable, routeFailed, captureFailed`；没有readDenied猜测。unknown不等于notCreated。failure为正交降级字段，nil编码省略；既有Workout的失败保留真实outcome，不能改写为notCreated。route失败仅使原route builder失效，真实running/paused/linked等outcome加routeFailed可settled；不另开Workout。已确认stop但endCollection/finish未证明保存时，stopped+captureFailed保持needsReconciliation及原token。failed只表示动作已确认失败且无未决side effect。SessionSnapshot.captureFailure从已提交观测派生，无关成功观测不自动清除同片段既有route警告。同token跨operation的linked为单调已保存证据，优先于savedAwaitingLink，再比较实际observedAt；不得用operation创建顺序把旧running覆盖为当前物理状态或对已保存token再perform finish。window只填实际观测，不能把requestedAt当采集开始证明。

每个实际Workout片段生命周期唯一的externalToken写入HealthKit metadata，同一原session恢复沿用，确认恢复失败后的新真实片段分配新start operation/token并记录gap；多个Workout不得共享首次全场token。关联查询同时核对source app、原match/device和token；token不是授权或Workout UUID。保存返回真实对象或解锁后查到真实UUID，才追加CaptureSegment。nil,nil表示已保存但锁屏暂取不到对象，savedAwaitingLink保留待对账；空query也可能因锁屏/读取不可知，不能据此新建。SDK recover能得到原session时接原builder，不再次startActivity/beginCollection。系统崩溃自动恢复、用户强退、设备重启分别验收；后两者不保证原session恢复。锁屏/空查询/unknown不证明旧片段不存在。

持久顺序：①业务facts、outbox、pending operation COMMIT并反馈业务保存；②操作先转needsReconciliation COMMIT；③事务外perform；④观测结果、真实关联revision/缺口与operation状态COMMIT。①失败不调gateway；②后崩溃先reconcile；③成功④失败保留原operation/token再查，不能重建；权限失败不撤销已存比赛。对账仍未知则保持needsReconciliation，明确提示，不能自动标完成。

业务pause/resume先保存，然后驱动采集；失败时业务仍按事实paused/running，采集状态另显。enter/leave不调gateway。iPhone手动样本暂停期间不加入有效样本，写真实WorkoutEvents；原始HR/GPS/Workout/路线只在HealthKit，内存实时显示可用，业务库/CloudKit/后台不存这些健康值。

恢复无法取得原Workout时先对账确认可执行的恢复失败，再在原binding下从实际新采集时刻续段并记录gap；未知两端可为nil，不插值或归零。若尚有savedAwaitingLink/未知side effect，不盲新建。恢复期间终结落盘，则排队的start/recover/resume取消；已真实启动的迟到结果只stop/finish原片段，不再续采。所有路径均不释放后台锁。

实时健康展示走WorkoutCapture→MatchPresentation的独立内存通道，数值optional并带available/notRecorded/unsupported状态；不得塞入SessionSnapshot、StoreCommit、BusinessDelta或日志fixture。requestAuthorization成功不代表读获准，authorizationStatus是写权限，空读取显示未记录/不可知。没有iPhoneHR来源不能填0或承诺来自Watch。

## 5. 依赖验收清单

- 006：v1原bytes/receipt/ACK回归、v2迁移原子性、facts/capture/operation/outbox故障回滚及重开、revision冲突/缺父/分叉、旧proof失效。
- 007：提交失败无反馈、同请求重试、并发/重入、跨按钮guard、恢复候选/错误设备/终结、side effect成功DB失败/原token对账、终结与迟到采集竞态。
- 008：iOS17手动/watch10 live编译、权限隐私、nil,nil待解锁、route fatal、系统恢复原session不重复启动、用户强退/设备重启如实降级、每片段token唯一及iPhone恢复缺口；宿主fake不算设备证据。
- 009：所有源进入target，实际模拟器启动，失败/取消/撤销/暂停/终结及可访问性证据；010真机验收与设备实现入dev门禁详见M2计划。M3/M4传输/真实锁未通过前不宣称正式记录闭环。
