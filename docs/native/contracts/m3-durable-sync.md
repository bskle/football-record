# M3 持久设备同步合同

状态：NATIVE-013 冻结设计；014 已合入，015 的已测实际接口增补如下。各任务审阅与集成状态分别见任务卡，不能由接口落地推定已合入。实施顺序见 [M3 子计划](../../superpowers/plans/2026-10-16-native-m3.md)，既有事务语义见 [M2 合同](m2-session-capture.md)。最低 iOS 17 / watchOS 10 不变。

## 1. 边界与最小方案

M3 只传比赛事实及非健康采集元数据。每条原 `BusinessOutboxItem` 首次路由时，在同一事务内物化一个包含完整 `MatchDescriptor`、本机当时全部 `MatchEvent` 和完整 `CaptureRevision` 祖先链的不可变 v2 包，再保存该原 outbox→包的映射。后续新增事实进入新的原 outbox、新包；重试只发送已保存原字节。完整快照避免合法 r2 先于 r1 到达被本地严格 append 校验误判为缺父；不另建等待父修订的业务队列。

本机 `generation` 仅为 SQLite CAS 版本，不能当跨设备 revision、包序或接收游标。每个 `(sourceDeviceID, targetDeviceID, matchID)` 有独立、持久、从 1 递增的 `sequence`。接收端可先接收序号 2 并 ACK 2，仍记录缺口 1；发送端逐包重试，不能用 ACK 2 推定 ACK 1。

不传 `CaptureOperation`、operation ledger、原 command 请求、HealthKit 样本、心率、GPS、路线、距离、速度或卡路里。收到元数据不执行 peer 的 SDK 操作。端到端 ACK 只证明此包业务事实已在接收库完整 COMMIT，不能制造 `completed`、完成凭据或释放后台锁。

## 2. v1 / v2 数据兼容与 v3 schema

NATIVE-014 在一个 `BEGIN IMMEDIATE` 事务内 additive 迁移到 schema 3。先完整验证既有 schema；保留 v1 canonical、checksum、固定 fixture、legacy receipt/ACK、v2 command hash、capture registry、原 business payload 与原 receipt 引用。v0/v1 按现有路径到 v2 再到 v3；任何迁移故障回滚到可重开原库，未知未来版本拒绝且保留原文件。

原 `business_outbox` 行保持原 `state='unrouted'`、payload、digest 和 ID，永不 UPDATE/DELETE/改绑；既有 loader 只接受该 state，原 `commitV2` / `committedCommandV2` 重试仍复核原行。旧 `pendingBusinessOutbox` 保持返回原始业务项的兼容语义；M3 专用新查询通过 route 映射排除已经物化的项。路由和 ACK 只更新新增台账，不删除原业务事实。014交付 route/inbox/ACK/sequence/progress 和 durable ACK 控制项；可以预建 delivery/fragment 空表，完整辅助 API、分片与调度算法由015负责，不作为014验收前置。

| 新表 | 持久内容与约束 |
|---|---|
| `sync_routes_v3` | 原 outbox ID 唯一、原 payload digest、packetID/idempotencyKey、source/target/match、sequence、canonical packet bytes/digest、trust epoch；同 outbox 只能有此条不可变映射，同域 sequence 唯一 |
| `sync_sequences_v3` | 上述发送域的 nextSequence，事务分配、防 Int64 溢出；不由 generation 推导 |
| `sync_inbox_v3` | peer 域、packetID/idempotencyKey/sequence、完整 canonical 原字节、首次接受的 descriptor 投影/digest、首次 ACK 原字节与首次接收结果；任一索引重用须匹配全部原字节 |
| `sync_acknowledgements_v3` | 被确认 packetID、原 ACK 字节/digest、验证过的接收 peer；只有匹配已存路由的 ACK 才插入 |
| `sync_receive_progress_v3` | peer 域的 highestObserved / highestContiguous 和缺失区间；补包收敛，不把高序号当低序号已接收 |
| `sync_delivery_v3` | outbound packet/ACK 控制项的稳定 ID、attemptCount、nextAttemptAt、最后错误；callback 仅记录尝试，不变更业务 ACK |
| `sync_fragments_v3` | 经信任检查的原传输片段字节/hash、所属完整包 digest、分片头、首次/截止时间；重开可继续组装 |

