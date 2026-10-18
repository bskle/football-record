# AccountKit：账号、权威控制与同 Session 云桥

NATIVE-023 的本机软件实现。生产 App Bootstrap 仍为 Unavailable；本模块没有接入真实 AuthenticationServices、Keychain、CloudKit、HealthKit 或 WatchConnectivity SDK。实际 Node loopback、文件 SQLite、受控云回读和原 Session 的证据见 [023验证卡](../../../docs/native/validation/NATIVE-023.md)。

## 一个 facade 与装配

创建一个 `SQLiteSessionRepository`，把同一实例传给 `MatchSession`、`AuthorityStartPermitProvider`、`CloudSessionBridge`、`AccountService`、`AuthorityControlService`、`LifecycleService` 和需要的 production peer service。各 bridge/coordinator 比较 `syncRepositoryIdentity()`；不同 facade 即使指向同一文件也不能混装。`SessionRepository` 的原 required 方法未扩大；新增能力均为附加协议。网络/SDK await 在队列和 SQL 事务外，落盘/业务变更回到原 Session 同场或账号队列后重读身份、epoch、终态与 CAS。

`AuthorityTrustConfiguration` 是组合根明确配置的固定 environment/keyID→strict raw32 Ed25519 公钥。Store 使用自己的配置重验原签名字节。`URLSessionAuthorityRelay` 只允许 development loopback，production 需要明确 HTTPS host allowlist，拒绝重定向；`shutdown()` 取消其会话。所有设备签名由 `DeviceProofSigner` 注入，产品代码不保存私钥。

开发 namespace 必须独立且不为 `production`。`AuthorityStartPermitProvider` 先经过实际 HTTP receipt/fresh-held 验签与持久化，development 只返回原 intent 精确 `DevelopmentStartFixture.permit(for:)`；dev receipt 不升级为 verifiedNetwork。production 路径需 production pin/域与生产 Store，App 当前没有启用该组合。

## 登录、恢复与身份暂停

`AccountService` 初始化后，必须由当前 Apple/cloud 身份匹配的显式动作调用 `admitCurrentIdentity(accountID:)`，再调用 `signIn(requestID:challengeRequestID:)` 或 `recover(authRequestID:)`。首次未知账号可传 nil；已有绑定须传当前账号 ID，且 service 的固定 cloudSpaceID、deviceID、公钥必须匹配本地原记录。旧 service/admission 过期后不会自动刷新代次；SDK 事件调用 `LifecycleService.identityChanged()`，在同 SQLite 推进 identity generation、暂停绑定并清可选统计，然后单调推进 vault fence、停 transport scope。当前双身份重新核实后才能显式新 admission。

`AppleSignInDriver.authorize(nonceSHA256:)` 输入为后台 challenge **字符串 UTF8** 的 SHA256，同时绑定 Apple nonce 与设备 challenge proof。JWT/code 只 transient，不能写业务 DB/日志；本地只持久原 auth requestID、公钥/指纹、challengeID、完整 transmitted canonical request digest 与 admission generation。device keyID 为 strict base64url 公钥字符串 UTF8 的 SHA256，不能换成 raw32 的摘要。

recover 使用原 authID/device/key/publicKey、新 nonce/time 与覆盖完整 body 的签名。已提交返回原 session；`knownRevoked/knownExpired/knownAbandoned` 是有限终态。knownAbandoned 只证明当前没有可恢复原记录且原 tuple 已永久 fenced，不能声称历史从未 commit。404/401/timeout/丢响应保持 unresolved，Store 单事务只准一个未知尝试，新 ID/challenge 不能绕过它。明确终态后仍由调用方显式开始 fresh Apple 流程。旧终态只在 auth-current/identity generation 的同事务 CAS 成功时暂停当前身份，不能清掉后来成功的新登录。

`DeviceCredentialVault` 仅提供读取、单调 `advanceIdentityFence(to:)`、原子 `replace(_:expectedIdentityGeneration:)`。相同代次 advance 保留该代次已安装的新 credential；更高代次清旧 credential；更低代次拒绝。024 必须把检查与真实 Keychain 写入串成同一原子边界，不能检查后 await 再无条件写；代次也须随 Keychain 控制记录保留。已有 DB 缺原私钥时不得静默生成新 key。业务 SQLite 不存 credential token、Apple JWT/code 或私钥。

## 比赛与控制队列

