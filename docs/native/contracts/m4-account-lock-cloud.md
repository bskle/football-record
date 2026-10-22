# M4 账号、权威锁、私有云与生命周期合同

状态快照：2026-10-20，[GIT-008](../tasks/GIT-008.md)登记时`dev=origin/dev=e3e4b09d79c1f2556b8648c214f6c3c148ca8cd1`，后续纯文档合并会推进Git HEAD。025 source4ec78e8 / final1c09eb1已whole双审、actual e3同步，root相关63host/2最低SDK/4UI与作者615/12SDK/6App分层；023及034～036历史交付保留GIT-007。024 finala8ad011（181host/8最低SDK）和037 final55718f4（69host/4最低SDK）已双审、hold026；026依赖接入及Watch合并类型修复完成，本地整包仍实现中且未组合验收；038独立边界未交付/未入dev。真实SDK/账号/设备/签名配置/部署及026组合擦除留后验，production Unavailable，M4未完成。以下合同正文、wire与证明边界不变；依据仍为[产品](../../0-产品方案.md)、[母计划](../../superpowers/plans/2026-10-15-native-development.md)、[M3合同](m3-durable-sync.md)及[M4计划](../../superpowers/plans/2026-10-18-native-m4.md)。

## 1. 事实源和实现层次

| 边界 | 唯一职责 | 不可代替的证明 |
|---|---|---|
| 现有 MatchCore / MatchStore / MatchSession | 本地事件事实、完整 capture 修订、命令回执、串行写入 | 一条 UI 提示或网络 callback 不是事务保存 |
| 最小 authority | Apple 匿名身份、激活 iPhone、登记 Watch、活动锁、生命周期与匿名计数 | 不读取或验证用户 CloudKit 私有库的比赛内容 |
| CloudSync / CloudKit private zone | 完整非健康业务事实、检查点、tombstone、冲突 | peer ACK、后台 release receipt 不能证明云保存 |
| AccountKit | 严格控制 DTO、HTTP、签名验证、Apple / 凭据边界 | 解码 JWT 不等于验证 Apple 身份 |
| HealthKit / DeviceSync | 原记录设备的采集与已授权 peer 传输 | WC 配对、checksum 或 iCloud 登录不等于 App 账号认证 |

021已交付 Node `v22.23.1` 内置 HTTP / crypto / `node:sqlite` 的文件持久本地 reference authority，默认只监听 loopback。实际 Serverless 供应商、原子持久存储适配、TLS、密钥管理、部署与备份恢复均在 026 实际服务门槛验收；本地 SQLite 或 Experimental API 不称为已部署生产服务。022及023同facade本机软件已交付；当前591整轮含Node161/Core257/Cloud80/Account54/Presentation39，非早期选测累计。034仅本机ops/TLS fixture/备份点恢复，不证明持续durability/RPO/epoch高水位或生产部署。024客户端SDK和025工程/UI已正式独立推进，未final/未入dev；028保持独立SDK候选，026真实SDK/账号/设备及全owned ledger/staging/Store聚合验收未完成。

生产 Bootstrap 的 permit、workout、transport、peer trust、CloudKit 和 auth 默认 unavailable；只有逐项通过相应真实验收后由唯一工程所有者显式装配。开发服务、开发签名 key、测试鉴权 factory、开发云 driver 只可进入独立 development namespace，UI 持续显示“开发模拟锁 / 开发配对 / 开发云演练”。不能通过设置一个 URL、注入 permit provider 或删除 guard 开放生产。

023 本地HTTP纵向使用 development authority adapter：先真实HTTP验证并持久development域控制proof、fresh held状态，再为原intent返回既有精确 `DevelopmentStartFixture.permit(for:)`，不把Node开发receipt直接包装为verifiedNetwork，不放宽Session.development guard或新增环境绕开M3 fixture。真实本地HTTP/SQL在sidecar控制台账留证，只算开发协议证据。production adapter只接受production签名域/固定keyset才形成verifiedNetwork，必须拒绝development域/key/test factory；Bootstrap到真实gate前仍Unavailable。

## 2. 身份、激活和隐私

`accountID` 是服务端 HMAC-SHA256(secret, issuer + subject) 映射得到的匿名 ID；HMAC 密钥、tokenDerivationKey、receipt signing key 和 DB 路径必须显式配置并持久保存，已有数据库缺失密钥时启动拒绝，不能重生映射/epoch。Apple `sub`、真实 Apple ID、email、identity token、authorization code 仅在验证/交换的内存边界存在，不落数据库、不进入 trace、请求体日志或错误序列化。Bearer 设备令牌只持久存 hash，客户端放 Keychain；每次控制请求还须登记设备 key 的持有证明，session 绑定 deviceID/keyID/epoch。签名私钥放 Keychain，重装丢失凭据不认作原设备。原设备 ID 使用现有持久 installation identity，不由机型或 WC 状态推导；同 UUID 换公钥拒绝，必须走显式恢复。

身份验证流程：服务生成 256-bit 一次性 challenge，保存 hash、设备公钥指纹、到期和 consumed 标志；AuthenticationServices nonce 与设备 key 的 challenge 签名同时绑定该 challenge；服务固定从 `https://appleid.apple.com/auth/keys` 读取 JWKS，验证 `kid → kty/alg/use`、签名、`iss=https://appleid.apple.com`、配置 allowlist 中的 `aud`、`nonce`、`exp`、`iat` 和 challenge 未使用，再原子消费。2026-10-18 实查官方 JWKS 为 RSA / RS256；第一版仅支持该映射，`none`、未知算法、错误 key type、未知 kid 且刷新仍无匹配一律拒绝；不能按 token 指定 URL 下载 key，也不按记忆放宽算法。注入时钟，JWT clock skew 上限 60 秒；challenge 有效期 300 秒。JWKS bounded cache 最长 3600 秒，未知 kid 只触发一次合并刷新，取 key 失败 fail-closed。测试 Apple key/JWT 通过独立 factory 注入，不进入 production factory。

首次绑定 `(accountID, cloudSpaceID)`；`cloudSpaceID` 由客户端真实 CloudKit container / 当前 user record identity 计算非健康稳定标识并核验，后台只记 opaque 绑定值，不声称自己验证了 iCloud 私有库。后续账号或 iCloud identity 变化暂停云读写、激活/恢复和新开赛，保留所有原数据和请求；不把新空间当空库覆盖旧库。重新匹配双身份并显式恢复后继续。

同账号至多一个 active iPhone，以单调 `activationEpoch` 隔离旧设备；允许多登记 Watch，但一场仅一个 `recordingDeviceID`。Watch 登记须由当前已认证 active iPhone 提交其稳定 installation ID、公钥与一次性 server challenge 证明；服务返回限定账号/epoch/Watch 的凭据及签名登记回执。初次登录第二台 iPhone 返回 `waitingMigration`，绝不覆盖 active iPhone。