事实/registry/outbox/route/inbox/ACK 任一损坏均报明确错误并保留原 bytes 诊断，不能当空列表或已同步。保留旧故障点，新增 migration-v3、afterRoute、afterInboundFacts、afterInboundReceipt、afterACK、afterFragment、beforeCommit/afterCommit 故障点。COMMIT 后 responseLost 由原请求重试恢复。

## 3. 新值类型与 canonical 包

所有下列公开值 `Codable, Sendable, Equatable`，有校验构造器和 decoder。ID 去空白后非空；source/target 不同；Int64 正数且不溢出；Date finite；hash 为小写 SHA256 hex。canonical 为 sortedKeys JSON；checksum 对不含自身 checksum 的完整 Body 计算，并使用明确 `football-record.sync.packet.v2` / `ack.v2` / `fragment.v2` 域分隔。v1 算法及字节完全不变。

| 类型 | 必需字段 |
|---|---|
| `PeerAuthorization` | `localDeviceID, remoteDeviceID, accountSubject, pairingID, trustEpoch: String; environment: PeerEnvironment; issuedAt, expiresAt: Date`；环境是 `.production` 或 `.development(databaseNamespace: String)` |
| `MatchPacketV2.Body` | `version=2; packetID, idempotencyKey: String; sequence: Int64; sourceDeviceID, targetDeviceID: String; descriptor: MatchDescriptor; events: [MatchEvent]; captureRevisions: [CaptureRevision]` |
| `MatchPacketV2` | `body: Body, checksum: String`；events 按稳定 ID 排序，revisions 按 revision 再 ID 排序；包含全部已提交事实，包括删除/撤销 tombstone，不能只发 replay 后有效事件 |
| `DurableACKV2.Body` | `version=2; ackID, packetID, idempotencyKey, matchID: String; sequence: Int64; packetChecksum, sourceDeviceID, targetDeviceID: String`；ACK source 是接收包的本机、target 是原包 source |
| `DurableACKV2` | `body: Body, checksum: String`；ackID 为域分隔后的 packetID + packetChecksum + 接收设备 ID 的 SHA256，稳定且可重建 |
| `RouteReceiptV3` | `outboxID, sourcePayloadDigest: String; packet: MatchPacketV2` |
| `InboundReceiptV3` | `ack: DurableACKV2; matchID: String; generation: Int64; insertedEventIDs, insertedCaptureRevisionIDs: [String]`；首次 COMMIT 的结果固定，重复包不制造新业务变化 |
| `SyncGap` | `lowerBound, upperBound: Int64`，闭区间；排序、非交叠、只描述已观察域以内的空洞 |
| `SyncState` | `matchID: String; unroutedCount, pendingACKCount, receivedGapCount: Int; lastPeerACKAt: Date?; issue: SyncIssue?`；计数来自持久行、时钟只用于展示 |
| `SyncIssue` | `.peerUnavailable, trustUnavailable, transportUnavailable, retryScheduled, ancestryIncomplete, invalidPayload, blockedIntegrity, quotaExceeded`；不得把 unknown 变成已同步 |

packetID/idempotencyKey 由 `outboxID + source + target` 的不同域分隔 SHA256 派生，首次路由保存后不再计算替换。一个 outbox 只路由一次且只支持当前可信 pair；换机/换账号使旧目标暂停，M4 设备生命周期另立显式迁移，M3 不改绑旧包。快照物化和 sequence 分配在同一 Store 事务，无 await，不使用物化前的外部 snapshot。首次路由必须先用与接收端相同的 validator 验证完整 event/capture 父闭包；legacy合法暂存缺事件父时，返回可重试 `ancestryIncomplete` 诊断，原outbox仍未路由、不分配packet、不消耗sequence，不冻结一个永久不可接收的坏包。