首次物理 start 须当前原 acquire + nonce fresh-held；terminal/mismatch/旧 epoch 不能开始。已成功开赛的原设备允许离线恢复同 match/recorder；网络未知本身不终结比赛。已持久或本轮学到 terminal/release 后，普通命令、recover/resume、replacement 和 callback 均重读持久门闩，只收尾原 externalToken。

`AuthorityControlService.normal` 经专用事务冻结当前云 proof witness 与原 recorder 意图；`abnormal` 先把本地 incomplete、稳定 intent、v2 command receipt/outbox 和 terminationPending 放同一事务，再 HTTP compare-release。仅保存通用 control intent 不够发送 terminate。normal 只原 recorder PoP；phone 只能用 `AuthorityHTTPRequest.opaqueRelay(...)` 原样转发原 method/path/body/Authorization/PoP。工厂只做边界检查，不重编码原 bytes、nonce 或签名。响应丢失按原业务 ID + 源设备 fresh PoP 重试。真实 WC 控制 relay 属026，与旧 peer packet/ACK 无关。

`controlQueueV4()` 持久返回原 intent、state、attemptCount、有限 issue、nextAttemptAt；首次签名结果优先，后到失败不覆盖 confirmed。`AuthorityControlService.reconcilePending()` 只处理到期 lock terminate，`LifecycleService.retryPendingControls()` 只处理其到期 lifecycle 类型；blocked 项需要对应显式动作。没有后台定时器，调用方按持久 nextAttemptAt 唤醒。auth、删除 capability、云队列各有自己的恢复入口，不混发请求。

## 云 facts、完成与历史

`CloudSessionBridge` 实现 `CloudCommitSink`。同 facade 一事务先 first receipt，再原 parent-token bytes + generation CAS，完整 facts/tombstones/raw records/token 一起提交。reset generation 阻止迟到旧 batch 复活。CloudSync 的独立 SQLite 仅为 transport 台账，不是第二业务 repository。

完整 cloud fact digest 与 legacy timelineVersion 属不同域。bridge 显式翻译 startIntent/starter/events/capture，保留旧 canonical/receipt/packet/ACK bytes；captureDigest 同实现。云 proof 专表先存，只有当前完整 facts/capture 与永久正常 release 同时匹配，才在同队列/事务调用原 completion factory。cloud-only、release-only、peer ACK 都不完成；后续更正失效旧 completion，可用新云 proof 复用既存正常 release，不重取锁。

未知云比赛需当前账号 HTTP 查询并验原 acquire，保留原 epoch，只写 `cloudHistoryV4(scope:)`，不合成 permit、不写 Match、不进录制恢复候选。这是历史恢复，不是旧 Workout/原机录制恢复。原 receipt 已 terminal 仍可授原 match 历史读取；无 receipt 整批停且 token 不进；同 ID 本机冲突整批回滚；显式 `cloudDeletionsV4(scope:)` 优先于晚到 facts。稳定 zone 可读跨 epoch 历史，旧 pending 不改绑新 scope。

`acceptDevelopmentSave` 只接受本 ledger 实际 confirmed upload/evidence + 独立开发 namespace；`acceptSDKReadback` 消费024实际 conditional SDK回读，再由 Store 按自身 policy 复验完整 manifest/parts/digests。production Bootstrap 未配置此能力。scope 比较按三个 ID UTF8 原 bytes + epoch，规范等价但 bytes 不同的 Unicode zone 不能跨 proof。

## 迁移、删除与分析

正常迁移要求本地终结状态、无 held/pending/conflict/未确认云工作。`prepareFinalCheckpoint(checkpointID: UUID)` 持久 enqueue 当前完整已确认 facts 的账号控制 checkpoint；空账号也只有 `account-checkpoint:<stableZoneKey>` 元数据，不创建假 Match。`acceptDevelopmentFinalCheckpoint` / SDK checkpoint 边界验证实际回读，`commitMigrationCheckpoint` 绑定控制 CloudRecord.recordID + digest；新机下载完整引用后才能 activate。payload UUID、控制 recordID、asset manifest ID 含义不同。已完成旧轮可开始合法新轮；旧 request 重放只返回原结果，不倒退 latest。激活响应丢失后显式 fresh 新 epoch 登录再查询原请求，不暂停已经验证的新 epoch。