epoch 从独立全局单调分配器取值，该计数器不保存用户关联且不随删号清零。同 Apple 身份删号后重注册即使得到相同 HMAC accountID，也获得从未使用的新 epoch；旧session/grant/receipt/nonce全部拒绝，不能复用旧激活。用户选择保留的CloudKit/本地事实继续按原身份+空间只读恢复，与新激活分离，不能自动删掉或移交不同身份。

Apple auth 的 responseLost 不能依赖重新消费原 challenge/JWT/code。成功事务保存原 auth request digest、绑定公钥、随机 sessionID、固定 claims/expiresAt 及 token hash；设备 token 使用配置 `tokenDerivationKey` 对 sessionID/accountID/deviceID/keyID/epoch/expiresAt 域分隔 HMAC 派生，可按同claims重构原opaque token，不持久明文 token。`POST /v1/auth/recover` 无Bearer，既有字段 `version, requestID, authRequestID, deviceID, keyID, nonce, issuedAt, deviceProof` 保留，NATIVE-032新增可选 `devicePublicKey`（原raw32 Ed25519公钥的strict base64url）。新客户端总携原公钥，公钥字段参与既有 `football-record.device.auth-recover.v1` 域下的完整请求签名；省略该字段的旧wire/签名bytes保持兼容。服务先查原authRequestID/deviceID记录；有row时必须用原公钥验证keyID/可选公钥一致性、完整PoP/时间并消费nonce，只返回原会话/凭据和原公开结果。原session过期/撤销/已不存在分别保持knownExpired/knownRevoked，不重新激活，不用absence替代已知原结果，也不重新消费Apple输入。

客户端已持久首次auth但未发送、服务beforeCommit失败或原记录已被删号清除时，可没有可恢复row。旧wire缺公钥仍401，不能推断未提交或生成新ID绕过unknown。新wire缺row时须验证公钥指纹等于keyID、有效原私钥签名覆盖全部请求字段、deviceID/authRequestID绑定、60秒时间与nonce；同一BEGIN IMMEDIATE事务消费nonce并持久永久per(authRequestID,deviceID,keyID) absence fence，只有COMMIT成功才返回 `{status:"knownAbandoned"}`。其含义仅为“当前无可恢复原auth记录，且该tuple不能未来晚提交”，不声称历史从未committed（例如删号后旧attempt）。authenticate在Apple验证await后、同一SQL事务内、任何账户/epoch/session/challenge变更前检查同tuple fence，已封尝试不能晚提交；race只能恢复先提交的原session或封住尚未提交尝试。另一device/key可证明自己的tuple，但其fence不能取消原key尝试或取得原session。已有row始终优先原结果；缺row终态不创建session/epoch。

schema2新增absence和缺row恢复nonce表，只持久 `HMAC(tokenDerivationKey, domain + canonical[authRequestID,deviceID,keyID])` opaque fence及独立域的scoped nonce HMAC，不保存新增可关联account/device/authID、公钥、Apple输入或原token。永久fence在删号后保留防止旧attempt复活，无新增身份关联，不能称绝对不可识别；持久key配置须稳定，schema1升级与fingerprint检查在同初始化事务，失败回滚且不改旧结果bytes。新requestID不允许重用已消费nonce，关闭重开也拒重放。恢复beforeCommit失败或COMMIT后丢响应仍是unknown，保原attempt再用新nonce恢复；404/401/timeout及其他网络失败不能当knownAbandoned或将原auth视为已关闭。只有收到已验证的knownAbandoned/knownRevoked/knownExpired，客户端才能显式结束原unknown尝试并新建正常auth（新ID/challenge），不得自动绕过未知gate。公开auth响应中的token只在内存codec重构，requests原结果存不含secret的固定claims。

### 2.1 Watch 登记的显式封闭恢复（NATIVE-036）

首次登记和显式恢复必须是独立typed action，并在Watch→Phone转发中保留区别。不能根据Phone本地是否已有attempt推断首次是否已发送，也不能把GET404、原POST401、timeout或丢响应当终态。新增已鉴权 `POST /v1/devices/watches/recover`（`recoverWatch`），正文严格为原 `version, requestID, watchID, watchPublicKey, challengeID, deviceProof`，保留原完整登记意图和Watch签名；当前active Phone为恢复path提供fresh会话PoP，不更换原业务ID或Watch证明。

两入口均先按原account/requestID/operation=`registerWatch`/完整canonical digest查已持久结果。原已登记结果优先，恢复原receipt/session/credential且不延长原有效期；原封闭结果直接逐bytes重放，不进入旧sessionClaims/credential重构分支。同账号同ID异意图/操作仍409。缺原结果时，恢复核当前active Phone/account/epoch、既有Watch不得换账号/key/角色、原stored challenge的ID/watchID/公钥指纹/hash，以及覆盖原完整正文的Watch challenge域签名。仅此封闭核验可忽略challenge到期或consumed；不消费全局challenge，不新增device/session/epoch。缺challenge、非法证明、旧Phone凭据、事务失败均不提供终态证明。

同一SQL事务写入原requests结果和永久opaque封闭bit。响应为 `{status:"knownAbandoned",receipt}`；receipt沿用 `football-record.authority.receipt.v1` 及原canonical格式，签名body含 `operation:"registerWatch", result:"knownAbandoned"`、原requestID/full requestDigest、可信accountID/activationEpoch和 `registration:{watchID,watchPublicKey}`。客户端须验证固定environment/keyID/公钥签名及全部原attempt绑定后才能封闭，不能只信未签名status。重复recover、GET和迟到原register返回同一已存bytes；原已登记/封闭receipt均不改写。

无新schema：复用schema2的 `auth_absence_fences`，以独立域 `football-record.watch-registration-closed.v1` 对 `[accountID,requestID,fullDigest,watchID,keyFingerprint]` 做tokenDerivationKey HMAC，仅保存不可直接关联的opaque ID。tuple刻意不含epoch；bit跨删号保留，避免未登记challenge未关联account、旧requests被清后，同anon新epoch用TTL内旧proof复活。两入口stored-first后、任何登记变更前查bit；原row已删但bit仍在则401，不在新epoch重签封闭。其他account/key/意图的bit不取消本域原请求；封闭不消费他账号可使用的challenge。此永久控制不声称绝对匿名，不新增Apple/token/subject列。

knownAbandoned只证明该原当前域attempt已封闭且不能未来晚commit，不宣称历史从未committed。客户端持久验证过的closed proof后才可显式新challenge/新requestID，迟到成功不得覆盖closed；该Store/转发状态机由023独立实现。原PoP/domain/历史receipt和v2bytes保持，不因本机恢复修复开放production bootstrap，真实Apple/WC/设备仍待026。

## 3. HTTP 控制协议 v1

