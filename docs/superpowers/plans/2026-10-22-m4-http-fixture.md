# M4 空 authority HTTP fixture 与独立身份观察 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 用户已选择由开发子代理执行；本次仅交付待双审计划，作者收到 root 明确准入实现后才写 helper / 产品 / tests，不重复询问用户执行方式。

**Goal:** 为后续原始 M4 / 051 的首次真实 HTTP 认证提供零预登录的 file SQLite authority，以及经过独立 nonce / 真实 JWT 验签的服务端当前匿名身份观察。

**Architecture:** 复用现有 `createAuthority`、`authSetup` 和 `createHTTPServer`，另建测试专用 sidecar；不调用会 seed Phone 的外层 fixture。仅从 `device-auth.mjs` 提取原 HMAC 纯映射，在原事务位置复用；测试 sidecar 通过 genuine development verifier 验证独立观察输入，再用同一 authority 的密钥映射，无账号、设备、会话、请求或锁写入。控制面为 requestID 对应的 stdin/stdout JSON Lines，业务认证仍走既有 loopback HTTP。

**Tech Stack:** 仓库声明的 Node `22.23.1`、`node:http` / `node:crypto` / `node:sqlite`、既有 development Apple verifier / RS256 fixture signer、Node test runner。默认实际 Unix 秒时钟；不改 Swift / Xcode / 最低 iOS 17 / watchOS 10。

---

## 1. 当前阶段、精确基线与所有权

这是 NATIVE-058 的**计划交付**，所有实施 checkbox 保持未勾选。本轮不运行 Node、HTTP、SQL、测试、构建、设备或模拟器探测，不改实现。依据为 [原生母计划](2026-10-15-native-development.md)、[M4 母计划](2026-10-18-native-m4.md)、[M4 合同](../../native/contracts/m4-account-lock-cloud.md)、[Git 治理](../../git-workflow.md)及 root 派工。

| 字段 | 登记值 |
|---|---|
| 唯一作者 | `/root/m4_native_http_fixture`；root 统筹，root 与第二位非作者审计划及后续 source/final |
| original base / 创建后实际 HEAD / 当前 dev | `2cab4640ee3a375da39fdabf0f5a317600b0c263` |
| 临时分支 | `test/m4-native-http-fixture` |
| 原生 worktree / attachment | `/Users/liam/.codex/worktrees/m4-native-http-fixture/20260830_足球记录`；`01a1620a-0182-7f02-a3f2-6bb32dd43d4f` |
| 合并目标 | held `test/m4-e2e-integration`，登记时 `acfd8ae569417e20be4b0b346845f03d0317ab77`；不是 dev 晋级 |
| 静态 ref 观察 | 2026-10-22 读 ref 时目标已到 `04d994899b08fe43ab0642358272664b33b502b9`；未读其目录/WIP，不作为实施输入 |
| 当前可写 | 本计划、`docs/native/tasks/NATIVE-058.md`、`docs/native/validation/NATIVE-058.md` 三文档 |
| 实现拟准入 | `backend/src/device-auth.mjs`、新 `scripts/native/m4-authority-fixture.mjs`、新 `backend/test/native-m4-fixture.test.mjs`，加上述三文档 |

未来只允许这六条精确路径；最小设计不需另建生产模块。`backend/test/support.mjs`、Apple verifier、HTTP / codec / database / authority / lifecycle、全部 Swift/UI/工程/capability/entitlement/锁文件、其他任务卡、其他 worktree 均只读或禁止触碰。不消费026尚未双审接口，不读其 Watch 四路径 WIP。需要扩路径时先向 root 报告具体必要性并更新登记，不能先写。

当前 base 的原生整合源码不包含 held026 的全部当前能力；下游 M4 当前身份文件格式、051 facade / Session 和 Apple/cloud 独立观察门禁只由 root 在026冻结、停写、干净后核对。本任务不照研究稿复制 Swift API，也不编造新 CloudDriver。

## 2. 当前实际源码核准

