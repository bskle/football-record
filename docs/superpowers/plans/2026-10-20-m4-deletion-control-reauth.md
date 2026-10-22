# M4 删除控制面 fresh reauthentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本任务由cloud独占下列20路径直接执行，不另派代理；产品TDD须先获root+m2对本具体计划确认。

**Goal:** 在原业务Session永久退役后，以原删除parent、原身份和原数据库恢复fresh Apple认证及精确原锁异常对账，随后重放原delete bytes，禁止创建新身份或重新录制。

**Architecture:** 三个专用purpose端点只操作现存原身份与原删除意图；server原表内持久purpose/parent/lock/session关联，Apple await前后原子校验。Core原SQLite控制行提供同parent原子准入及历史proof，AccountKit只使用原client/signer/vault/Session；普通050业务gate保持原样。新增控制类型被046/045/LocalErasure识别但不成为业务facts，026独立接线后验收。

**Tech Stack:** Node SQLite/crypto/HTTP、Swift6、既有系统SQLite3、CryptoKit、XCTest；最低iOS17/watchOS10。无新依赖、schema、工程、SDK或UI改动。

---

## 1. 登记、基线与写入边界

- sole author `/root/m4_cloud`，两位非作者 `/root`、`/root/m2_review`。
- initialbase `2cab4640ee3a375da39fdabf0f5a317600b0c263`；accepted050 `c031a15a5dfd1aa51f219770c6cee57bdc36006c`普通merge `481bb05640341ffbf60df75a66694a6a9e85e3c7`；accepted046 `f05e987b3c91fef81f34e22a588d77915a6648db`（含045）普通merge后effectiveBase `07c1b92a75d1c9998afecbfb8cb731a464b414af`。
- branch `fix/deletion-control-reauth`；tree `/Users/liam/.codex/worktrees/m4-deletion-control-reauth/20260830_足球记录`；attachment `01a157d5-d491-7062-b011-005625f415a7`，createdAt `1792474993`。作者实际核HEAD/branch/parents/clean含ignored一致。
- 仅合held026，登记target `0e7292df9b1f4eef2edc31d3d7954eee92ceb892`；不自行merge/push/archive，不推进dev/release/main。原输入32+6与root裁定见树外`NATIVE-026/deletion-control-reauth-*.json`。
- database.mjs/schema、旧receipt.mjs、Package/App/project/Presentation/SDK、旧业务gate均不写。原表不足以严格持久识别purpose时，先给实证请求最小增量所有权，不猜测恢复。

下列为唯一20路径；新文件按职责拆分，现有文件只做所列窄接缝：

1. `backend/src/deletion-reauth.mjs`
2. `backend/src/device-auth.mjs`
3. `backend/src/codec.mjs`
4. `backend/src/http.mjs`
5. `backend/src/authority.mjs`
6. `backend/src/lifecycle.mjs`
7. `backend/test/deletion-control-reauth.test.mjs`
8. `native/Packages/MatchCore/Sources/MatchStore/DeletionControlAuthenticationModels.swift`
9. `native/Packages/MatchCore/Sources/MatchStore/DeletionControlAuthenticationPersistence.swift`
10. `native/Packages/MatchCore/Sources/MatchSession/DeletionControlAuthenticationCoordinator.swift`
11. `native/Packages/MatchCore/Sources/MatchStore/CapturePersistence.swift`
12. `native/Packages/MatchCore/Sources/MatchStore/LifecycleStatePersistence.swift`
13. `native/Packages/MatchCore/Tests/MatchStoreTests/DeletionControlAuthenticationTests.swift`
14. `native/Packages/MatchCore/Tests/MatchSessionTests/DeletionControlAuthenticationTests.swift`
15. `native/Modules/AccountKit/Sources/AccountKit/DeletionControlAuthenticationService.swift`
16. `native/Modules/AccountKit/Tests/AccountKitTests/DeletionControlAuthenticationTests.swift`
17. `docs/superpowers/plans/2026-10-20-m4-deletion-control-reauth.md`
18. `docs/native/tasks/NATIVE-052.md`
19. `docs/native/validation/NATIVE-052.md`
20. `docs/native/contracts/m4-account-lock-cloud.md`

## 2. 固定常量、预算与编码

`purpose = "deleteControl.v1"`；version恒1。所有JSON沿原`canonicalJSON`/`AuthorityWire` sortedKeys、无斜线转义、严格已知keys；重复key、非canonical、未知version/enum/额外field均拒绝。原auth/delete/lock DTO、旧receipt domain/bytes不改。