基础 URL 由配置注入；production 只允许 HTTPS allowlist，development 仅允许 loopback。正文上限 16 KiB、JSON object、固定版本 `1`，每个端点按下表拒绝未知字段、重复 JSON key、超长/非法类型、非有限数、额外嵌套内容。所有 ID 是 1～128 字节受限 ASCII `[A-Za-z0-9._:-]`；digest 为 64 个小写 hex；时间为整数 Unix 秒，epoch 为正整数且不越 JS safe integer / Swift Int64 边界。服务不接收任意 properties 字典。

除 auth 与下表明确的 delete-status capability 查询外，均要求设备凭据并验证账号/epoch/角色；设备令牌不放正文或 URL。写入业务的 `requestID` 在一个账号内唯一并永久绑定 operation + canonical request digest；live-status/delete-status是窄查询，auth-recover是可持久absence fence的窄恢复控制；其新requestID/nonce用于传输防重放，不覆盖原业务request结果；同 ID 异操作/异字段为 `409 idempotencyConflict`。`GET /v1/requests/{requestID}` 返回同一个已持久结果或 `404 notFound`，不能返回别的账号结果。每次写请求的响应丢失均以同 ID 查询/重发；不得生成新的 matchID、lockID 或 requestID 绕过未知结果。所有持设备会话的请求（含GET/status查询）的设备 PoP header 固定 `keyID, nonce, issuedAt, signature`，唯一 canonical signing input 为带 `football-record.device.pop.v1` 域的 `method, path, requestID, bodySHA256, sessionID, activationEpoch, keyID, nonce, issuedAt` 全部字段；GET正文digest为空bytes的SHA256且requestID取路径原ID。先验签再在事务内持久消费 nonce，过期 60 秒拒绝。仅替换 nonce/issuedAt 不换签名必须拒绝。

| endpoint | 正文允许字段（均含 version / requestID，GET 除外） | 成功与拒绝 |
|---|---|---|
| `POST /v1/auth/challenges` | `version, requestID, deviceID, devicePublicKey` | 随机 challenge、到期；不接受账号自报 |
| `POST /v1/auth/apple` | `version, requestID, challengeID, identityToken, authorizationCode, deviceID, devicePublicKey, deviceProof, cloudSpaceID` | 已验证匿名会话；第二机 waitingMigration；raw Apple 字段只 transient |
| `POST /v1/auth/recover` | `version, requestID, authRequestID, deviceID, keyID, nonce, issuedAt, deviceProof` + optional `devicePublicKey` | 无Bearer，原row优先恢复原session；可选公钥完整新PoP可在缺row时原子fence并knownAbandoned，不消费旧Apple输入 |
| `POST /v1/devices/watches` | `version, requestID, watchID, watchPublicKey, challengeID, deviceProof` | 当前 active iPhone 登记；同 watch 不改绑他人账号 |
| `POST /v1/devices/watches/recover` | 原完整 `version, requestID, watchID, watchPublicKey, challengeID, deviceProof` | 当前 active Phone fresh PoP；原已登记结果优先，缺row验证原Watch证明后原子签名封闭；见2.1 |
| `POST /v1/locks/acquire` | `version, requestID, matchID, recordingDeviceID, activationEpoch` | 原子获得 lock / 同请求原结果；已有锁返回 originalMatch，不能新开 |
| `POST /v1/locks/terminate` | `version, requestID, matchID, lockID, recordingDeviceID, activationEpoch, mode, cloudConfirmationID, contentCommitment` | `mode=normal` 仅原 recorder（可经手机代理）；`mode=abnormal` 仅当前 active iPhone，后两字段省略；精确比较原 lock 才释放 |
| `POST /v1/peers/grants` | `version, requestID, localDeviceID, remoteDeviceID, activationEpoch, pairingID` | 仅同账号登记 pair，固定 grant / epoch / 有效期 |
| `POST /v1/migrations/prepare` | `version, requestID, newPhoneID, activationEpoch` | 旧 active phone 在线、无锁，建立迁移 ID，暂停新开赛 |
| `POST /v1/migrations/checkpoint` | `version, requestID, migrationID, checkpointID, contentCommitment, activationEpoch` | 旧机确认所有待同步为零后的最终 opaque checkpoint，旧激活退出 |
| `POST /v1/migrations/activate` | `version, requestID, migrationID, checkpointID, contentCommitment, cloudSpaceID` | 新机完成下载校验后提交；匹配双身份/最终 checkpoint，CAS 增 epoch 激活 |
| `POST /v1/migrations/lost` | `version, requestID, newPhoneID, cloudSpaceID` | 持久 server requestedAt / eligibleAt，七天不得重试缩短 |
| `POST /v1/migrations/lost-recovery` | `version, requestID, migrationID, reauthenticationID, matchID, lockID, originalRecordingDeviceID, originalActivationEpoch, confirmedAt` | waiting新手机在七天后freshApple+原keyPoP获得只针对原锁的短期异常终结grant |
| `POST /v1/locks/terminate-lost` | `version, requestID, migrationID, grantID, matchID, lockID, originalRecordingDeviceID, originalActivationEpoch` | 验narrow lost grant与新机PoP，仅abnormal compare-release；不赋active/start/采集权限 |
| `POST /v1/migrations/force` | `version, requestID, migrationID, reauthenticationID` | 等待满七天后 fresh Apple 再认证且无活动锁；旧机凭据失效 |
| `POST /v1/accounts/delete` | `version, requestID, reauthenticationID, recoveryCapabilityDigest` | 先完成活动锁异常终结对账，再删匿名身份/设备/赠送资格/封禁申诉关联；返回逐步 receipt |
| `POST /v1/accounts/delete-status` | `version, requestID, deleteRequestID, recoveryCapability` | 无session，仅持capability窄取原delete结果；不重新注册或恢复账号 |
| `POST /v1/analytics` | `version, requestID, metric, count, appVersion, osFamily, osMajor, qualification` | metric 有限枚举、count 1～100；默认关闭，不接收业务内容 |

通用错误只含 `code, requestID, retryable, retryAfterSeconds?`；错误码冻结为 `unauthorized, invalidPayload, idempotencyConflict, activationMismatch, cloudIdentityMismatch, activeMatchExists, lockMismatch, migrationBlocked, waitingPeriod, reauthenticationRequired, accountDeleted, unavailable`。`activeMatchExists` 可额外返回签名原锁控制回执，禁止附业务详情。HTTP `401/403/409/422/429/503` 区分身份、权限、冲突、输入、限流和服务不可用；客户端未知错误暂停，不推断成功。

后端 schema 只含匿名账号/绑定、激活和登记、公钥与凭据 hash、锁、控制请求/签名结果、迁移、删除进度、资格与封禁申诉状态及允许统计。没有时间线/比分/名字/健康/GPS/场地字段，拒绝输入也不写这些内容到日志或 quarantine。StoreKit 真实购买归 Apple，V1 不实现付费；资格枚举/赠送资格可删除，真实购买恢复不被删号伪造失效。

## 4. 权威锁事务、签名回执和本地投影