| 固定 `2cab…` 输入 | 实际 API / 事实 | 计划责任 |
|---|---|---|
| `backend/src/device-auth.mjs:35–61` | `authenticate` 先检查 challenge，await verifier，再在事务内查 absence fence、重查 challenge；44 行内联映射，49 行首次建 active Phone | 只抽取44行表达式；事务、顺序、错误、wire 不动 |
| `backend/src/apple-verifier.mjs:5–6,12–28,34` | `isAppleVerifier` / `isVerifiedApple` 为 WeakMap 品牌；`createDevelopmentAppleVerifier` 返回真实 RS256/JWKS verifier | 新观察强制 genuine development verifier 和 verified identity，复制对象不承接品牌 |
| 同文件22行 | `exp >= now-60`，`iat <= now+60`、`iat <= exp`，没有最大 token 年龄 | 新观察另要求独立新 nonce、本次签发时间和60秒观察生命周期，不宣称旧 verifier 已保证 freshness |
| `backend/test/support.mjs:66–82` | `authSetup(f, options={})` 只需 `f.authority/f.clock`；返回 auth/verifier 及未执行的闭包 | 可以调用 `authSetup`，不得调用其 `login/request/device` |
| `backend/test/support.mjs:10–53,85–102` | `startFixtureAuthority/openHTTPFixture` 会 seed fixture account/phone/session | 新 sidecar 不调用这两个入口 |
| `native/Modules/AccountKit/Tests/AccountKitTests/Support/authority-fixture.mjs:5–9,23–31` | 默认 `f.login()`；启动/Watch 输出另一设备 credential/privateKey | 不修改旧 helper；新 helper 启动与控制 op 不提供设备私钥/凭据 |
| `backend/src/authority.mjs:10–11,87–89` | `createAuthority(options)` 正常初始化 schema；`authorityState` 可取实际 db/config；`close` 清 transient reauth 并关库 | 观察开始前单独记录初始化；观察不调用 auth / recover / lifecycle |
| `backend/src/database.mjs:10–42` | 初始化 metadata、schema、epoch_allocator=0；accounts.active_phone_id NOT NULL | 不手写 accounts 空行，不改 activePhone / 锁 / epoch；逐表快照从初始化后开始 |
| `backend/src/config.mjs:5–13` | 显式绝对 file DB、至少32字节 HMAC/token keys、Ed25519 receipt key；指纹校验 | 同进程 restart 保留同配置/密钥/clock，不对已有库自动重生 keys |
| `backend/src/http.mjs:9,40,49–53` | `createHTTPServer({authority,appleVerifier,deviceAuth,logger,rateLimit})`；只允许 loopback；drop fault 比较内部 method | 复用实际路由，不加身份生产 endpoint；authApple fault 名是 `authenticate` |
| `backend/src/database.mjs:46–59` | 既有 `beforeCommit` / `afterCommitResponseLost` | 原样映射受控 fault；不新增 SQL 故障语义 |
| `backend/test/device-auth-boundary.test.mjs:41–45` | 显式 development legacy verifier 兼容 | 新品牌矩阵只加于新观察；原认证兼容必须完整回归 |
| `backend/test/apple-revocation-support.mjs:6–54` | `startRevocationFixture({clock})`、`registerCode(code,token)`、`revoker`、`close()` | 可按显式 revoker op 启用；复用既有机制，不另造 token exchange/revoke 或 CloudDriver |

`acfd…` 研究材料只作参考。已静态比较2cab→acfd四个 backend 文件：身份映射原式未变，主要差异为052删除控制的路由、nonce budget、purpose gate 和 reauthentication 接缝。未来普通合入026时保留其已审052修改；不得以当前2cab的整段文件覆盖，也不在058内重构 `authority.takeReauthMaterial` 或 `deletion-reauth.mjs` 的同式校验。合入后原backend完整回归必须覆盖052实际新增套件。

## 3. 最小模块边界与协议（均为拟新增 API）

### 3.1 唯一生产触点

在 `backend/src/device-auth.mjs` 导出：

```js
export function accountIDForAppleIdentity(accountHMACKey, identity) {
  return createHmac('sha256', accountHMACKey)
    .update(identity.issuer+'\n'+identity.subject).digest('hex');
}
```

原44行仅改为：

```js
const accountID=accountIDForAppleIdentity(config.accountHMACKey,verified);
```