| 项 | 固定规则 |
|---|---|
| request/response | 每HTTP正文≤16384 bytes；response≤65536；原held receipt≤16384；新control signed envelope≤16384 |
| ID/key/time | wire ID复用原1...128 ASCII grammar；公钥32bytes、签名64bytes、capability32bytes base64url canonical；SHA256小写64hex；epoch1...JS-safe整数、秒0...JS-safe整数 |
| original scope | 本地三ID以原UTF8 bytes比较，epoch精确；不Unicode规范化；server仅拥有account/cloud，不伪证本地zone |
| challenge/proof | challenge及Apple fresh窗口300秒；request proof issuedAt与server偏差≤60秒；nonce为原ID语法且不得重用 |
| control session | server生成`dc.<UUID>`，300秒有效；独立reauth expiresAt=`verifiedApple.issuedAt+300`，不随recover延长；appleRevocation阶段不新建reauth material |
| server目的控制 | 每parent最多64个challenge+auth attempt（合计），每account最多256个；单内部purpose envelope≤32768bytes、每parent总新控制payload≤4MiB；同SQL写前验，不截断/自动清理历史 |
| client控制 | 单新record≤65536bytes；每parent≤64attempts、全库≤256attempts、≤64parent envelopes、总新控制rows≤512/总payload≤16MiB；写前同SQL验，超限typed unavailable且原bytes保全 |

signInput恒`UTF8(domain + "\n") + canonicalJSON(bodyWithoutDeviceProof)`，非裸JSON重签：

| 用途 | 固定domain |
|---|---|
| challenge请求device proof | `football-record.deletion-control.challenge.v1` |
| auth请求device proof | `football-record.deletion-control.authenticate.v1`；签名body另加虚拟`challengeSHA256`，不发送该虚拟字段 |
| recover请求device proof | `football-record.deletion-control.recover.v1` |
| server control证明 | `football-record.deletion-control-auth.v1`，沿原固定receipt Ed25519 keyset验签 |
| absence HMAC | `football-record.deletion-control.absence.v1`，绑定parentID/digest/authID/device/key；与普通auth absence隔离 |
| 内部record ID派生 | `SHA256(UTF8("football-record.deletion-control-record.v1\n") + canonicalJSON([kind,parentID,parentDigest,childID]))`；ID为`dcp.`/`dcs.`/`dck.`+64hex |

这些域版本是新增目的；不能重释普通device.challenge/auth-recover/pop或旧authority receipt。

## 3. 专用HTTP DTO闭合字段

三个端点分别为`/v1/accounts/delete/reauth/challenges`、`/apple`、`/recover`。正文仅POST body；capability、Apple字段、Bearer、响应body绝不URL/日志/持久JSON。

共同字段`C`：`version,purpose,requestID,deleteRequest,deleteDigest,accountID,deviceID,devicePublicKey,keyID,activationEpoch,cloudSpaceID,recoveryCapability`。

- `deleteRequest`是原canonical delete对象，精确keys仍`version,requestID,reauthenticationID,recoveryCapabilityDigest`；重编码必须等于客户端原intent.canonicalRequest；`deleteDigest`必须等于其SHA；cap原值只用于恒时hash比较，不保存。
- `keyID`必须等于公钥原bytes hash；原device必须已存在、原active phone、key/account/epoch/cloud全部匹配。不存在绝不能走nextEpoch/newDevice/newAccount。
- challenge exact keys=`C + issuedAt,nonce,deviceProof`。`requestID`为稳定challenge request ID。验证原device目的签名与freshness，生成稳定challenge；此时不预留server parent、不创建session。返回`version,purpose,requestID,challengeID,expiresAt,challenge`；已消费/过期则同keys去challenge加`status`(`consumed|expired`)。
- apple exact keys=`C + challengeID,identityToken,authorizationCode,deviceProof`；`requestID`为稳定auth request ID，未知后只recover原ID，不重POST单次code。Apple验证在SQL外；设备proof同时绑定challengeSHA256与完整parent字段。只有fresh verifiedApple issuer/subject派生account等于原account后才进current tx。
- recover exact keys=`C + authRequestID,authRequestDigest,issuedAt,nonce,deviceProof`；`requestID`为本次查询ID，`authRequestID/digest`为原immutable attempt。原device目的proof+cap共同认证；不要求旧Bearer仍有效，不重新创建身份或刷新旧code/TTL。

成功返回exact keys=`authorization,originalAcquire,credential`，后两者明确JSON null或对象；credential不持久，必须与authorization里session claims/tuple完全相等。`originalAcquire`为原canonical signed held receipt对象，不是重签或手写pin。

新authorization是`{body,signature}`。body exact keys：

```text
version,purpose,environment,keyID,proofID,requestID,requestDigest,
parentRequestID,parentDigest,recoveryCapabilityDigest,
accountID,deviceID,deviceKeyID,activationEpoch,cloudSpaceID,
result,stage,issuedAt,expiresAt,sessionID,
reauthenticationID,reauthenticationExpiresAt,lockState,lock
```