ACK 仅确认该包在 `sync_routes_v3` 显式映射的原 outbox，不能因为完整快照还附带了其他业务项的事实，就顺带确认那些未映射 outbox。原 outbox 后续仍分别物化并取得各自 ACK。

新增 Store 接口目标（NATIVE-014，方法在现有 `MatchStore` actor 上）：

```swift
public func unroutedBusinessOutboxV3(matchID: String) throws -> [BusinessOutboxItem]
public func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization,
                                 now: Date) throws -> RouteReceiptV3
public func pendingPacketsV2(matchID: String) throws -> [MatchPacketV2]
public func receiveV2(_ bytes: Data, peer: PeerAuthorization,
                      expectedMatchID: String, now: Date) throws -> InboundReceiptV3
public func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) throws
public func syncStateV3(matchID: String) throws -> SyncState
```

Store 检查授权值的结构、环境、本地/远端方向、有效期、matchID 和所有 header；账号与配对真实性由下节可信 provider 负责。不得让 UI 直接构造 production 授权后调用 Store。每次 route/receive/ACK 的调用方必须先重新验证同一授权 epoch。

## 4. 接收事务、乱序与持久 ACK

1. 在业务事务前验证可信 peer、字节上限、version、canonical/hash、目标、source、matchID、descriptor、所有事实和 capture 链。原始 packet 只有通过完整重组校验后才进入此入口；无半包业务 ACK。
2. `CaptureRevision` 必须从 root revision 1 / parent nil 到包内唯一 head 连续闭合、binding 相同；同 ID 同 canonical 的共有前缀幂等。已存 r1/r2 收到旧快照 r1 可 ACK 且不回退；先收到 r1/r2 再收到 r1 不是分叉。已存较短前缀只追加后缀；不同字节的相同 ID、跨 match/binding、两条不同后继、包内缺父均是真冲突，隔离完整原 bytes、blocking 且不 ACK。不能把包内缺父交给严格本地 append 后补救。
3. events 以原始 ID/parent/撤销/删除事实集合合并；完整源快照需包含源已有 ancestry。保留既有 v1 `receive` 对缺事件父的落盘/回放恢复语义，不改旧协议；v2 新包缺其自称完整的事件父则拒绝原包。合并不覆盖原 facts、不让旧包复活 tombstone，不将源库 generation 导入本库。descriptor recorder 和每个 event.sourceDeviceID 必须属于授权 local/remote pair；`.live` 仅原 recorder，`.postMatch` 和 `.abnormalTermination` 沿用现有合法编辑/终结 authority 语义，不能新增“所有事实只能 recorder”限制。原始输入 descriptor 只作为快照事实载体：startIntent/starter/recordingDeviceID 必须与本地不可变身份一致；peer 不能靠公开可构造的 descriptor 或 ACK 声称后台释放/完成。M3 拒绝 incoming `releaseRequested/releasedConfirmed`、任何 completion proof 字段或自报 verifiedNetwork 许可；development permit 必须完整等于 `DevelopmentStartFixture.permit(for: descriptor.startIntent)`（含 evidence/intent/match/recorder/规范permitID），并通过 development namespace / pair 隔离检查。无本地 descriptor 时只接受该已验证 development 许可对应的 unknown/held 投影；production provider 在 M4 前不可用。已有本地可信 permit/锁/完成证明不由 peer 覆盖，晚到 held/unknown 包不能回退本地权威状态；若遇当前版本无法验证的本地权威证明，fail-closed，保留原状态。未来 M4 经独立 server/cloud proof 入口建立可信权威投影，不能放宽本接收入口。
4. 在一个事务保存 descriptor、事件、capture revisions、registry、接收进度、首次完整 inbox 和原 ACK 控制项；无新事实仍保存稳定 inbox/ACK。不导入对端 operations、不以接收操作制造新的本机业务 outbox。只有实际新增业务事实才推进本机 generation；与本机命令交错由当前 Session 队列串行安排。
5. COMMIT 后返回首次 `InboundReceiptV3`。ACK 丢失、回调失败、重启或 responseLost 时，原包重试先验证 inbox 全部原字节，再重新核对持久 descriptor 身份、首次接受投影与当前权威状态的合法延伸、facts/revisions/registry 和原 ACK 的完整性后返回原 ACK；不只查到 packetID 就成功。原 payload hash 始终绑定输入原字节，不为适配本地权威投影重写输入；验证投影不要求当前 lock/permit 与旧 peer 可变字段逐字相同。事实被损坏/删除不能继续 ACK。
6. 发送端验证当前可信 ACK 来源、本机 target、packetID/idempotencyKey/sequence/matchID/checksum 和已存路由原包，再在事务内保存确认。相同 ACK 幂等；同 ID 异 payload/错误 peer 拒绝并隔离。旧 v1 ACK 不能确认 v2 包。传输 completion/reply callback、接收文件成功、replay 成功均不能代替这一步。