输入仍为同一个 server key、原 verified.issuer + 单个 LF + verified.subject 的原 UTF-8；保持 lowercase hex。不 trim、不规范化 Unicode、不替换 delimiter、不提前计算或移动 await/事务。纯 mapper 不新增品牌限制，避免改变 legacy development authenticate；新 observer 独立强制品牌。

### 3.2 测试 sidecar 的内部接口

在新 `scripts/native/m4-authority-fixture.mjs` 导出以下测试专用接口，直接执行文件才启动 CLI：

| 拟新增导出 | 参数与返回 |
|---|---|
| `createM4IdentityObserver` | 参数 `{authority,appleVerifier,namespace,getGeneration}`；返回 `beginObservation/observeIdentity/invalidate` 闭包 |
| `openM4AuthorityFixture` | 可选参数 `{databasePath,clock,faults,fetchJWKS}`；返回下述控制闭包；fetchJWKS只传给现有authSetup的真实verifier工厂，CLI不能注入 |

`databasePath` 若未给出，使用专属 `mkdtemp` 下的绝对 `authority.sqlite`；传入时必须是绝对且不存在的新文件，拒绝已有 DB，不自动删除/替换文件或生成一套 key 读旧库。函数只返回公开 `metadata`、`beginObservation()`、`observeIdentity(input)`、`issueApple(input)`、`enableRevoker()`、`setFault(input)`、`restart()`、`close()`；keys/config/deviceAuth 不向 CLI caller 暴露。host 测试自行提供临时新 DB 路径以做只读快照。

默认 clock 为 `{now:()=>Math.floor(Date.now()/1000)}`，与原生实际 Unix 秒对齐且自然推进。host 测试可以注入既有 `fixtureClock(start)`；CLI 无改时钟 op。真实 native 链不能以固定1800000000、伪造现在或时钟跃迁绕过 TTL。

内部启动顺序固定：生成 server-only HMAC/token/receipt keys → `createAuthority(config)` → `authSetup({get authority(){return authority;},clock})` → `createHTTPServer({authority,appleVerifier:setup.verifier,deviceAuth:setup.auth,logger})` → `listen(0,'127.0.0.1')`。不调用 seed/login/request/device，默认无账号、设备、session、challenge、request、活动锁；epoch_allocator=0。schema/metadata 正常初始化单独留证，不把它混入观察零写宣称。

### 3.3 观察生命周期与独立性

`createM4IdentityObserver` 在构造时捕获 actual `authorityState(authority)`、其 config/key/clock、genuine development verifier 和 generation。`beginObservation()` 只在内存分配随机 observationID 与256-bit nonce，返回 `{observationID,nonce,issuedAt,expiresAt}`；有效期60秒，内存 pending 上限128，满时 fail closed，不驱逐仍有效观察。`observeIdentity({observationID,identityToken})` 单次取走该 pending nonce，在 await 前后检查未关闭、同 generation、相同 authority state/config/key对象与key SHA256/config fingerprint/clock/environment 和 genuine verifier；调用 `await appleVerifier.verify(identityToken,pending.nonce)` 后再核 genuine `isVerifiedApple(verified,'development')`、environment、nonce、`pending.issuedAt <= verified.issuedAt <= now <= pending.expiresAt`。成功返回：

```js
{
  kind:'currentIdentity', environment:'development', namespace,
  observationID, accountID:accountIDForAppleIdentity(config.accountHMACKey,verified),
  observedAt:clock.now(), expiresAt:pending.expiresAt
}
```

不得输出 `registered/accountExists/active/activationEpoch/startGrant` 或 credential；不得通过调用 authenticate/recover/login、建立 binding、query行存在性得出观察。pending 失败也单次消费，不改 SQL。nonce 不复用 auth challenge，观察不创建或消费 challenges/auth_records/nonces。重新观察同 issuer/subject 的 accountID稳定；新身份不同。namespace来自当前fixture实例的独立随机 development namespace，不用 accountID、config.subject 或 native客户端HMAC计算替代身份来源。