`keyID`为server receipt key，`deviceKeyID`为原device key。`requestID/digest`恒原auth attempt，recover ready返回首次原proof bytes；closing proof也绑定原attempt，不投射业务。

- result有限`ready,knownAbandoned,knownExpired,knownRevoked,parentUnavailable,lockMappingUnavailable`；stage有限`unreserved,requested,lockReconciled,appleRevocation`。
- sessionID/reauthenticationID/reauthenticationExpiresAt/lock可null，编码必须显式null。`expiresAt`为control session expiry；closing proof sessionID=null、expiresAt=issuedAt，不安装vault。
- `lockState=none|pinned|unavailable`；pinned时lock exact keys=`matchID,lockID,recordingDeviceID,activationEpoch,acquireRequestID,acquireRequestDigest,acquireReceiptDigest`；none/unavailable时lock=null，不将unknown伪装none。
- parent已backendDeleted时只返回既有delete-status语义`{status:"backendDeleted",receipt:<原receipt>}`或`{status:"receiptExpired"}`；cap只查原结果，不授权建session。Service以原delete verifier验原receipt，交026原acceptDeletion流程；未知/过期不退回generic auth。

## 4. Server原表purpose持久与所有消费者

不改DDL/user_version，采用严格内部envelope；不是根据路径/requestID前缀猜认证所有权。

| 原表 | 新用途与不变量 |
|---|---|
| requests | challenge request ID：operation=`deleteControlChallenge`，result存version/purpose/原parent canonical+digest/capHash/tuple/challengeID（无cap原文）；auth request ID：operation=`deleteControlAuthentication`，result存首次authorization+原acquire（无credential/token）；派生dcp record：operation=`deleteControlParent`，固定parent+tuple+lock pin；dcs record：`deleteControlSession`固定session→parent/auth关联；dck record：`deleteControlLock`固定一个明确确认后的abnormal requestID/digest。每个record保持strict envelope和原request_digest CAS |
| challenges/challenge_requests | 复用原nonce/challenge/消费行；通过challenge_requests JOIN requests精确读取purpose。ordinary challenge/auth遇control metadata拒绝，control遇ordinary拒绝。任何同ID异purpose/digest都冲突 |
| auth_records | public_result为strict version/purpose envelope，含原control result及原parent关联；普通旧格式分支机械兼容，未知/坏新格式不得fallback普通。authRequestID+device原PK保持 |
| sessions/nonces | 新`dc.<UUID>` control session与auth_records+dcs同事务发布；purpose授权必须两个记录/签名proof/tuple一致。dc marker仅用于缺metadata时fail closed，绝不用marker授予权限。已有ordinary/watch session行为不变 |
| auth_absence_fences/auth_recovery_nonces | 新HMAC域绑定原parent/auth/device/key，recover missing以fresh purpose proof关闭原attempt；不可把普通404/401/timeout当可信absence |
| deletions/reauthentications | original client intent absent→requested的currenttx CAS；requested/lockReconciled只更新同原parent mutable reauthID；fresh code+verifiedApple仅原transient map；appleRevocation只发原目的session，不再revoke、不倒退stage |

同事务检查`requests`/challenge/auth global ID冲突；新内部key撞到普通request也拒绝，不覆盖。查找session/challenge关联出现多行/无法严格解释，保全并拒绝。所有bytes预算在INSERT/UPDATE/COMMIT之前算；内部meta绝不带Apple subject/code/token或cap原值。

必须逐项接线的消费者：codec严格字段/routes、HTTP专用dispatch、ordinary challenge/checkChallenge/auth/recover隔离、control recover、auth_records输出、authenticateRequest、authority write/liveStatus/terminate、lifecycle delete/current parent check、backendDeleted cleanup。普通旧表中无purpose metadata时原普通路径保持；任何带dc session marker或新purpose metadata的损坏/缺失不能转普通权限。

## 5. 原parent预留、Apple await与幂等

1. challenge前证明原account/device/key/epoch/cloud仍存在，cap hash等于原delete对象；已有pending必须同ID/digest/cap且stage合法。仅暂存challenge，不创建account或server parent。
2. fresh Apple返回后在BEGIN IMMEDIATE内重验同tuple/purpose/challenge/cap：无pending则为原client canonical intent INSERT requested；有pending只接受同parent，不同pending/已删/缺身份均拒绝。冻结当时实际active lock pin；无锁明确none，缺实际映射为unavailable。
3. requested/lockReconciled分支原子创建同tuple reauthID并更新原row的mutable ID；stage appleRevocation只恢复delete-only控制凭证。transient材料仅调用原verifiedApple/code协议，不保存任何秘密。
4. sessions/auth_records/dcp/dcs/首次result同一COMMIT，control session原tuple、短TTL；COMMITlost以原purpose recover返回原canonical proof与同session token（原tokenFor稳定推导）。不再消费code/challenge，不重建parent或更新epoch。
5. ready proof过期或server transient材料丢失不能recover变fresh。原delete返回reauthenticationRequired后明确新Apple流程和新稳定attempt；unknown attempt先recover原ID。knownAbandoned是已关闭该原attempt的服务事实，不是历史从未commit。
6. backendDeleted当前缺account/device时，cap仅查原delete receipt；receiptExpired/缺receipt/401/timeout都保留，不调用generic auth。原delete intent中旧reauthID、原digest/cap语义始终不变。