已确认的 packet 不再列入 `pendingPacketsV2`，但路由、原包、原业务项与命令回执保留。完成凭据继续绑定完整业务事实 + captureDigest；任何新增 revision 使旧 proof 失效，ACK 本身不生成 proof。

## 5. 可信 peer 与模块依赖

`PeerTrustProvider` 必须验证持久本机 ID、实际远端 ID、同账号、当前有效配对/登记关系及环境，再授权 routing、receive、ACK 与发送。`WCSession.isPaired/isWatchAppInstalled/activationState/isReachable` 和 checksum 都不是账号认证。M4 前 production provider 始终 unavailable，不从 WCSession 推导账号，不生成 `phone`、空 target 或临时随机 peer 伪装可信身份。

```swift
public enum PeerOperation: Sendable { case route, send, receive, acknowledge }
public protocol PeerTrustProvider: Sendable {
    func authorize(_ operation: PeerOperation, remoteDeviceID: String?) async throws
        -> PeerAuthorization
    func validate(_ authorization: PeerAuthorization, for operation: PeerOperation) async throws
}
public protocol SyncTransport: Sendable {
    func activate() async
    func deliveries() async -> AsyncStream<SyncDelivery>
    func send(_ fragmentBytes: Data, deliveryID: String) async throws
    func didPersistDelivery(_ transportDeliveryID: String) async
}
public struct SyncDelivery: Sendable {
    public let bytes: Data
    public let transportDeliveryID: String
}
public protocol SyncInboundCoordinator: Sendable {
    func receiveSyncPacket(_ bytes: Data, peer: PeerAuthorization,
                           matchID: String) async throws -> InboundReceiptV3
    func receiveSyncACK(_ bytes: Data, peer: PeerAuthorization) async throws
}
```

`UnavailablePeerTrustProvider` / `UnavailableSyncTransport` 是正式装配默认值。Debug 协议验收用两个实际独立 namespace / SQLite 文件、各自持久身份文件和明确固定配对/账号 fixture；重启身份不变化，身份丢失拒绝接管。fixture 工厂只在 `#if DEBUG` 和 development 环境可达，不能传给 production namespace；持续展示“开发模拟锁 / 开发配对”。这只验证协议，不证明 M4 账号或生产信任。

`MatchSync` 是 `native/Packages/MatchCore/` 的真实 product/target，依赖 MatchCore + MatchStore，不依赖 MatchSession/SwiftUI/WatchConnectivity。公共同步 DTO、`PeerTrustProvider`、`SyncRepository` 和 `SyncInboundCoordinator` 放 MatchStore；`SyncTransport`/`SyncDelivery` 和服务放 MatchSync。MatchSession 保留原依赖方向并实现 coordinator，无 Session→MatchSync 反向依赖。NATIVE-015 扩充 `SessionRepository: SyncRepository`，由 `SQLiteSessionRepository` 复用该对象内部唯一 `MatchStore` actor 与 SQLite 连接；Session 与 SyncService 注入同一 facade。禁止第二个不受 Session 协调的可写 `SQLiteSessionRepository`/MatchStore 连接。