供后续026使用时，受信任 test harness依据这个服务端观察写入/读取**已有** M4 Apple current identity 输入，并保留其 namespace/environment/observationID/文件权限/anchor校验；058不写 Swift、不手动 bindAccount，不拿客户端 binding 反填观察。CloudKit current identity 仍来自既有独立受控 cloud identity；cloudSpaceID/zoneID不能由此 accountID推导。身份观察不是凭据，不能恢复未知 auth、解除删除/退休 gate或授予开始比赛。

### 3.4 requestID JSON Lines 控制协议

CLI 命令为 `node scripts/native/m4-authority-fixture.mjs`，不需要 root、subject 或设备材料命令行参数。每行最多16384字节，strict JSON/plain object/精确字段集合；`version===1`，control `requestID` 满足既有 `[A-Za-z0-9._:-]{1,128}`，与业务 requestID分离。命令串行处理，每个合法 requestID恰一响应；同进程最多4096个唯一control ID，重复ID返回 `duplicateRequest`，容量满返回 `fixtureUnavailable`，不静默重放密钥材料。未知字段/operation拒绝，不能提供任意 SQL/任意 HTTP代理/任意 key/凭据导入接口。

启动只输出一次：

```js
{version:1,type:'ready',environment:'development',namespace,
 baseURL,publicKey:receiptPublicKey,keyID:receiptKeyID,now:clock.now()}
```

| op / 精确请求额外字段 | 响应 result | 责任 |
|---|---|---|
| `identity.begin` / 无 | `{observationID,nonce,issuedAt,expiresAt}` | 只分配内存观察nonce |
| `apple` / `purpose,nonce,identity` | `{identityToken,authorizationCode}` | purpose仅 `observation/authentication`；identity仅 `primary/alternate`；使用既有 `appleJWT` 对相应固定development signer身份签名，nonce须64字符hex；observation JWT 60秒，authentication JWT 300秒；返回新随机code，启用revoker时用其 `registerCode(code,token)` 绑定；不返回原始subject |
| `identity.observe` / `observationID,identityToken` | 第3.3节 currentIdentity 对象 | 必须真实验签，不能直接从 identity selector或解码结果取ID |
| `revoker` / 无 | `{enabled:true}` | 只启动一次既有 `startRevocationFixture({clock})` 并赋实际config.appleRevoker；不输出其请求/token/keys |
| `fault` / `name,value` | `{applied:true}` | name仅 `beforeCommit/afterCommitResponseLost/dropResponseAfterOperation`；前二为bool，后一仅 `null/challenge/authenticate/recover/registerWatch/recoverWatch/acquire/terminate/liveStatus/peerGrant`，null为关闭；不改SQL/锁/epoch |
| `restart` / 无 | 与ready相同公开metadata（无type字段） | 同进程完整关网关库，原DB/keys/clock/faults/namespace不变，generation递增并废弃未完成观察；重新构造 authSetup/server，baseURL可变 |
| `close` / 无 | `{closed:true}` | 停收新控制命令、await当前控制/HTTP尾部、关闭HTTP、authority、可选revoker，完成后才回复并退出 |

响应统一为 `{version:1,requestID,ok:true,result}` 或 `{version:1,requestID,ok:false,error:{code}}`。非法JSON/非法ID统一 `requestID:'unknown'`。错误code限 `fixtureInvalidRequest/duplicateRequest/fixtureUnauthorized/fixtureUnavailable/fixtureClosed`，不序列化异常对象、body、token、code、issuer、subject。stdout仅协议；stderr仅有限诊断code/operation，不打印stack/request或第三方响应。`apple`回复是显式短期credential交换通道，原生HTTP auth响应也必然给原设备自己的credential；这两类仅交调用者内存，不保存raw transcript、trace或证据。ready/观察/fault/restart/close/error全部无token、code、HMAC key、设备privateKey或credential。

`nonce` 为64个hex字符（32字节值）；计划采用此长度，拒绝空值、其他长度和非hex。identity selector只驱动受控signer发出测试身份，匿名身份结果必须另经genuine verifier，不接受 `config.subject` 的直出或客户端自行计算值。真实Apple账号的授权码/网络调用不在此fixture。

### 3.5 restart / fault / close 的边界