## 6. 原锁proof、明确确认与受限旧端点

正常本机known held/terminationPending仍须按旧显式异常流程，在创建Saga/永久freeze之前处理；不改createDeletionSaga的拒绝。不假定手机知道Watch当前锁。

Server在原parent reserve/currenttx从active_locks取实际tuple，并从原requests中查唯一operation=acquire/result=held的原receipt：验canonical、固定receipt签名/key/env、行requestID/digest、account/epoch/match/lock/recorder全匹配。新reserve同tx固定；旧requested未有pin仅能用requested之前签发且仍当前的原held证据，缺失/多义/时间不合理保留unavailable。requested后的acquire已被原deletion guard禁止，pin不得改成别的锁。

新control proof签名绑定pin+原held raw SHA；客户端既有VerifiedAuthorityReceiptV1再验原held receipt，Store自身固定trust同tx复验并保存原raw。无本机Match不创建它。既有本机acquire存在时必须逐raw一致。live-status使用已存pin与fresh nonce，验既有VerifiedLiveLockV1；不能从配置、UI或未验JSON造pin。

control session只允许：

- 原delete（body逐bytes）与其原request query。
- 原pin的`POST /v1/locks/status`（含同acquireID/tuple、fresh nonce）；可查pin的一个原acquire request。
- 用户明确确认、已在原SQLite持久confirmationID/time/parent/tuple后，一个稳定abnormal requestID/digest的`POST /v1/locks/terminate`及其query。mode必须abnormal；server首次dck绑定该ID/digest，换ID也拒绝。

所有其他路径（含normal/acquire/Watch/migration/analytics）、不同lock/recorder/epoch/parent或替换pin均拒绝。每次server事务重查parent/tuple/pin；首次删除只比对原活动锁，原firstreceipt同ID重放；返回历史receipt不证明当前无锁，delete仍检查当前activeLock。

新Core控制coordinator不调用旧business-gated prepare/accept，不放宽applyCommitV2或validateAccountBusinessWriteV4。仅持久明确确认、原canonical abnormal intent、已验证live/releasedAbnormal firstproof；不造新Match/event/command/outbox/capture/permit，不派gateway，不称normal/completed。结果保持原recorder/epoch；真实映射缺失typed blocked。026通过既有`LifecycleUserAction.abnormal(matchID)`显式路由，不由renew/status自动确认。

## 7. Core公共typed边界与原SQL门

新文件定义单独optional capability，原AccountLifecycle/Authority协议required funcs不变。类型命名如下：

```swift
public struct DeletionControlContextV1: Sendable {
  public let saga: DeletionSagaV4
  public let binding: AccountBindingV4
  public let originalScope: CloudScopeV1
  public let publicKey, keyID: String
  public let identityGeneration: Int64
}
public struct DeletionControlAttemptV1: Codable, Sendable {
  public let parentRequestID, parentDigest, challengeRequestID: String
  public let originalScope: CloudScopeV1
  public let binding: AccountBindingV4
  public let publicKey, keyID: String
  public let identityGeneration: Int64
  public let authentication: AuthAttemptV4
}
public struct DeletionControlLockConfirmationV1: Codable, Sendable {
  public let parentRequestID, parentDigest, confirmationID: String
  public let confirmedAt: Int64
  public let intent: ControlIntentV1
  public let acquireRaw: Data
}
public enum DeletionControlLockStateV1: String, Codable, Sendable { case none, pinned, unavailable }
public enum DeletionControlOutcomeV1: Sendable {
  case ready(reauthenticationID: String?, lockState: DeletionControlLockStateV1)
  case needsFreshAuthorization, unresolved, knownAbandoned, knownExpired, knownRevoked
  case parentCompleted(VerifiedAuthorityReceiptV1), parentUnavailable, lockMappingUnavailable
}
public enum DeletionControlIssueV1: String, Codable, Sendable {
  case unresolved, needsFreshAuthorization, parentUnavailable, lockMappingUnavailable, identityChanged, stopped, capacity
}
```