`SyncRepositoryIdentity` 含 facade 启动时生成的 instanceID 与实际 databaseNamespace，和设备 ID / 信任无关；coordinator 暴露相同 identity，服务启动必须比较相等，拒绝另一连接伪装为相同 namespace。新增仓储辅助方法均由 015 在现有 MatchStore extension 内实现，SQL 只经过该 actor。签名固定为：

```swift
public protocol SyncRepository: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func matchIDs() async throws -> [String]
    func unroutedBusinessOutboxV3(matchID: String) async throws -> [BusinessOutboxItem]
    func routeBusinessOutboxV3(outboxID: String, peer: PeerAuthorization,
                               now: Date) async throws -> RouteReceiptV3
    func pendingPacketsV2(matchID: String) async throws -> [MatchPacketV2]
    func receiveV2(_ bytes: Data, peer: PeerAuthorization,
                   expectedMatchID: String, now: Date) async throws -> InboundReceiptV3
    func acknowledgeV2(_ bytes: Data, peer: PeerAuthorization, now: Date) async throws
    func syncStateV3(matchID: String) async throws -> SyncState
    func ensureSyncDeliveriesV3(matchID: String) async throws
    func dueSyncDeliveriesV3(now: Date, limit: Int) async throws -> [SyncDeliveryRecord]
    func recordSyncAttemptV3(deliveryID: String, nextAttemptAt: Date,
                             issue: SyncIssue?, now: Date) async throws
    func validateSyncDeliveryV3(deliveryID: String, peer: PeerAuthorization,
                                 now: Date) async throws
    func reactivateSyncACKsV3() async throws
    func acceptSyncFragmentV3(_ bytes: Data, peer: PeerAuthorization,
                              now: Date) async throws -> FragmentAssemblyResult
    func pendingSyncAssembliesV3(peer: PeerAuthorization,
                                 now: Date) async throws -> [FragmentAssemblyResult]
    func consumeSyncAssemblyV3(messageID: String, wholeChecksum: String) async throws
    func expireSyncAssembliesV3(now: Date) async throws
}
```

`SyncDeliveryRecord` 为 `deliveryID, messageID, matchID, sourceDeviceID, targetDeviceID: String; kind: SyncMessageKind; fragmentBytes: Data; attemptCount: Int; nextAttemptAt: Date`。`SyncMessageKind` 只有 packet/ack；`FragmentAssemblyResult` 为 `.incomplete` 或 `.complete(messageID: String, kind: SyncMessageKind, matchID: String, wholeChecksum: String, bytes: Data)`。`ensureSyncDeliveriesV3` 仅从已验证的 route/inbox ACK 原字节生成稳定分片和发送计划；不接受任意调用方 payload。`consume` 先复核成功业务/ACK receipt，再删除已消费的临时组/片段；重复 consume 安全，原 inbox/ACK 审计字节仍保留。完整但未 consume 的消息是持久恢复工作，启动和可重试的普通 wake 会重新经同一 Session 重放，成功后消费；不依赖发送端再送新帧。一个已隔离坏包不阻止其他完整消息处理。上述值均有完整校验构造器/decoder；`SyncRepositoryIdentity` 和 `SyncDeliveryRecord` 无网络身份权威。