锁不设自动释放 TTL，不因 permit/grant 到期、客户端或服务时钟前移自动放锁。不可变 request receipt 只证明原 acquire 结果。启动/恢复每次还需 `POST /v1/locks/status`，允许字段 `version, requestID, acquireRequestID, matchID, lockID, recordingDeviceID, activationEpoch, nonce`；此查询不更改原业务 receipt。服务在同一 SQL 事务读取原 receipt、当前激活和当前锁并签发 nonce-bound `LiveLockAttestationV1`（同字段另含 `accountID, receiptID, status=held|terminal|mismatch, observedAt, expiresAt`），有效期 60 秒。客户端必须匹配本次随机 nonce、当前 epoch 与设备，仅 `held` 进入原启动；历史 acquire 回执重放不能代替 live status。若锁已由手机异常终结/释放，返回 terminal 并持久归原比赛，provider 拒绝启动，Session 不生成新的开始或 Workout。live attestation 使用独立签名域 `football-record.authority.live-lock.v1` 并绑定完整查询意图摘要和nonce；fresh nonce/时间/签名可变化，原 acquire outcome/lockID/receiptID/原 bytes 保持不变。

每个写操作在 `BEGIN IMMEDIATE` 内：验证设备/epoch → 查原请求 → 校验业务前置 → 修改唯一活动锁/激活 → 保存 canonical 请求摘要和固定结果 bytes → COMMIT。`active_locks.account_id` 唯一；没有“内存先查后写”锁。事务内不 await 网络/JWKS/SDK；先得到验证结果，再在事务内重验 challenge/epoch/状态。故障前回滚；COMMIT 后丢响应用原请求查同结果。关闭重开、两个 SQLite 连接/两个 worker 真实并发都必须只有一个赢家。

release 只执行带账号、原 `matchID/lockID/recordingDeviceID/activationEpoch` 的 compare-and-delete；先查原请求已提交结果，因此旧终结重试返回原成功，不能释放新比赛锁。任何终结不改变 recorder，不创建替代 Workout。若锁已被另一合法请求终结，返回原终结控制状态和明确冲突，不伪造第二个正常完成。

控制结果采用 Node Ed25519 签名，公钥 wire 格式为严格 base64url 的 32-byte raw key（SPKI DER 不能冒充 raw），Swift 用 CryptoKit `Curve25519.Signing.PublicKey` 验签；配置固定 keyID→公钥，不能信任响应附带的公钥。签名字节为 UTF-8：`football-record.authority.receipt.v1\n` + sorted-key JSON body；所有 body 字段仅受限 ASCII/安全整数/固定枚举，禁止浮点、Unicode 和可选空值差异。body 固定包含 `version, environment, keyID, receiptID, requestID, requestDigest, operation, accountID, activationEpoch, matchID, lockID, recordingDeviceID, result, issuedAt`；非锁操作的三个锁字段为空字符串。外层只含 `body, signature`，signature 为严格 base64url。result 枚举 `held, originalMatch, releasedNormal, releasedAbnormal, registered, waitingMigration, checkpointAccepted, activated, waitingPeriod, deleted, grantIssued`。额外 lifecycle payload 在各端点固定结构中纳入签名，不以开放字典扩展。requestDigest 是已持久typed business请求canonical摘要，包含cloud commitment/迁移checkpoint等全部允许字段，transport PoP nonce/time不进入business digest；验签后必须与原intent摘要完全一致。签名验证必须同时匹配调用的完整意图、环境、账号、epoch 和当前设备角色；仅验签正确不能跨场复用。

本地 authority schema4 新台账 `account_binding_v4, control_intents_v4, authority_results_v4, authority_projection_v4, peer_grants_v4, lifecycle_steps_v4, cloud_applied_batches_v4, cloud_checkpoints_v4` additive 创建；旧 descriptor、command/receipt、outbox、packet、ACK canonical 原 bytes、checksum、route、sequence 完全保留。`control_intents` 保存稳定完整意图/摘要和 pending 状态；`authority_results` 保存验签原 bytes / digest 与首次结果，不能只存一个 Boolean。`authority_projection` 是新可信投影，不让普通 `commitV2` 或 peer descriptor 写 `releasedConfirmed`。`Store.validateDescriptor` 的原 unknown/held 路径维持，新增专用控制 API 只按已验签证据 CAS 推进。

Session 复用已持久 `StartIntent` 和 `SessionCommandRequest.start`：先保存 intent → 原 `StartPermitProvider.acquire(for:)` 对同 ID acquire/query 并获取 fresh live-lock attestation → 验签持久原结果 → 同场队列复核 → 原命令事务保存 held permit / 开始事件 → gateway。锁已得但后续 SQL/Workout 失败时保留原意图与锁投影，用相同 ID 对账；不得静默释放、换 ID 或允许其他比赛。网络 await 在队列/SQL 事务外，返回后重读 epoch 和 terminal；账号变化期间返回旧结果只归旧意图，不激活新账号。

专用协议新增于 MatchStore / MatchSession，不扩大现有 `SessionRepository` 必须实现的方法，避免 008/018 等历史 wrapper 被新抽象要求破坏。`SQLiteSessionRepository` 同一个 facade/唯一 MatchStore 实现这些附加协议；服务用 `SyncRepositoryIdentity` 比较实例和 namespace，拒绝第二连接。控制意图、云导入、异常终结与 execute/recovery/capture/inbound 共用 Session 同场队列。

```swift
public protocol AuthorityRepository: Sendable {
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity
  func prepareControlV4(_ intent: ControlIntentV1) async throws -> ControlIntentReceiptV4
  func pendingControlsV4() async throws -> [ControlIntentV1]
  func recordAuthorityResultV4(_ receipt: VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4
  func authorityStateV4(matchID: String) async throws -> AuthorityStateV4
  func completeNormallyV4(release: VerifiedAuthorityReceiptV1, cloud: VerifiedCloudSaveV1,
    expectedGeneration: Int64, now: Date) async throws
}
public protocol AuthorityInboundCoordinator: Sendable {
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity
  func acceptAuthorityResult(_ receipt: VerifiedAuthorityReceiptV1) async throws -> AuthorityReceiptV4
  func requestAbnormalEnd(_ request: AbnormalEndRequestV1) async throws -> SessionReceipt
}
```

`ControlIntentV1` 为上节允许字段的 typed operation enum，包含稳定 requestID；`ControlIntentReceiptV4` 是已持久该意图的摘要；`VerifiedAuthorityReceiptV1` 只能由固定公钥验签边界构造，携带原 bytes 和 typed body；`AuthorityReceiptV4` 保存首次投影结果；`AuthorityStateV4` 是结构体，`status` 分别为 held / terminationPending / releasedNormal / releasedAbnormal / unknown，`verifiedNormalRelease: VerifiedAuthorityReceiptV1?` 与 `cloudProofMatchingCurrentFactsAndCapture: VerifiedCloudSaveV1?` 由当前持久事实核对派生，receipt 的 `matchesOriginalLock(of:)` 比较account/原intent/match/lock/recorder/原epoch，不与 MatchReplay 状态混成一个字段。`AbnormalEndRequestV1` 固定 requestID/matchID/lockID/originalRecorder/confirmedAt，不接受替代 recorder。具体类型放 `AuthorityModels.swift`；023 实作时不能用可公开随意初始化的 verified DTO 绕过验证。