`VerifiedDeletionControlAuthorizationV1`为非Codable、private init的固定域验签结果，公开raw及第3节已逐字段定义的只读body；只能由`verify(raw:expectedParent:expectedAttempt:trust:)`重建。其body按第3节24个闭合字段显式encode/decode nullable字段，无任意字典或verified布尔入参。上述Context的memberwise init保持internal；attempt/confirmation的init和decode必须重验字段/原bytes/预算，不依赖synthesized decode跳过不变量。

`Context`字段固定parentRequestID/digest、originalScope、原完整AccountBinding、原current auth publicKey/keyID、identityGeneration、原intent/cap只在受控context内供请求；不Codable/无公开verified bool。原key来自auth-current→原auth-attempt+固定trust的原receipt，不从caller配置创造；未知旧映射拒绝。

Repository/Coordinator均为独立新协议，概念签名固定如下（Coordinator去V4后缀，由Session own clock提供at）：

```swift
func deletionControlContextV4(parentID: String, expectedIdentityGeneration: Int64) async throws -> DeletionControlContextV1
func deletionControlAttemptV4(parentID: String, authRequestID: String) async throws -> DeletionControlAttemptV1?
func saveDeletionControlAttemptV4(_ attempt: DeletionControlAttemptV1) async throws
func acceptDeletionControlAuthorizationV4(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, originalAcquire: Data?, expectedIdentityGeneration: Int64, at: Date) async throws
func resolveDeletionControlAttemptV4(parentID: String, authorization: VerifiedDeletionControlAuthorizationV1, expectedIdentityGeneration: Int64) async throws
func saveDeletionControlLockConfirmationV4(parentID: String, confirmation: DeletionControlLockConfirmationV1, expectedIdentityGeneration: Int64) async throws
func acceptDeletionControlLiveLockV4(parentID: String, proof: VerifiedLiveLockV1, expectedIdentityGeneration: Int64, at: Date) async throws
func acceptDeletionControlAbnormalResultV4(parentID: String, receipt: VerifiedAuthorityReceiptV1, expectedIdentityGeneration: Int64) async throws
```

新coordinator只操作原store和仅`_authority-account` mutex（不额外取match锁），无network await。每次SQL事务自己读取并重跑原Saga构造不变量、control_intents原bytes/hash、cap hash、scope原UTF8、原binding/key/environment/current expected gen，要求!backendDeleted且backendReceipt=nil/local未completed。锁await后进入Store仍由事务查当前门；不依赖caller传Saga或布尔值。

新kind使用`lifecycle_steps_v4`的`delete-control-v1:<subkind>:<ASCII ID>`，subkind有限`parent,attempt,confirmation,proof`。attempt关联/firstproof不可变，后来的可信closing resolution独立保留、不覆盖首次proof。重复异parent/digest/tuple/raw冲突；beforeCommit rollback、COMMITlost readback保持原bytes。post-backendDeleted只能读历史，不返回ready也不刷新vault。

新控制不写account_binding/auth-current/identity-generation/business/capture，不调用普通resolveTerminalAuthentication。它只允许对原parent恢复，不开放普通signIn/registration。

## 8. 046/045/LocalErasure及当前零兼容

共享一个新kind严格只读validator：原canonical/checksum、id/subkind/parent raw关系、固定proof签名与首次receipt。对历史proof不要求旧gen仍为current或parent仍未完成；否则会阻合法045 witness。未知subkind/version、无法关联parent、损坏proof拒绝且不写quarantine。

046全inventory调用该validator后仍枚举完整capture/command/outbox；输出和旧raw事实不因控制行改变。045 witness和mutating LocalErasure同样校验新kind，但仍只清原34业务表+normal-intent/migration-checkpoint两witness；新kind最小控制与原Saga/cap保留，明确不含业务canonical副本。新auth request ID不得撞原control_intents/auth/watch请求及新purpose语义ID；普通loader不误采新prefix。045完成后新control mutation必因backendDeleted/current门拒绝，不能在零witness后添auth业务事实。

## 9. AccountKit服务、unknown及owned stop

```swift
public actor DeletionControlAuthenticationService {
  public init(client: AuthorityClient,
    repository: any DeletionControlAuthenticationRepository,
    coordinator: any DeletionControlAuthenticationCoordinator,
    scope: CloudScopeV1, apple: any AppleSignInDriver,
    currentScope: @escaping @Sendable () async throws -> CloudScopeV1 = { throw AuthorityError.unavailable })
  public func renew(parentID: String, authRequestID: String, challengeRequestID: String, expectedIdentityGeneration: Int64) async throws -> DeletionControlOutcomeV1
  public func recover(parentID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws -> DeletionControlOutcomeV1
  public func lockStatus(parentID: String, expectedIdentityGeneration: Int64) async throws -> VerifiedLiveLockV1
  public func confirmAbnormal(parentID: String, confirmationID: String, requestID: String, confirmedAt: Date, expectedIdentityGeneration: Int64) async throws -> VerifiedAuthorityReceiptV1
  public func stopAndJoin() async
}
```