015的服务公开入口固定为 `MatchSyncService.init(repository: any SyncRepository, inbound: any SyncInboundCoordinator, transport: any SyncTransport, trust: any PeerTrustProvider, clock: any SyncClock)`、`start() async throws`、`wake() async`、`connectionDidActivate() async`、`stop() async`、`state(matchID: String) async throws -> SyncState`、actor 方法 `states(matchID: String) -> AsyncStream<SyncStateUpdate>`（跨 actor 调用须 await）。`SyncClock: Sendable` 只需 `func now() -> Date`，SystemSyncClock为正式实现；start先校验两端repositoryIdentity相等再激活/恢复调度，stop取消内存loop且保留持久任务，重复start不产生第二loop。states订阅先读持久状态，再送变化通知。`SyncStateUpdate: Codable, Sendable, Equatable` 为 `.state(SyncState)` 或 `.unavailable(matchID: String, issue: SyncIssue)`；读取失败明确发 unavailable/blockedIntegrity，不伪造零计数或保留旧成功通知。恢复读取后发新持久 state。

### 015 实际辅助入口与 016/017 交接

- `SQLiteSessionRepository` 在创建时一次生成 instance UUID，identity 的 namespace 来自实际路径配置；每个 Session/coordinator/service 必须共享这个 facade 与其唯一 Store actor。两个实际隔离库使用各自 namespace，不能从 incoming 授权反向配置。facade 对 production 显式传 Store `.production`，其他受限开发 namespace 显式传 `.development(databaseNamespace:)`；正式 trust/transport 默认 unavailable。两处 Presentation wrapper 真实转发底层 identity 和方法，无共同假 identity。
- `validateSyncDeliveryV3` 复核保存 route/inbox 的原绑定与原分片，不允许新 account/peer/epoch 替换旧目标。`reactivateSyncACKsV3` 保留累计 attemptCount，只重置本轮连续次数与休眠；仅新 start、重复原包或真实 `connectionDidActivate` 使用，普通 timer/wake 不重置八次预算。016 必须只在真实新连接激活时调用 `connectionDidActivate`，它不新增监听器/发送 loop。每次 start/真实激活先标记需要恢复，再做 trust await；信任暂失后普通 wake 可继续恢复。
- `pendingSyncAssembliesV3(peer:now:)` 只枚举经当前授权重新验证的完整未消费消息。完整组不因 24 小时过去而丢失；期限只清理尚未组装完整的片段。服务 COMMIT 后通知/cleanup 失去结果也保留恢复标记，普通 wake 可再次经同一 Session 处理。
- `didPersistDelivery` 有无设备影响的默认 no-op；service 仅在 `acceptSyncFragmentV3` 成功返回后、业务 process 前调用。授权失败、SQL/落盘失败、COMMIT 后 responseLost 均不通知；原片已持久的合法重放成功可通知。016 据此仅释放 transport 自有 durable inbox 输入文件。这个通知只证明本机片段持久，不是业务 ACK，不更新发送端 business/outbox 状态。
- 017 订阅 typed `SyncStateUpdate`；unavailable 表示计数未知，不能从上次 `.state` 保留“对端已保存”结论。真实待重试 delivery 的最后错误在 backoff 和重开后仍从持久记录恢复。

## 6. Session 串行、通知与重开

`SyncInboundCoordinator` 另需 `func syncRepositoryIdentity() async -> SyncRepositoryIdentity`。`MatchSession.receiveSyncPacket` 先验证授权、解析受限 header 取得 matchID，再进入现有同场 `acquire/release` 队列；该队列与 execute、恢复、capture reconcile 共用。业务 COMMIT 后在队列内重读 `snapshotV2`、派生 snapshot 并 publish 给现有 `updates(matchID:)` subscribers，然后释放队列；不新建第二 currentMatch 索引。即使是同包重放，也复核首次 receipt 后再次 publish / 唤醒原采集收尾；COMMIT 后 publish/wake 前崩溃或 responseLost 不会永远遗漏清理。ACK 路径只更新同步台账，并发布持久同步状态，不伪造 SessionReceipt/成功触觉。