restart仅指同一sidecar进程内 reopen：保留同一文件及WAL、配置密钥、receipt keyID、clock和development namespace。先增加generation并使旧观察失效，再关闭HTTP、等待已进入handler的尾部结束、关authority，最后重新create；不通过Promise.race/短超时或process.exit提前丢尾部。不能仅依赖Node server.close回调推断async handler尾部完成：res.destroy后handler仍可能await。helper在测试sidecar内保留createHTTPServer的原request listener并包装其返回Promise，维护in-flight集合，关闭接收后await该集合以及自有观察/revoker任务，再关authority。包装只调用原handler、不复制HTTP/auth逻辑、不改生产http.mjs。close失败不宣称成功，不抹SQL文件或强行改业务状态。

fault只赋现有mutable faults字段；`beforeCommit`回滚、`afterCommitResponseLost`保留已提交结果、HTTP drop仅丢结果。原始客户端用原request/installation/key按原recover协议恢复；fixture不帮助重新登录、不发第二Phone、不重建auth、清锁或重置epoch。未决结果和故障开关按场景显式解除，不让重启自动“治好”业务。

不新增跨进程secret持久化协议；整个sidecar退出后不会凭旧DB重生keys。需要测试原生进程崩溃时，sidecar继续存活；若以后要求sidecar自身kill后重开，需先登记独立server-only受限密钥保存方案并评审，不用本计划的同进程restart冒充。无需新增生产部署/安全运维系统。

## 4. 分步实施与 TDD

以下运行命令仅供后续实现准入后执行；本轮全部未运行。命令从任务树根执行，Node二进制先按仓库声明核对22.23.1；日志写058独立证据目录，HTTP响应秘密只留测试进程内存。每轮红与绿记录完整命令、exit、时间和输入hash，缺API红不冒充行为反例。

### Task 1：原身份映射纯提取

**Files:** 修改 `backend/src/device-auth.mjs`；创建 `backend/test/native-m4-fixture.test.mjs`。

- [ ] **Step 1 — 写映射固定输入/原式等价测试。** 在新test中导入 `accountIDForAppleIdentity`，用 `Buffer.alloc(32,7)` 和 `{issuer:'https://appleid.apple.com',subject:'fixture-primary'}`，断言如下；再断言同输入稳定、另一subject/issuer/key不同、NFC/NFD原bytes不被归一、空白不被trim。

```js
const expected=createHmac('sha256',key).update(identity.issuer+'\n'+identity.subject).digest('hex');
assert.equal(accountIDForAppleIdentity(key,identity),expected);
assert.match(accountIDForAppleIdentity(key,identity),/^[a-f0-9]{64}$/);
```

- [ ] **Step 2 — 运行红。** `node --test --test-name-pattern='account mapping' backend/test/native-m4-fixture.test.mjs`；先保存缺导出API红。不能把相同内联公式测试当整个task证明，后续真实HTTP结果必须与独立observer比对。
- [ ] **Step 3 — 最小实现。** 加第3.1节完整纯函数，只替换原44行；diff确认原事务/await/absence fence/challenge及所有其他认证行未变。
- [ ] **Step 4 — 运行绿与原兼容回归。** 上述focused命令通过；`node --test backend/test/auth.test.mjs backend/test/device-auth-boundary.test.mjs backend/test/auth-absence-recovery.test.mjs` 应0失败，legacy-dev原41–45行兼容保留。
- [ ] **Step 5 — 提交。** 只stage两个精确路径，`refactor: share server account identity mapping`，body记录实际红绿和无生产wire/事务改动范围。

### Task 2：空 file SQLite + 实时 HTTP 启动

**Files:** 新 `scripts/native/m4-authority-fixture.mjs`；扩同一新test。

- [ ] **Step 1 — 写空启动行为测试。** 使用测试自己的新临时绝对dbPath；打开fixture后通过独立只读连接枚举 `sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'`，对每表按列名、SQLite类型和逐值bytes稳定排序保存逻辑快照；blob转hex，数字/文本不混同。断言所有业务/控制表为空、epoch_allocator恰1行value0、metadata只有合法configuration行；startup无accountID/credential/privateKey/token。
- [ ] **Step 2 — 运行红。** `node --test --test-name-pattern='empty authority' backend/test/native-m4-fixture.test.mjs`；保存缺模块API红后，保留实际零预登录断言，不能靠删断言变绿。
- [ ] **Step 3 — 最小启动实现。** 使用下列真实API接缝，并在同文件加入CLI main guard、keys封闭、read-only公开metadata与await close；不返回setup/auth/config。复用已读 `tempDB()` 可以生成路径，但不调用任何seed入口。