`Outcome`有限ready（只读reauth/lock状态）、needsFreshAuthorization、unresolved、knownAbandoned、knownExpired、knownRevoked、parentCompleted（原verified delete receipt）、parentUnavailable、lockMappingUnavailable。不是AccountAuthentication，不admitIdentity。scope callback每次观察当前原身份/云域，默认unavailable；不创建SDK provider、Runtime、Session、DB、signer或vault。

每次source/Apple/signer/HTTP/SQL/vault await后先查service lifetime/stopped与原SQL context，再作下一外部mutation；借用repo identity token必须与原coordinator精确同facade，scope原bytes相同。call已有attempt时只recover；准备attempt持久后才auth POST。404/401/retryable/timeout仅unresolved，不换ID/重POST code。可信closing proof只关原attempt，不advance gen/suspend binding。

SQL接受ready proof在先，同一原vault `replace(同account/device/key/epoch credential, expectedIdentityGeneration:)`在后；前后检查原parent/gen/lifetime，再返回。SQL与vault不是一笔事务：原owner串行reauth/resume并join整个任务，vault CAS防旧gen；lost response只能从原proof/recover完成同scope写，不隐藏正面SQL。backendDeleted或final stopped后不刷新vault。

所有public call由actor持有独立Task；caller取消传播到owned task，退出前join，cancel-insensitive late响应也过永久stopped/lifetime门。stopAndJoin同步封新entry、cancel并join owned task，清引用；不关闭借用Session/vault/HTTP/Cloud/delete transport。026 business quiesce不关控制服务，finalclose先stop/join再关DB；owner不得反调context.shutdown。原renew与abnormal现有UI action接线归026，不在052改App/Presentation。

## 10. TDD与提交slice

仅计划四文档提交时不运行产品、不预填测试通过。收到root+m2计划确认后，直接按下面顺序实施；每个slice先compiler/API红，再目标runtime真实行为红，fixture/工具错误独立日志，不充作安全红。

### 052.1 Server专用purpose与原parent

- [ ] 新Node测试先构造原登录/原cap/原delete canonical：旧普通凭据过期、原pending保留；调用专用challenge/auth/recover，原代码缺API为compiler/接口红；用真实HTTP旧generic路径复现会建新身份反例，安全红单独保存。
- [ ] 用原server真实SQLite+controlled Apple verifier/revoker，覆盖first-dispatch absent→原requested、existing exact、不同pending/缺身份零新账号/epoch、Apple await后并发删除currenttx拒绝、appleRevocation不重revoke。
- [ ] 实现原表strict purpose、固定domains/budgets、dc marker+auth_records+dcs双向核验；ordinary/control跨purposeID拒绝、缺meta不回落普通。
- [ ] 运行focused Node，beforeCommit/COMMITlost/backend reopen/knownAbandoned/401/404/timeout/TTL/code消耗均保留原firstbytes；读取DB/log扫描无Apple/cap/token秘密。
- [ ] 精确暂存backend7paths，普通commit `feat: add deletion control authentication`，body记录实际命令和真实服务未验。

### 052.2 原Session/SQLite控制门及消费者

- [ ] 写真实同一SQLiteSessionRepository+MatchSession tests，先retireBusiness，正常050五mutation仍拒绝；新control API缺失红与runtime gate红分开。
- [ ] 用真实签名control proof/原held receipt、beforeCommit/COMMITlost、原authority mutex delayed reply和两handle读回测试，不用memory fake冒durability。
- [ ] 实现新Models/Persistence/Coordinator与同SQL原parent/key/gen/CAS；不改任何旧gate、canonical编码或DDL。
- [ ] 046 inventory before/after raw一致；045 witness+LocalErasure保留新控制kind、仍清34表/twowitness；坏kind/孤儿/错parent/signature typedblock无quarantine；postbackend/localcompleted新auth写零。
- [ ] 运行原Core全suite并提交`feat: persist parent-bound deletion authentication`；不把focused数与full相加。

### 052.3 原锁明确确认与原HTTP端到端

- [ ] Node真实server先持锁，再使原delete留下requested/activeMatchExists；过期原credential，经专用fresh认证得到server原held证明。确认前零terminate，明确确认后仅原pin abnormal+query，原delete bytes继续。
- [ ] wrong match/lock/recorder/epoch、normal/acquire/newparent/不同confirm request、状态await中锁替换/parent完成都拒绝；原COMMITlost/reopen原receipt重放。
- [ ] AccountKit使用同原client/signer/vault、原SQLite/Session，service从server返回的原receipt验pin后持久；无本机Match不造Match，unknown映射typedblock。旧business仍永久retired，0 gateway/0新permit。
- [ ] 反例断言采用原state/原bytes，而不是镜像私有条件：