## 5. 云数据、事务游标与完整保存证明

M3 的 8 MiB 是完整业务消息上限，不是单个 CKRecord Data 字段容量承诺。024 用 manifest + CKAsset 保存原 canonical bytes；先确认所有 asset / manifest 的保存和回读完整长度、digest、引用闭合，再产生 cloud proof。asset 上传成功而 manifest 失败仍 pending，不承认部分完整保存。

CKRecord仅放小metadata及asset引用。下载得到的系统asset staging文件必须在SDK回调返回前复制进App自有持久目录并校验size/hash，不能保存系统临时URL后异步再读；失败保留batch pending，不推进cursor或生成proof。

CloudKit 只用自定义 private Record Zone；物理 zone 按 `(accountID, cloudSpaceID)` 稳定，activationEpoch 只作写入/队列/授权 fence，不创建空的新zone隔断历史。新激活从稳定zone全扫，先以迁移只读授权校验旧epoch最终checkpoint；合法历史事实按原match identity只读恢复，旧epoch不能获得当前开赛/写入权限。record 类型冻结为不可变 `MatchFactsV1`（start identity、全部非健康 events/tombstone 与 capture metadata 修订）、`CheckpointV1`、`DeletionV1`；队伍/球员快照、场地和生涯基础事实按其既有业务字段进私有云，M5 新增字段须 versioned 增量，不能送后台。禁止 HealthKit 样本、心率、GPS、路线、距离、速度、能量和原始 Workout；只允许现有非健康关联 ID。单 match payload 上限沿 M3 完整 8 MiB，超限显式 blocked 不截断。每份不可变 snapshot ID 由 account/match/完整 fact digest/captureDigest 域 hash 生成；条件保存用 `.ifServerRecordUnchanged`，服务端冲突保留本地与远端原事实并显示冲突，不做 silent LWW。

CloudSync 拥有独立 durable cloud upload queue、重试/attempt、原 bytes、changeTag 和待导入 batch；不得用 `unroutedBusinessOutboxV3` 或 peer ACK 台账当唯一云队列，因为原 peer 项可能已路由/确认。CloudSync 的传输 SQLite 不是第二个业务 MatchStore，不直接改比赛。所有 business writes 经原 Session/facade。

`CKServerChangeToken` 是不透明 archive bytes，仅由 SDK driver 编解码，附 zone/账号绑定；不从 token 猜时间/序号。022 先持久完整下载批次，不推进权威 cursor。023 的 `commitCloudBatchV4` 在现有 MatchStore **同一事务**验证/合并本批事实、tombstone，保存首次 import receipt 和该批 opaque token；随后 CloudSync 才确认批次。唯一可用于下一次 fetch 的 `appliedToken` 来自该事务；单独“已收到 token”或仅写进 transport inbox 不能推进。批次中任何记录验证/冲突/SQL 故障均不推进 token，原 batch 保留、阻塞并可重试；COMMIT 后丢响应查首次 receipt，不重复事实。

```swift
public protocol CloudImportRepository: Sendable {
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity
  func cloudCursorV4(scope: CloudScopeV1) async throws -> CloudCursorV4
  func resetCloudCursorV4(scope: CloudScopeV1, expectedGeneration: Int64) async throws -> CloudCursorV4
  func commitCloudBatchV4(_ batch: ValidatedCloudBatchV1) async throws -> CloudImportReceiptV4
  func saveCloudCheckpointV4(_ proof: VerifiedCloudSaveV1) async throws -> CloudCheckpointReceiptV4
}
public protocol CloudInboundCoordinator: Sendable {
  func syncRepositoryIdentity() async -> SyncRepositoryIdentity
  func importCloudBatch(_ batch: ValidatedCloudBatchV1) async throws -> CloudImportReceiptV4
  func acceptCloudSave(_ proof: VerifiedCloudSaveV1) async throws -> CloudCheckpointReceiptV4
}
```

`CloudScopeV1` 固定 accountID/cloudSpaceID/zoneID/activationEpoch，zone物理身份不随epoch变化；`CloudCursorV4` 是同一次事务读取的 `appliedToken: Data?, fetchGeneration: Int64`，reset必须CAS旧generation后递增再置空，不能拆两次查询拼cursor；`ValidatedCloudBatchV1` 含 scope/batchID/原 records 与删除标记/expectedAppliedToken 原 bytes/nextToken 原 bytes/fetchGeneration，验证构造器拒绝未知 record schema；同事务先查首次receipt（原batch重放返回原结果，不回退cursor），再以当前 appliedToken 原bytes与 expectedAppliedToken 相等及持久fetchGeneration相等作CAS，不能比较opaque token大小。不同batch乱序T2→T1拒绝而不倒退；`CloudImportReceiptV4` 绑定完整 batch digest 与首次结果；`VerifiedCloudSaveV1` 由 trusted driver 完成条件保存并回读/确认全部相同 snapshot 的 recordID/changeTag/digest 后生成，绑定 scope、matchID、terminalEventID、完整事实 digest、captureDigest、checkpointID、confirmationID；fake 构造工厂仅 development。`CloudCheckpointReceiptV4` 是同 facade 当前快照核对后已保存的 proof 引用。包依赖避免循环：这些纯 DTO / 协议由 023 放 MatchStore，022 初期定义 transport 自有 DTO 与 `CloudCommitSink` 闭包协议，023 交付显式 bridge，不能让 MatchStore 依赖 CloudSync。

`changeTokenExpired` 通过同业务facade的reset事务递增持久fetchGeneration并将本scope appliedToken置空，进入全量重扫；resetGeneration前的旧batch即使迟到也拒绝，不能复活旧cursor；保留未上传本地快照、已存 tombstone、pending batch 和冲突。全量重扫完成前不得以“远端缺席”删除本地记录；只能用明确 tombstone。quota / 网络 / iCloud 关闭 / permission / accountChanged 各有 typed issue 和持久重试，unknown 不当空库或已同步。通知只唤醒，重开从持久 queue / cursor / checkpoint 读取。

正常结束先原记录设备本地 `matchEnded` + capture 收尾 → `endedPendingSync`。完整云保存证明到达同场队列，先在专用 checkpoint/proof 表保存，并核对当前所有 events（含更正/撤销/删除）与完整 captureDigest；此时不写 `CompletionProofV2`，仍是 `endedPendingSync`。随后提交稳定 normal termination 意图，后台仅验证身份/设备 PoP/锁和客户端 opaque save assertion 承诺并原子放锁；这是信任已认证客户端真实云适配器的明确假设，服务不能独立验证 private DB 内容，收据不得声称 server-verified CloudKit save。只有已验证 normal release 和匹配当前全事实/captureDigest 的 cloud proof 同时存在，才在同场队列内原子保存 `CompletionProofV2` 并 publish completed，不能先让 MatchReplay completed 再由 UI 隐藏。peer ACK 或 release receipt 单独不能产生 completed。后续纠错/新增 capture 修订使旧 completion proof 失效，但既有 release 永久绑定原 account/match/lock/recorder，不撤回或重新取锁；新的精确 cloud proof 可结合既有 normal release 重建 completion，无须已释放后台为新 digest 再次放锁。异常终结始终 incomplete，任何云保存或迟到数据都不能改正常完成。