```js
const config={databasePath,accountHMACKey:randomBytes(32),tokenDerivationKey:randomBytes(32),
  receiptPrivateKey:generateKeyPairSync('ed25519').privateKey,clock,faults,environment:'development'};
let authority=createAuthority(config);
let setup=await authSetup({get authority(){return authority;},clock},{fetchJWKS});
let server=createHTTPServer({authority,appleVerifier:setup.verifier,deviceAuth:setup.auth,logger});
const handlers=server.listeners('request');
if(handlers.length!==1)throw Error('unexpected request handlers');
const handler=handlers[0],inflightHTTP=new Set();
server.removeListener('request',handler);
server.on('request',(request,response)=>{
  if(closing){response.writeHead(503,{'content-type':'application/json'});
    response.end('{"code":"unavailable","requestID":"unknown","retryable":true}');return;}
  const task=Promise.resolve(handler(request,response));inflightHTTP.add(task);
  task.then(()=>inflightHTTP.delete(task),()=>inflightHTTP.delete(task));
});
await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
```

本段的 `closing` 是fixture闭包内初始为false的生命周期状态；`logger`是有限code/operation诊断函数，`fetchJWKS`是上述可选测试参数；不向CLI开放。close先 `closing=true` 并调用server.close停止接收，然后 `await Promise.all([closedNetwork,...inflightHTTP,...inflightObservations])` 后关authority；`closedNetwork`用该次server.close回调构造，observer在结束/失败时从集合移除。正常保留库文件，不执行数据擦除。

- [ ] **Step 4 — 运行绿。** focused通过；增加默认clock与 `Math.floor(Date.now()/1000)` 差不超过2秒、短等待后自然前进、loopback host、新DB拒复用和非法路径拒绝。测试用HTTP `/v1/auth/challenges` 验证实际标准路由存在，比较快照时与空启动/观察场景分开，不能混算zero-write。
- [ ] **Step 5 — 提交。** 明确stage新script/test，`test: add empty native authority fixture`；不改旧fixture默认行为或现有测试。

### Task 3：genuine独立观察与零写入

**Files:** 同script/test；不再改生产mapper。

- [ ] **Step 1 — 写成功/拒绝/await边界测试。** 固定时钟、新临时DB和真实development verifier；begin→既有 `appleJWT` 新签短token→observe，断言成功kind/current accountID。成功与所有失败前后逐表完整逻辑快照相等，覆盖metadata/epoch/accounts/devices/sessions/requests/locks/challenges/auth_records/nonces/fences/reauth等所有现有表，不能只比较count。
- [ ] **Step 2 — 写矩阵并运行红。** `node --test --test-name-pattern='identity observation' backend/test/native-m4-fixture.test.mjs`：伪/复制verifier在verify前拒；copied/plain identity不能替代token；production verifier/环境、错误issuer/audience/nonce/signature/alg/kid/kty/use、exp早于now-60、future iat、iat>exp拒；观察nonce过期/重放/错ID/过早签发/容量满/期间generation变化拒。异步暂停用真实verifier的受控fetchJWKS Promise门，不替换genuine verifier.verify；环境/authority切换在await后仍拒且零写。
- [ ] **Step 3 — 最小观察实现。** 按第3.3节状态机实现内存map/gate/一次消费/品牌检查，核心成功路径如下，`gate()`必须逐项执行该节规定的捕获值比较，不能只检查bool或namespace。

```js
const pending=observations.get(observationID); observations.delete(observationID);
if(!pending||clock.now()>pending.expiresAt)fail('unauthorized',401);
gate();
const verified=await appleVerifier.verify(identityToken,pending.nonce);
gate();
const now=clock.now();
if(!isVerifiedApple(verified,'development')||verified.environment!=='development'||
   verified.nonce!==pending.nonce||verified.issuedAt<pending.issuedAt||
   verified.issuedAt>now||now>pending.expiresAt)fail('unauthorized',401);
return {kind:'currentIdentity',environment:'development',namespace,observationID,
  accountID:accountIDForAppleIdentity(config.accountHMACKey,verified),
  observedAt:now,expiresAt:pending.expiresAt};
```