```swift
let before = try await repository.captureInventoryV4()
try await session.retireBusiness()
let result = try await deletionControl.renew(parentID: parentID,
  authRequestID: "delete-auth-original", challengeRequestID: "delete-challenge-original",
  expectedIdentityGeneration: generation)
guard case .ready = result else { return XCTFail("expected control-ready result") }
let afterGeneration = try await repository.identityGenerationV4()
let afterBinding = try await repository.accountBindingV4()
let afterInventory = try await repository.captureInventoryV4()
XCTAssertEqual(afterGeneration, generation)
XCTAssertEqual(afterBinding, originalBinding)
XCTAssertEqual(afterInventory.map(\.binding.matchID), before.map(\.binding.matchID))
```

此snippet的repository/session/deletionControl来自新test内真实harness；每个harness只开一个原SQLite facade与具体Session，签名与HTTP由原Node控制fixture产生。

- [ ] final stop/cancel/late source/Apple/signer/HTTP/Store/vault分别hold；仅本实例owned tasks被join；原borrowed资源不close；SQL正面事实不被postawait stopped吞掉。
- [ ] 提交`feat: resume deletion through original control facade`；全Node/Core/AccountKit后冻结source。

## 11. 最终命令、证据与验收

Host实际命令（每轮使用独立/tmp scratch、树外logs/inputs；历史日志不覆盖）：

```bash
node --test backend/test/deletion-control-reauth.test.mjs
node --test backend/test/*.test.mjs
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE052-core
swift test --package-path native/Modules/AccountKit --scratch-path /private/tmp/football-record-NATIVE052-account
```

AccountKit跨模块HTTP test沿既有Support找repo root启动真实Node，new Store/Session forward均原对象；不修改Package或Support。如现support接缝不足，只在本owned新test定义helper，不写共享test资源。

四fresh minimum product build：`xcrun swift build --package-path native/Modules/AccountKit --target AccountKit --sdk <xcrun --show-sdk-path> --triple <下表> --scratch-path <独立/tmp>`；已有未改旧warnings保留原输出，不能扩大旧模块修复。实际argv固定于source-commands.json，SDK/工具版本/输入before/post另存。

| SDK | triple |
|---|---|
| iphonesimulator | arm64-apple-ios17.0-simulator |
| iphoneos | arm64-apple-ios17.0 |
| watchsimulator | arm64-apple-watchos10.0-simulator |
| watchos | arm64-apple-watchos10.0 |

保留六Git输入、原红绿/fixture失败、版本、全部runtime Sources/Package/Tests/support/Git mode/blob/hash与每command before/post0，source/final精确SHA、同源scope/links/diffcheck。root+m2 source双PASS后只两卡收尾，产品/测试/plan/合同保持source bytes；final再双审，由root普通merge held026。新数量以实际单轮为准，不填预计数。

本任务为本机控制协议/SQLite+HTTP软件，不执行真实Apple/Keychain/iCloud/CloudKit/Health/WC/用户账号/设备/部署；四SDK只编译。生产provider默认Unavailable不变；026还负责真实SDK装配、原renew/abnormal UI路由、全部owned控制任务join与整体删除验收，不以052单叶通过称M4完成。


## 后端 checkpoint 预审约束补充

固定 `18dcd916c2290c421ec0f324a8c2534d9f0f1e04` 是首个 backend slice，未通过整体源码审。原 closing 状态与当前授权分开验证：过期或撤销仍须原 signed authorization、原 requests/auth_records/parent/session 元信息和所有 scope/expiry claims 相符；缺坏不能签新 knownRevoked。原 ready bytes 不覆盖，首次 expired/revoked resolution 用既有 requests 的 `deleteControlResolution` 私有 kind；ID 为 `dcr.` 加固定 `football-record.deletion-control-record.v1` 域的 `["resolution", parentID, parentDigest, authRequestID]` SHA256。该行闭合字段为原 parent envelope + `authRequestID, authRequestDigest, readyDigest, authorization, originalAcquire`，readyDigest 是原 signed ready envelope canonical bytes 的 SHA256，originalAcquire 明确 null。原 wire、旧 receipt domain 与 schema 不变。

每 parent 4MiB 计入全部新控制 payload，含 requests、auth_records 副本、原 session/reauth/challenge 与其索引、专用 parent nonce/absence fence 和 PoP nonce；以每列 UTF8/BLOB 实际字节、INTEGER 8 bytes、NULL 0 bytes 核算，另保留32KiB单 envelope及64/256 challenge+auth计数。它不是 SQLite页/文件大小承诺。所有相关 mutation 仍在原 SQL事务，nonce/副本插入前检查候选总量；非 attempt session/首 closing 不因恰好64个 attempt误拒，但仍计 payload。未知私有 kind/列结构保留拒绝；原普通 nonce 分支机械兼容。旧 challenge_requests 全局ID与原 ordinary absence fence 不可被新 purpose重分类。