## 6. 生产 peer 信任和生命周期隔离

M3 `receiveV2`、fragment/ACK 接收的 development permit 精确匹配、防伪与环境检查保持。023 新增独立 `ProductionPeerEnvelopeV1` 路径：原 v2 canonical packet/ACK bytes + source/target/account/activationEpoch/pairingID/grantID + 原 body digest，发送设备用登记 Ed25519 key 签名；接收先验证 backend 签名 grant、公钥/设备/角色、当前 epoch、有效期，再验设备 envelope 签名和完整原 payload。服务器 grant 不是比赛完成证明。未经该路径不能把 `.production` enum 或 `verifiedNetwork` descriptor 当可信。

NATIVE-030补足服务端角色证明：`peerGrant` nested签名正文除既有`grantID/pairingID/localDeviceID/remoteDeviceID/localPublicKey/remotePublicKey/expiresAt`外，必备`localRole, remoteRole, activePhoneID`。角色从同account、当前activationEpoch的登记device行读取，activePhoneID从该account的当前active_phone_id读取；只允许一端`phone`、另一端`watch`（local/remote任意顺序），phone端deviceID必须等于activePhoneID。申请caller仍必须是该active phone及其原登记key的有效session/PoP。waiting、未知角色、Watch-Watch、Phone-Phone、非active phone端点、跨account/epoch或错误caller/key一律不能形成新grant。客户端不能从WC、envelope、endpoint名称或请求自报字段推断角色；新请求不增加role/activePhoneID字段，HTTP codec仍拒未知字段。接收verifier须在backend原签名下检查这三个字段、恰一phone一watch及phoneID==activePhoneID，并与当前account/epoch、具体source/target及登记公钥绑定；签名有效但缺字段或角色不合法不构成新production context的信任证据。

该签名正文增补仍是preproduction V1，不改HTTP请求、设备PoP、receipt签名domain或原v2 packet/ACK bytes。旧requestID回放及GET只读返回持久原receipt bytes，绝不补写角色、重新签名或延长有效期；即使历史存在已签Watch-Watch结果也保留原bytes供对账，不能当作新角色证明。缺必备角色的旧grant必须暂停用于新production context；合法active phone + Watch可显式使用新control requestID、原pairingID和相同有序端点续取同grantID，重新验证当前登记/角色/epoch并生成新签名与有效期，原request结果不变。旧非法pair不能靠renew取得新proof，不能为修复而悄改旧result或旧业务pending绑定。生产provider/trust/bootstrap仍默认unavailable；030只修本地参考后台的证明责任，不启用App或声称真实WC/设备验收。

新 Store 入口接收只能由 verifier 构造的 `VerifiedPeerEnvelopeV1`，复用原 facts/ancestry/inbox/ACK validator，但按独立权威证据查本地账号/permit，绝不接受 peer 自报 release/completion。v2 原 bytes 不改写，旧 protocol/fixtures/hash 不变。生产 envelope 的路由/重试/ACK 台账独立版本，旧 pending 永不自动改绑。有效期到期暂停新发送/接收，可用同 grantID 重新取合法 grant，不重建业务 ID。

`sync_context_v3` 是现有 singleton peer/epoch 绑定，不能为换 Watch 自动 UPDATE 或把旧 pending 指向新 peer。显式换 pair 流程由 active iPhone 申请新 grant、冻结旧通道、保存生命周期决定、在 schema4 新 context 中建立新 peer 域；旧 route/ACK 保留。旧 pair 尚有未确认事实时显示待处理，只能从完整本地/云事实为新 pair 创建新域的独立 snapshot，不能假装旧包获 ACK。账号登出/激活 epoch 变化立即失效旧 grant，原比赛迟到事实仅能按旧 matchID 和明确恢复授权导入，不复活活动锁。

## 7. 正常迁移、丢失迁移、删除与分析

正常迁移状态为 `waitingNewPhone → oldPhonePrepared → finalCheckpointSaved → oldPhoneDeactivated → newPhoneVerified → activated`。prepare 时在服务事务中冻结新开赛，要求旧机在线且无活动锁；客户端另要求无 endedPendingSync / 云 pending / 冲突。旧机把最终完整 checkpoint 保存到私有云，再提交 opaque ID/commitment；服务停用旧 epoch，保留迁移 reservation，新机下载并逐 record/digest 校验 checkpoint 后 CAS 激活。下载失败保持 waiting，不能同时激活两台；任何旧机离线/活动比赛/待同步都拒绝正常迁移。HealthKit 同步不作为迁移完成条件。

丢失迁移 `eligibleAt = persistedServerRequestedAt + 604800` 秒；重复请求返回原时间，客户端时钟提前/倒退与服务重开均不能缩短。到期后需要该时点之后新签发且未使用的 Apple 再认证（300 秒有效），不能重用申请时登录。若有活动比赛，新的已验证同账号手机只能通过专用 lost-recovery 异常终结授权先结束原锁，保持原 recorder / incomplete；锁确认释放后才 force 激活。新机只恢复已在 CloudKit 的内容，UI 明示未上传数据可能无法恢复，不接管原 Watch Workout。

删号采用持久逐项 saga：`requested → lockReconciled → appleRevocation → backendDeleted`，客户端独立保存 `cloudChoice/cloudProgress, localChoice/localProgress, healthConfirmed/healthProgress`。用户选择分别控制 CloudKit 与本地；HealthKit 仅对 App 创建 Workout 单独确认，不因删账号/本地自动执行。当前活动锁必须先经用户确认异常终结并对账，不能删掉锁行假装正常完成。Apple 撤销通过 fresh reauthentication authorization code 的 exchange/revoke adapter 完成，响应和 token 不持久；失败保留阶段并提示再认证重试，不把 backendDeleted 称全部完成。服务删除身份/设备/赠送资格、会话/公钥与相关封禁申诉关联，保留30天的最小化假名 deletion receipt 与 recovery capability hash，仅供查询原delete结果；不声称这些控制记录绝对不可识别，不保留Apple身份映射。到期清除receipt；真实购买记录归 Apple 可恢复。离线/中途退出重开从各分项继续；后台身份删除成功后云/本地/HealthKit 失败仍分别显示。