- [ ] **Step 4 — 运行绿。** focused通过；重复新nonce观察同身份结果稳定、alternate不同；观察后仍0账号/设备/session/request/锁且epoch0；无credential、grant、registered或accountExists字段。使用原始HTTP challenge→authApple和测试自生成的第一设备材料，断言receipt为 `registered`、active_phone_id恰该设备、公钥原bytes、epoch1、结果accountID等于此前独立观察；第二Phone仅此场景才额外生成并断言 `waitingMigration`。
- [ ] **Step 5 — 提交。** `test: add verified server identity observation`；body明确仅development sidecar观察，不称真实Apple或051原生链完成。

### Task 4：stdio发行/控制、故障与完整关闭

**Files:** 同script/test。

- [ ] **Step 1 — 写子进程协议测试。** `spawn(process.execPath,[absoluteScriptPath],{stdio:['pipe','pipe','pipe']})`，解析readline；检测启动唯一ready与每个requestID唯一response。以primary/alternate与真实nonce调用apple→observe；token/code仅留内存，持久日志先白名单脱敏。覆盖JSON损坏、重复ID、未知op/字段、超长行、4096ID边界、nonce非法、故障枚举非法；错误无原input回显。
- [ ] **Step 2 — 运行红。** `node --test --test-name-pattern='stdio|fault|restart|close' backend/test/native-m4-fixture.test.mjs`；先保存缺CLI/协议红，再对实际已启动子进程断言，不用mock server绕开HTTP。
- [ ] **Step 3 — 实现精确dispatcher。** 按第3.4节字段表作allowlist解析；响应只从显式result构造，`catch`只映射有限code。apple调用现存 `appleJWT({iss:'https://appleid.apple.com',sub:subjects[identity],aud:'test.football',nonce,iat:clock.now(),exp:clock.now()+(purpose==='observation'?60:300)})`；随机code用 `randomBytes(32).toString('base64url')`，可选现存revoker.registerCode；没有credential/privateKey导入/生成设备op、SQL inspect或生产身份route。
- [ ] **Step 4 — 实现既有fault/restart/close并运行绿。** 映射 `faults[name]=value===null?undefined:value`；restart保留同config/keys/clock/DB并重建setup/server，响应里publicKey/keyID/namespace相等，旧观察因generation失效。真实first-device认证在beforeCommit失败后原事务行全回滚；afterCommitResponseLost/drop authenticate后按原request/key恢复原session且不重消费challenge；reopen后锁/epoch/request原bytes不变。close等待尾部再回复，EOF同样await完整关闭，SIGTERM只触发同一close路径；测试用真实genuine verifier的fetchJWKS Promise门暂停HTTP认证，触发close后证明回复仍待，放行原Promise后才完整退出；确认端口关闭、进程退出0、无提前200ms race。
- [ ] **Step 5 — 扫描秘密并提交。** Sentinel测试检查ready/观察/错误/故障/restart/close和stderr/持久SQL无原subject/code/JWT/HMAC/token/privateKey；只有明确apple回复与标准HTTP登录结果可在调用者内存带所需输入/凭据。`test: add native fixture control protocol`。

### Task 5：固定source回归、双审与held026交接

**Files:** 三文档收尾；只因真实失败修复上述精确script/test/mapper，不跨路径。