丢失迁移保留后台原 requestedAt/eligibleAt，七天到期仍需新鲜 Apple 证明。`requestLostRecovery` 只针对原 acquire 的 match/lock/recorder/epoch，`terminateLost` 仅异常释放原锁；force 需另一次 fresh proof，不授旧 Workout 接管权。

`deletionSagasV4()` 重开发现原 deletion ID/capability/choices/revision；`resumeDeletion` 按原 ID 恢复后台、云、本地和单独确认的健康分项。backendDeleted 验签后才可擦 Store。`localDataProgress` 把 Store 与 transport 两个内部结果聚成一个“本地数据”结果；二者完成或明确保留前整体 finished=false。默认 `LocalTransportDeletionDriver` Unavailable，真实非空副本不能自称已删。`LocalTransportDeletionRequest` 传原 saga requestID/digest 和原 scope，026 为每 owned file 稳定派生子 ID，聚合所有 ledger catalog、024 asset staging 与 Store；保护 saga/capability/028 最小选择控制及其他账号空间。033 只证明单文件逻辑清理，永久围栏不解除；已确认 accountChanged 围栏不阻止重开重试剩余 cloud/health。Store 清除完整 normal/checkpoint proof副本，同时保留最小恢复控制。这里不声称物理介质/备份擦除。

`setAnalyticsEnabled` 默认 false；`enqueueAnalytics` 只接受有限 `AnalyticsEventV4` 指标、bounded count 与固定 app/OS/qualification 字段，稳定 ID 去重；关闭/身份变化/删除清未上传统计，不影响业务云 facts。`flushAnalytics` 用原 typed body 实际 HTTP，回包后再读开关和当前绑定。

## production peer

新 `ProductionPeerService` 与 Core `VerifiedPeerGrantV1/VerifiedPeerEnvelopeV1` 独立于 M3。必须 production fixed pin、signed localRole/remoteRole/activePhoneID、恰一 active phone 与 watch、当前 epoch/expiry/登记公钥，再验发送设备 envelope 签名。旧 missing-role grant 暂停；合法同 pair 可用新 control ID 续取同 grantID，旧结果不补签。

原 v2 packet/ACK bytes 作为 payload 不改写，v4 route/inbox/ACK 独立，换 pair 不重定向旧 pending。`ProductionPeerSyncService` 使用显式 provider/transport，默认均 Unavailable；到期暂停，每次发送在 key/SDK await 后重读 Store fence。receiver 先查询原 acquire，在同 Session 验签导入；peer 只传事实，永不制造 release/completed。SDK026负责真实 WC envelope 传输/分片与原控制 relay；ACK 原 bytes 来自持久 inbox，可按原 grant 回送，丢 ACK 由原 packet 重试再次取同 receipt。

## 024 / 025 / 026 交接入口

| 所有者 | 具体边界 |
| --- | --- |
| 024 | 实现 AppleSignInDriver、DeviceProofSigner、fenced DeviceCredentialVault；CloudIdentityProvider SDK取得当次 cloudSpaceID/稳定 zone，由当前双身份核验动作显式 admission；CloudDriver 实际 private zone/token/conditional save/asset staging回读，经现有 bridge SDK入口提交 proof。 |
| 025 | 同一 facade/Session 装配。查询 accountBindingV4（account/epoch/role/suspended）、identityGenerationV4、authAttemptsV4/pendingAuthAttemptsV4/authResolutionV4（旧knownNotFound仍unknown）、controlQueueV4、latestMigrationV4、deletionSagasV4、analyticsEnabledV4、authorityStateV4、matchingCloudSaveV4、cloudCursorV4/history/deletions。普通 snapshotV2 保留本机原事实；旧epoch历史不作可录制候选。 |
| 026 | 真账号/签名/SDK/设备验收，WC原HTTP控制relay与独立peer transport，所有ownedledger/staging删除聚合，当前身份变化停止旧actors，保留云恢复时显式新namespace；不得自动unfence旧文件。 |

`URLSessionAuthorityRelay.shutdown()` 取消网络；`SQLiteSessionRepository.close()` / `SQLiteCloudLedger.close()` 在调用方停止自己的任务后关闭文件。Session 不拥有独立后台轮询服务；UI取消订阅/调用方任务后再关闭资源。真实Apple、iCloud、Keychain、CloudKit、HealthKit、物理Workout/WC与签名安装仍未验，最低SDK编译不能替代这些门槛。