客户端发delete前先持久随机256-bit recovery capability，签名delete原request仅携其SHA256；服务只存hash并把它绑定原deleteRequestID。COMMIT后凭据已撤销且响应丢失时，使用无session的delete-status端点；capability仅放正文、绝不URL/日志，常量时间比较后只能返回该原请求的进度/receipt，不能取得其他数据、创建会话或新账号。客户端在CloudKit/本地/HealthKit分项全部处理完或明确保留前，不删除最小saga控制文件/capability；“删除本地数据”不提前擦掉恢复手段。30天后明确receiptExpired，不以重新登录自动新建账号假装原delete重试。

分析默认关闭；关闭即丢弃尚未发送的可选 analytics queue，不删除业务、锁控制或必要故障状态。metric allowlist：`registered, activeDay, matchCompleted, matchIncomplete, watchRecorded, syncSucceeded, syncFailed, recoverySucceeded, recoveryFailed`，计数去重稳定 requestID；活动只由实际使用事件采样，无持续心跳。服务根据匿名账号计数和日桶计算比赛数/最后活跃/DAU、WAU、MAU、设备与资格状态、版本分布和成功率，不保存事件内容、心率或精确位置。退出/删号关闭发送并清理未发统计；匿名去身份 aggregate 可保留。日志只输出有限 code/requestID/operation/耗时，不输出 DTO/body/Authorization/Apple 字段。

### 7.1 NATIVE-027：服务端AppleRevoker（本地软件已交付）

027是`backend/**`唯一写入者，可在含021的最新已验证dev上与023独立并行。024只负责客户端AuthenticationServices/fresh reauthentication和Keychain/CloudKit；服务端token exchange、revoke及ES256 client_secret由027承担，TeamID、KeyID、`.p8`私钥和client_secret绝不进入App、业务库、仓库或日志。默认revoker仍unavailable；development受控transport/factory与固定Apple生产transport严格分离，真实配置/撤销留026。

021初始hook只接`authorizationCode`；已交付027补足身份核验，将`apple-verifier.mjs`验证结果补为内存已验证`issuer/subject/audience/nonce/issuedAt/environment`；`device-auth.mjs`仅在transient reauth map中保留code及此上下文，绑定原account/device/key/epoch/reauthenticationID。`lifecycle.mjs`在原pending-delete和同设备PoP验证后，将该对象交`appleRevoker({authorizationCode, expectedApple, reauthenticationID})`（返回`Promise<{revoked: true}>`）；expectedApple不得从客户端自报字段或解码未验JWT构造，不持久真实subject/code/token。await后沿021既有pending-request/digest/epoch/reauth CAS推进，不能把别人的code或新的删除请求代入。

生产网络固定HTTPS且拒绝redirect：`POST https://appleid.apple.com/auth/token` 的form字段为`client_id, client_secret, code, grant_type=authorization_code`；仅当原已验证授权流程明确携带且匹配配置的redirect_uri时原值带入，原生AS无该值则省略。client_id须等于配置allowlist和expected audience；client_secret为服务端ES256 JWT，header `alg=ES256,kid=配置KeyID`，claims `iss=TeamID,sub=client_id,aud=https://appleid.apple.com,iat=当前秒,exp=iat+300`，JOSE签名用64-byte P1363而非DER。Apple返回的id_token仍按可信Apple JWKS及其alg/key匹配验签，校验exp/iat合法并比对iss/sub/aud/nonce与expectedApple一致；此RS256验证边界与ES256 client_secret签名不是同一用途。身份不匹配、缺id_token或refresh_token拒绝，不调用revoke。

通过后以同一client_id/client_secret向`POST https://appleid.apple.com/auth/revoke`发form `client_id, client_secret, token=内存refresh_token, token_type_hint=refresh_token`。HTTP200空body正确视为该次撤销成功，不强制JSON；非200/超时/非法交换响应转有限错误码，不输出response body、code或token。网络await全在SQL外。未知token exchange结果不得盲重放单次code；状态保持待撤销/需fresh reauthentication。refresh_token仅在本次内存中存在时可重试同一撤销，进程重启或token遗失必须fresh auth并绑定原pending-delete，不伪造已撤销、不重建删除请求。仅成功撤销且原本地CAS提交后才推进appleRevocation；删除其他分项不由该adapter推进。

### 7.2 NATIVE-028：独立HealthKitDeletion（SDK候选保留）

028仅持新`native/Modules/HealthKitDeletion/**`及自身任务/验证卡；不写008/018采集候选、AccountKit、Apps、project/scheme/entitlements或脚本。模块自带SwiftPM、受控driver和独立文件SQLite控制ledger，不成为第二业务MatchStore。默认driver unavailable，SDK执行默认关闭；第一阶段只host受控测试及iOS17/watchOS10 sim/device四triple编译，不调用用户HealthStore查询、删除或授权prompt。

删除请求固定稳定requestID、selectionDigest及单独Health删除confirmation（确认ID/时间/同一选择摘要）；每目标精确含`workoutUUID, matchID, recordingDeviceID, segmentToken, expectedSourceBundleID`。这些本地控制字段不送后台/云，不保存健康样本；同requestID异选择拒绝。026从原采集registry映射已确认范围，缺映射/metadata/source匹配时保留分项失败，不能扩大为所有Workout。真实predicate为 **当前`HKSource.default()` AND OR(每个目标UUID AND matchID AND recorderID AND segmentToken)**，先比expected source与当前App source；不能把各字段多值集合交叉匹配。仅允许App自身source保存对象；Phone/Watch source及授权不可假定相同，不删除第三方或另一source的数据。无需先做Health查询；空可见query不证明读权限或全局已空。

ledger独立于普通本地业务擦除目录，先事务持久`executing/attemptID/完整request摘要`再调用SDK；超时保留`awaitingOutcome`，同一未决attempt不并发重复发。重开未知结果只能对原scope/原request恢复或重试；迟到callback必须匹配原request/selectionDigest/attemptID，不覆盖更新选择、不推进CloudKit/本地/账号分项。`success=true,count=0`只记录该精确scope本次操作结果，不称全部健康数据已空或已获读取权限；错误/未知结果保留分项状态和可恢复诊断。普通本地擦除后控制ledger及最小恢复信息仍可读取，完成或用户明确保留分项后才按026的saga规则收尾。

026将028的requestID/选择摘要/confirmation/per-scope结果映射到既有healthConfirmed/healthProgress；025负责运行时明确确认和进度UI。027后端删除与028 Health删除互不代替成功；真实source/权限、本人明确确认及目标对象删除验收在026单独登记，SDK候选此前保留树。

### 7.3 NATIVE-033：单ledger本地传输逻辑擦除

已集成033的`CloudLocalTransportErasing`是独立可选协议，原CloudLedger required方法及canonical编码/hash域不变，默认eraser unavailable。稳定requestID绑定完整原scope；只在该ledger文件按accountID/cloudSpaceID/zoneID三ID原UTF-8精确选择全部epoch，清理upload、staged batch（含ACK）、conflict双方、save evidence四类canonical副本；其他stable zone原bytes不变，Unicode规范等价不能合并不同原bytes身份。重开不使用新epoch替换原同ID请求。