- [ ] **Step 1 — 固定source并完整验证。** 单次 `node --test backend/test/native-m4-fixture.test.mjs` 后，在 `backend` 目录单次 `npm test`（实际 `node --test test/*.test.mjs`）覆盖原完整backend，不相加旧161或focused计数。记录新增/总数、失败、所有运行时输入Git blob/hash及原日志；Node版本本轮实际核准才写结果。若052未在本树，明确此轮不含其测试。
- [ ] **Step 2 — 静态与信任检查。** `git diff --check`、明确路径diff、原authenticate除纯映射替换外零行为delta、旧helper/support/HTTP/codec/config/Apple verifier bytes与base相同；确认不开放production、无Swift/工程变更。当前任务为host测试fixture与纯函数提取，真机和SDK编译不适用，真实Apple/CloudKit/WC/Keychain/设备/生产部署不因此通过。
- [ ] **Step 3 — 两位非作者source审阅。** root与独立第二审阅者基于完整source SHA/whole-tree diff、输入副本hash和实际运行证据分别审；核zero seed、真实品牌/nonce/freshness、独立服务端映射、零SQL副作用、无grant/secret泄露、原legacy兼容/事务/旧结果bytes、fault/reopen原始材料。
- [ ] **Step 4 — 文档final与final双审。** 只收尾本计划/任务卡/验证卡；以树外manifest记录actual source/final SHA避免自引用，确认产品/测试输入与source相同且工作树含ignored无遗漏；root与第二位非作者分别核final。作者停写等待，不自行merge/push/archive/delete/rebase。
- [ ] **Step 5 — root普通合入held026。** root先确认026原作者已停写、clean，冻结新完整target；基于真实052 API差异再次核准接缝，不能读取/消费WIP。root `--no-ff` 普通merge058，手工保留双方已审最小修改，不rebase/覆盖目标；记录actual merge SHA/whole tree并重跑新suite和目标完整backend（含052），两位非作者复核精确merge。失败保留独立058树，不能靠清activePhone/锁/epoch或改原051绕过。
- [ ] **Step 6 — 下游验收与生命周期。** 026在原M4/051 facade、Session、installation/key及既有Apple/cloud独立观察文件门禁上做首次真实HTTP链与其余母计划软件链，另登记exact native输入与测试；058通过不替代该验收。全部必需目标接收且无活跃依赖、未提交/未跟踪/必要ignored证据安全保存后，才由root原生archive worktree，核实际成功再 `git branch -d test/m4-native-http-fixture`；queued/拒绝则保留，不盲重试/强删。本树当前是026活跃依赖，必须保留；不晋级dev/release/main。

## 5. 验收结论的允许范围

058未来允许宣称：空file SQLite reference authority、受控development JWT真实密码学验证、服务端独立当前匿名身份观察、原HTTP first-device认证与故障reopen在记录的host范围通过。计划阶段只允许宣称静态计划交付。

不得宣称：账号行已存在、已注册/active/start授权、真实Apple账号或授权码、CloudKit/Keychain/WC/设备验收、原051或026全链已通过、生产trust/provider/bootstrap已开放、跨进程durability/RPO、M4完成或原生发布。既有knownAbandoned/unknown、peer ACK、释放锁与completion的合同证明边界保持。

## 6. 静态计划证据与检查点

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-058`。

- `planning-inputs.json` SHA256 `562d7da0ffdd9b3877274ee9ef756728bb871a51025bb2831cfeb8ec2310b254`：固定2cab的21份Git blob/模式/bytes/hash副本，以及4份acfd研究参考副本与来源hash。
- `planning-initial-git.json` SHA256 `905ac1ddf52a34dc93514bad72ce1a1c69c6e4e4bbce516b7c5ecefbdfe31987`：创建后HEAD/分支/clean含ignored、attachment、original target与ref观察；runtime调用均0。
- `reference-acfd-backend-delta.patch` SHA256 `294801a008474ebb4faa7caf7e4a326005f7672e8e6c85a95550c73978bf1506`：仅固定2cab→acfd的四文件静态差异，不是当前目标工作树输入。
- 文档提交后的whole-tree diff、三文档immutable copy/hash、Git proof、static-check结果和actual最终SHA由树外 `planning-final-manifest.json` / `planning-checkpoint.json` 记录；本文不回写自身提交SHA。

检查点：三文档Conventional `docs` commit后clean停写；root与第二位非作者均审计划通过、root明确准入这三个实现路径之后才实施。当前未运行任何Node/HTTP/SQL/test/build/设备或模拟器探测；未改产品/helper/test；未读026 Watch WIP；未push/merge/archive/delete/rebase。脚本和observer均为未来新增，不当作现存已验证API。