若接收终结事实：先持久化终结，再根据最新本机 operation ledger 在同场队列中持久化必要 finish/cancel 意图；只清理本机原 recordingDeviceID 的原 token。释放队列后才调度跨系统 gateway，不在 SQL 事务或同场业务队列内等待 SDK / 网络；沿用现有 needsReconciliation / 二次 COMMIT 失败规则，不能因等待 gateway 阻止 ACK 返回。若终结已 COMMIT 而清理意图保存失败，保留已提交 inbox/首次 ACK，当前调用可报可恢复错误，重复包及启动扫描重新派生同一稳定 cleanup ID；不能换 token 或新建 start。重开/recover 必须扫描已存 terminal match 的本机 ledger，不只扫描活动候选，并重新执行原幂等收尾。不是本机 recorder 时只观察，不 start/recover/接管；任何迟到结果只归原比赛、不复活、不正常完成、不释放锁。

收到终结与本机 execute/gateway-await 的竞态必须测试：提交队列串行写业务，gateway await 返回后重读终结，不能写出继续采集意图。只读终结页面仍能观察新的迟到事实；刷新错误保持 NATIVE-012 fail-closed，原未决完整请求不换 ID/时间/generation。`SyncState` 使用独立 `AsyncStream` 仅作通知，订阅/重开先从持久 state 读取；不依赖某条内存通知才能发现已存事实。

## 7. 持久分片、重试和缺口

单个完整 packet 或 ACK canonical 上限 8 MiB。传输 `SyncFragment.Body` 固定 `version=2; kind=packet|ack; messageID; sourceDeviceID; targetDeviceID; matchID; wholeChecksum; totalBytes; index; count; chunkChecksum; payload: Data`，外层 `body, checksum`；index 从 0，chunk 为最多 256 KiB，count≤32，声明长度必须等于重组结果。小于等于 32 KiB 的完整 payload 为单片；更大按 256 KiB 切片。fragmentID 为 messageID/wholeChecksum/index 域 hash，不因重传换 ID。所有头字段和 payload 纳入 fragment checksum；wholeChecksum 明确为完整 canonical message 原 bytes 的 SHA256，区别于 packet/ACK Body 的域 checksum。完整重组后同时复核 messageID/kind/match/source/target 与消息本体一致，再进入业务。公开 encoded-frame 上限为 `SyncFragment.maximumEncodedBytes = 16 MiB`（JSON/base64 外壳上限），`SyncDelivery` / `SyncDeliveryRecord` 构造及 service/Store 入口在 fragment JSON 解码前检查；不放宽完整消息 8 MiB、单片 payload 256 KiB 或最多32片。

信任检查先于片段落盘。接收只接纳当前 peer / 目标/环境；同 fragmentID 同 hash 幂等，同 ID 异字节隔离且不覆盖。按完整消息域原子保存片段；进程重开重组未完成消息。尚未组装完整的每消息有 24 小时组装期限；完整未 consume 组保留到 receipt/consume。每 peer 暂存上限 64 MiB/256 个未消费临时组（含完整待处理组）；超限拒绝新片，不删已提交事实。过期只清理该消息临时片段并保留 timeout 诊断，不发送 ACK；发送端仍保留原包，原样重试可重新组装。计时用持久首次接收时间，时钟倒退不提前过期。无半包 COMMIT/ACK。

SyncService 单 actor、单 drain task，每轮最多处理 32 个 due deliveries；并发 activate/网络变化合并唤醒，不创建重复发送 loop。业务包/控制 ACK 分别持久 attemptCount 和 nextAttemptAt；重试 1、2、4、8、16、32、60、120 秒后最高 300 秒，使用注入 clock，不在测试 sleep。错误保留原 bytes/ID。业务包一直待持久 ACK；ACK 控制项保留原字节、累计 attemptCount 审计与独立本轮连续次数，连续 8 次实际 send 尝试后休眠，重复包或新的连接激活重新唤醒原 ACK，避免无限 ACK-of-ACK。授权失效/不可用只暂停并显示 issue，不进入 send、不消耗尝试/休眠预算；进入 send 后的成功或失败均持久记录 attempt/deadline。callback 只记录 attempt，不确认业务。重开从持久台账继续，不重新路由、不重新分配序号。