同事务先重放首次相同请求receipt，否则严格校验原bytes/归属/digest/ACK，写永久stable-zone fence、清理目标、再枚举核实canonical零并保存最小receipt；未知/损坏/无法归属失败保留，COMMIT前全回滚、后丢响应以原请求重放。该文件所有canonical写事务均查fence，旧连接、await中save/fetch及迟到回调不能复活；新epoch和clearScopeIssue都不能解除，无in-file unfence。两个控制表只留最小请求/摘要/scope hash，不存被清业务原bytes或saga秘密。

receipt仅证明**该文件四类canonical的逻辑清理**，不能代表全本地删除、CloudKit删除或物理介质/备份擦除。026必须遍历完整owned ledger catalog，聚合所有033逐文件结果、024 owned CKAsset staging清理和023业务Store结果；独立saga、recovery capability及028 selection/分项控制必须在普通业务擦除后仍可恢复，不能以某一receipt提前推进“本地全部完成”。

用户选择保留云并恢复时，由026先使全部旧actors失效，再显式选择新ledger namespace/文件及已授权业务cursor初始化；旧文件永久fence持续挡旧实例。023/024/026相关聚合与真实环境尚未验收，033本地Cloud80或两项最低SDK编译不能代替这些门槛，生产装配不因该任务开放。

## 8. 必测故障与真实门槛

027/028是原删除要求的责任补足，不新增产品决策。024客户端SDK、027服务端撤销和028独立删除driver分别验证；025只负责工程/UI装配，026统一映射saga和实际环境。027纯参考server可按双审及本地gate入dev而不开放生产；024/028 SDK候选门槛前保留独立树。受控driver/四triple编译不证明用户HealthStore读/删或真实Apple撤销。

自动层必须覆盖两个真实 DB connection/worker 并发 acquire、auth首次COMMIT丢响应恢复同session且不重消费challenge、仅修改PoP nonce/时间而不换签名被拒绝、删号COMMIT丢响应凭capability恢复、删号同Apple重注册拒旧epoch proof、同 ID 异载荷、commit 前失败/后丢响应/关闭重开、锁得而本地启动失败、终结和新开交错、旧 epoch/旧 match 终结、新 Watch/账号切换、伪签名/kid/跨域重放、生产 DTO 不能通过开发 factory、schema3→4 每故障点回滚及旧 canonical bytes 零变化。云覆盖 token 与事实原子性、同batch首次receipt优先重放/不同batch乱序parent-token CAS/expired后旧generation不复活cursor、冲突/配额/partial failure、tombstone 不复活、tokenExpired 全扫、账号切换停写与完整 proof 失效。迁移覆盖所有拒绝项、604799/604800 秒、时钟倒退/重开、重认证过期；删除覆盖每一步独立失败与重开，不合并成功提示。

真实层须绑定 exact SHA、服务部署版本、两个 Apple/iCloud 身份、签名设备/OS、时间和结果：Apple 登录/撤销、双身份不匹配、Watch 自身联网与经 iPhone 代理开赛、完整离线结束→手机持久→CloudKit→后台释放→新开、手机异常终结与迟到 Watch、正常/七天丢失迁移、删号四分项。008/010/016/018 保留原门槛；编译、fixture、单机服务和两模拟器都不替代真实层。M4 全部属于 V1，未测项目留在 024/026 任务分支，不提前勾完成或晋级 release/main。

实现依据（2026-10-18 官方预检）：[Apple 用户验证](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)、[Apple JWKS](https://appleid.apple.com/auth/keys)、[CloudKit zone 变更](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation)、[条件保存策略](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged)、[Apple private DB 示例](https://github.com/apple/sample-cloudkit-privatedb-sync)、[Node 22.23.1 SQLite](https://nodejs.org/download/release/v22.23.1/docs/api/sqlite.html)、[Node crypto](https://nodejs.org/download/release/v22.23.1/docs/api/crypto.html)。官方 API 页面与本机 SDK 编译只证明接口依据；Node SQLite 文档仍标 active development，真实 Apple/CloudKit/Serverless 行为另验。

027/028补充依据（2026-10-19官方只读预检）：[Apple token验证/交换](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)、[token撤销](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)、[服务端client secret](https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret)、[HKSource](https://developer.apple.com/documentation/healthkit/hksource)、[限定predicate删除](https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects%28of%3Apredicate%3Awithcompletion%3A%29)。文档和SDK检查不表示实际Apple凭据、用户HealthStore授权或删除已执行。


### 7.4 NATIVE-052：原删除parent的专用fresh认证控制面

本段追加原删除恢复的目的边界，不改既有auth/delete/lock canonical wire、旧receipt或历史证明。普通signIn/recover安装binding属于业务入口；业务永久退役后不得解gate、创建新Session/业务DB或用generic auth/apple重建身份假装原delete重试。052只定义独立`deleteControl.v1`目的的challenge/apple/recover端点，具体闭合字段与固定新签名域见[052计划](../../superpowers/plans/2026-10-20-m4-deletion-control-reauth.md)。capability仍只放body，单独不能创建会话或账号；专用认证必须同时证明fresh verifiedApple与原device purpose签名，并在await后原SQL事务重查原account/device/key/epoch/cloud及原parent canonical digest/cap hash。

若原client已持久意图但从未在server预留，只可对仍存在的原身份将同一原canonical intent absent→requested；已有pending仅同parent/digest/cap可继续，不同pending/已删/缺身份拒绝，零新account/device/epoch。原delete bytes中的旧reauthID不改，requested/lockReconciled使用server新mutable reauthID；appleRevocation只恢复控制凭证，不倒退或重复撤销。COMMITlost恢复原attempt/首次proof，unknown不得重POST单次code或改ID；receiptExpired不退回generic登录。

控制session的持久purpose只准原delete/query；为原活动锁对账，仅可增加原parent固定的实际match/lock/recorder/epoch及原signed held acquire对应的live-status、用户明确确认后的一个稳定abnormal请求和原query，绝不normal/acquire/释放新锁。pin必须来自server原行及原签名receipt并由client与Store复验/持久，缺真实映射保全typed blocked，不从配置猜、不新造Match/permit/capture。known本机held仍在Saga/freeze前走原异常终结，原createDeletionSaga拒绝不变。

Core新可选控制入口在原Store同事务验原Saga/control/cap/rawscope/key/gen，retained typedkind与046全inventory、045当前零及LocalErasure兼容，历史最小控制可读且不含业务副本；backendDeleted/local完成后不能再添auth事实或刷新vault。052不改binding/gen、不admitIdentity、不解除录制。原owner保留控制通道到原Saga恢复完毕，finalclose须先stop/cancel/join全部owned控制任务再关原资源。root+m2源码/最终双审及本机矩阵不等于026整体或真实Apple/账号/设备/部署完成，production默认Unavailable保持。