## 2026-10-22 恢复及只读接缝具体声明

原工作目录已由启动清理移除；恢复快照 `08a387fae82c56837585e8d389b61f97356f35e7` 的六个未提交文件已与最后204输入清单逐字核对，在原 `fix/deletion-control-reauth` 分支的新受管目录 `/Users/liam/.codex/worktrees/m4-deletion-control-reauth-resume/20260830_足球记录` 恢复。当前唯一作者为 `/root/m4_deletion_resume`；初始base、effectiveBase、20路径和held026目标保持原登记。新attachment为 `01a16137-5f80-7890-ae1f-6e9ef60cd196`。未修改或删除原快照、未改写历史。

root已批准在新增optional repository中加入以下历史只读声明，供unknown恢复、COMMIT响应丢失读回和原锁明确确认使用：

```swift
func deletionControlAttemptsV4(parentID: String) async throws -> [DeletionControlAttemptV1]
func deletionControlAuthorizationV4(parentID: String, authRequestID: String) async throws -> DeletionControlAuthorizationRecordV1?
func deletionControlLockConfirmationV4(parentID: String) async throws -> DeletionControlLockConfirmationV1?
public struct DeletionControlAuthorizationRecordV1: Sendable {
    public let authorization: VerifiedDeletionControlAuthorizationV1
    public let originalAcquire: Data?
    public let resolution: VerifiedDeletionControlAuthorizationV1?
}
```

这些读取只返回已按原parent、原attempt、固定trust和严格闭合kind重验的历史bytes；不代表当前授权、ready或vault写入准入。所有活动操作仍须原 `deletionControlContextV4` 的current SQL门。原protocol required API和普通业务退休门保持不变。独立Session coordinator只取原 `_authority-account` mutex，时间从原Session clock取得，不进行网络、业务mutation或新建facade。


## 2026-10-22 Core 独立审阅修复

`50463f4` 的317/0是修复前单轮证据，不能代表以下三项已关闭。新增四项实际回归在该产品源码上4 tests/6 failures，修复后同命令4/0。

- 原ready响应整段TTL内丢失时，固定trust验证的首次knownExpired/knownRevoked可直接作为原attempt第一条closing历史记录；不构造ready、不安装credential、不修改binding/generation。若已有ready，则closing仍另存resolution，原first bytes不覆盖。首次knownAbandoned仍仅为原attempt关闭事实，不等于从未commit。
- 新attempt的auth/challenge语义ID在同SQL内检查原Watch attempt及所有auth/watch receipt/admission控制键；写完parent+attempt后、COMMIT前再跑完整严格validator。碰撞零新控制行，原Watch bytes保留，不能提交后才把完整inventory/erase读坏。
- 原attempt一旦已有可信closing或resolution，活动ready接受在同一SQL门拒绝，即使相同ready签名/TTL仍有效；历史读取保持原ready+closing，不能借幂等重放刷新vault。

本批Core验证脚本的207项保守输入包含未提交的AccountKit两个占位/测试文件，它们不被Core package命令消费；精确Core Git输入以checkpoint逐项限定。AccountKit仍在独立TDD阶段，不能将本批Core结果声称为whole052。


## 2026-10-22 AccountKit owner 与 challenge 丢响应阶段

所有public renew/recover/status/explicit-abnormal由本实例独立owned Task持有，并以FIFO串行覆盖当前身份source、Apple、signer、HTTP、原SQL、同vault CAS和最终复验。caller取消传播后仍join原任务；stopAndJoin永久封entry、取消并join所有owned尾部，不关闭借用Session/repository/vault/HTTP。026外层仍须串行该服务与原Lifecycle.resume，finalclose先join控制服务再关闭原DB；SQL与vault不称原子事务。ready SQL后再次读同attempt当前firstproof/resolution，已closing不允许vault刷新。

仅在专用challenge HTTP响应发生明确networkConnectionLost、此lexical流程尚未调用Apple/持久auth attempt/派发auth POST时，可在原parent/gen/独立scope及同authID仍无attempt复验后返回既有needsFreshAuthorization。它只要求用户下一次明确采用新的challenge/auth IDs；本服务不自动生成它们，不关闭旧challenge、不称knownAbandoned或从未commit。401/404/timeout/其他未知响应保留unresolved；一旦auth attempt存在，renew只恢复其原ID，任何网络错误都不能回退此分支。新TDD以真实server已保存challenge后的丢响应复现该区别，不改变server首次request bytes、wire或预算。