缺口按独立 peer 域持久显示；本方案完整快照允许安全接收高序号，发送端仍发送所有未 ACK 的原包，丢失低序号自然重试补齐。没有 skip/累计 ACK，也不为填序号伪造事件。错误/未知版本隔离后显示需处理，不能静默清掉 pending。

## 8. WatchConnectivity 适配与真实设备门槛

NATIVE-016 独占 `native/Modules/DeviceSync/` 实际 SwiftPM 包，仅依赖 MatchSync；通过 driver 协议测 host 生命周期。真实 `WCSession` 只在 iOS/watchOS SDK 条件编译，最低系统不升级。active 且 reachable、encoded fragment≤48 KiB 时用 `sendMessageData` 快路；其余把同一 canonical fragment 文件交 `transferFile(_:metadata:)` 后台通道。48 KiB 是本应用策略上限，不能表述成 Apple 保证值。消息与文件完全复用协议，ACK 同样可走持久后台控制片段。

`sendMessageData` replyHandler 必须被调用，快速回复只可为 transport `accepted/deferred/unavailable`；不等慢 SQL，也不伪装 durable ACK。真正业务 ACK 由上述 Store COMMIT 后的控制项发送；即时 handler 确已取得持久 ACK 时也必须走同一校验路径。`transferFile` completion 只表示系统传输尝试结果，不清业务 outbox。

`didReceive file` delegate 返回前同步 move/copy 到本 App Application Support 下的唯一 durable inbox 文件，确认 copy 成功后才返回并异步送入服务；不能保存系统临时 URL 后立即返回。保留文件直至应用片段落盘，崩溃重开扫描 App 自有 inbox 并以稳定 hash 去重。错误/quota 不 ACK，留下可诊断失败，不能以传输文件回调成功报告业务已保存。

`updateApplicationContext` 只发可覆盖的 latest hint，不能作为事件/ACK的唯一承载，本轮可不使用。只在 `.activated` 发送；处理 activation failure、reachability、iOS `sessionDidBecomeInactive/sessionDidDeactivate`，deactivate 后重新 activate。切换 Watch、账号/配对/本机身份变化使旧 trust epoch 失效、暂停发送与接收，不能把原 pending 重新指向新 peer。

官方限制：`transferFile` 不支持 Simulator，Simulator 不调用接收文件 delegate，必须配对真机验证。两端模拟器只证明 UI 启动、依赖装配和 fake transport 协议；双 SDK 编译只证明 API/availability。当前无本人设备协助时，016 / 018 保持“已自动验证，待真机”，不入 `dev`；017 用 unavailable 生产装配，经双审与模拟器验证可独立入 `dev`。

依据（2026-10-16 主代理已预检官方原文）：[WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession)、[传输官方示例](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)、[transferFile](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))、[接收文件 delegate](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceive:))。官方页面证据保存在树外 `native-validation/M3-official-preflight/`；链接与编译不等于实际通信验收。

## 9. 状态展示与验收不变量

UI 清楚区分本地已保存、待传手机/手表、对端已保存、待云同步、待后台终结。云/后台在 M4 前明确未接通，不能因为 peer ACK 把状态变成云已同步。正常结束仍 `endedPendingSync`；异常结束仍 incomplete 和待终结事实。同步失败不抹除本地已保存提示，不阻止原记录设备离线继续合法记录；显示端一直只读。

必须覆盖迁移回滚、旧 fixture/hash/receipt 原样重试、原 outbox 路由后原 command 重试、capture r2 先到/r1重复/较长本地前缀、真缺父/分叉/跨 match/同ID异payload、ACK 丢失与事实损坏重验、分片乱序/重复/超时/上限/重开、换 peer/过期 epoch/非授权 ACK、发送成功无业务 ACK、Session 终结/gateway竞态/重开收尾、tombstone 不复活。纯协议自动证据与配对真机断连/后台/两端重启证据分开登记，不能互相替代。
