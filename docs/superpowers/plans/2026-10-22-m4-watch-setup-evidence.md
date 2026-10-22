# M4 Watch setup 只读证据 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 用户已选择子代理开发；NATIVE-059 唯一作者执行。产品/测试写入前，须 root 与第二位非作者对本计划 exact commit 双审 PASS，作者随后只按 root 的明确放行继续。

**Goal:** 从原 Store 的单个受检快照，在无需 Phone context 或 relay 的本地 preflight 中，区分空 setup 与同一原 Watch identity/key 的唯一 admission，并只返回原受检 admitted context，供 026 随后精确核对 fresh Phone context 再重试原协议。

**Architecture:** 新增独立 optional setup reader，返回 factory-only、非 Codable 的只读 projection。原 SQLiteSessionRepository 只转发原 store；055 current reader、原 Watch 服务和持久化顺序保持不变。任何注册、已封闭、Phone/control 或未知历史均拒绝，不能把当前接受证明失败解释为空 setup。

**Tech Stack:** Swift 6、系统 SQLite3、CryptoKit、XCTest；最低 iOS 17 / watchOS 10；无新依赖、schema 或工程配置。

---

## 1. 登记、基线与所有权

| 字段 | 本轮事实 |
| --- | --- |
| 任务 / 唯一作者 | NATIVE-059 / `/root/m4_watch_setup_evidence` |
| original base | latest verified dev `2cab4640ee3a375da39fdabf0f5a317600b0c263` |
| 已接收依赖 | accepted 055 final `b355b5c6e93fd811cba959d5257836de1d47bca5`，由 root 普通 no-ff 接入 |
| effective plan base | actual HEAD `1a72c21b5b44b6f436006a4d50273c0e27dc22fb`，全树等于 055 final，初始 clean 含 ignored |
| 临时分支 | `fix/m4-watch-setup-evidence` |
| 原生 worktree | `/Users/liam/.codex/worktrees/m4-watch-setup-evidence/20260830_足球记录` |
| attachment | `01a16211-394f-7a81-9e14-6e2e24f3a1f6` |
| 唯一接收目标 | held026 `test/m4-e2e-integration`，登记测试 checkpoint `2bb9842867b10d6bb3013f537dcb2a1df4c592b4`；接入前由 root 重核且目标 clean/stopped |
| 审阅 / 晋级 | root + 第二位非作者计划/source/final 各双审；本叶子不入 dev/release/main |

本轮只写下表前三份文档，禁止实现、测试运行及 Swift/Node/HTTP/SQL/build/device/simulator 探针。将来实现仅准入后四个路径；不能消费其他作者工作目录或未审 API，不能撤销、覆盖其他作者成果。

| 精确路径 | 本轮 / 后续职责 |
| --- | --- |
| `docs/superpowers/plans/2026-10-22-m4-watch-setup-evidence.md` | 本轮：本计划 |
| `docs/native/tasks/NATIVE-059.md` | 本轮：任务、所有权、审阅及生命周期 |
| `docs/native/validation/NATIVE-059.md` | 本轮：静态证据与未执行范围；后续逐层登记 |
| `native/Packages/MatchCore/Sources/MatchStore/WatchRegistrationSetupEvidence.swift` | 后续新增：optional protocol、factory-only projection、受检快照 |
| `native/Packages/MatchCore/Sources/MatchSession/WatchEvidenceReader.swift` | 后续仅追加原 facade forwarding |
| `native/Packages/MatchCore/Tests/MatchStoreTests/WatchRegistrationSetupEvidenceTests.swift` | 后续新增：真实 Store/SQL/签名/预算/快照测试 |
| `native/Packages/MatchCore/Tests/MatchSessionTests/WatchEvidenceReaderTests.swift` | 后续追加：原 facade/Provider/coordinator 正例及 055 回归 |

不改 `CurrentWatchRegistrationEvidence.swift`、`WatchRegistrationModels.swift`、`WatchRegistrationPersistence.swift`、AccountKit、任何 026/058 源、required protocol、Package/lock、project/scheme/target/capability/entitlements；不改 wire、PoP、schema、原服务或持久化时序。需要扩路径时先提交具体理由，由 root 重新审阅所有权，不自行扩写。

## 2. 已固定问题、R59-P1 修订与证据界限

旧计划 commit `de7b9c357e789825be04429c28dc3dbdb830365f` 因 R59-P1 未获准实现：mandatory context 参数会要求 026 在本地辨别 legacy/history 前调用 `watchRelay.registrationContext()`；这是实际 context exchange，不是本地 getter，重开 owner 也无现成完整 context getter，因而违反四入口零 dispatch。本次只修订三文档，不实现或运行。移除 reader 的 context 输入，projection 只返回受检 `admittedContext?`；先本地拒绝历史，再由 026 获取 fresh context、比对并复读 setup。旧 de7 计划/副本/checkpoint 与审阅报告保留，不改写；修订提交重新接受 root 与第二位非作者 exact 计划审。


R26-W1 的 rejected source 为 `04d994899b08fe43ab0642358272664b33b502b9`。原 `WatchRegistrationService.admitCurrentIdentity(context:)` 先通过原 coordinator 提交 `watch-admission:<device>`，之后才调用首次 challenge HTTP、校验响应及 signer；`saveWatchRegistrationAttempt` 在这些步骤之后，登记转发又在 save 之后。首次 HTTP503、非法 challenge 或 signer 失败可留下纯 admission，尚无注册 requestID/attempt 可恢复。

055 `currentWatchRegistrationEvidenceV4` 在缺 current marker 且存在 admission history 时抛 `AuthorityError.unavailable`，这仍是正确语义。`pendingWatchRegistrationAttemptsV4()` 过滤已有 receipt 的历史，不能证明没有 registered/closed/legacy/partial 历史；binding nil 和分开多次 await 也不能证明 setup 状态。

原作者的固定实际 HTTP503 RED checkpoint 为 `2bb9842867b10d6bb3013f537dcb2a1df4c592b4`：1 项、5 个断言失败、0 unexpected；所有 retry 前的纯 admission 前置通过。它只证明原 026 缺陷，不是本叶子的 RED/GREEN，也不把旧 freshIntegration269/0、root 四 SDK 解释为通过该新测试。本轮只读固定 JSON，未读活跃 026 工作树或重跑该测试。

`StoredWatchAdmission` 实际只有 `{context, publicKey}`，deviceID 位于行 key；没有 admitted generation、challengeID 或 requestID。原 admission 方法可在更高 epoch 时推进 generation 并覆盖 context。因此本 projection 只能证明同快照当前 generation、当前保留 admission 的完整原 bytes 关联及其余事实缺席；不证明首次 admission generation、历史从未 commit、数据库未回滚或所有 metadata 未被协同改写。不能从中恢复或猜测旧 requestID。

## 3. 精确最小 API

在新 Store 文件定义以下新接口；以下名称是本计划新增项，不冒称基线已有 API。原 required repository 协议不添加方法。

```swift
public protocol WatchRegistrationSetupEvidenceReadingV4: Sendable {
    func watchRegistrationSetupEvidenceV4(
        expectedIdentityGeneration: Int64,
        deviceID: String,
        publicKey: String
    ) async throws -> CheckedLocalWatchRegistrationSetupEvidenceV4
}

/// One local read snapshot, only for original protocol setup.
public struct CheckedLocalWatchRegistrationSetupEvidenceV4: Sendable {
    public enum State: Sendable, Equatable { case empty, admissionOnly }
    public let state: State
    public let identityGeneration: Int64
    public let watchDeviceID: String
    public let watchPublicKey: String
    public let watchDeviceKeyID: String
    public let admittedContext: WatchRegistrationContextV4?
    fileprivate init(state: State, identityGeneration: Int64,
                     watchDeviceID: String, watchPublicKey: String,
                     watchDeviceKeyID: String, admittedContext: WatchRegistrationContextV4?) {
        self.state = state; self.identityGeneration = identityGeneration
        self.watchDeviceID = watchDeviceID; self.watchPublicKey = watchPublicKey
        self.watchDeviceKeyID = watchDeviceKeyID; self.admittedContext = admittedContext
    }
}
```

结果无 public/memberwise initializer、Codable、原始 receipt、binding、permit、credential 或 ready 字段。`.empty` 必须 `admittedContext == nil`，不编造调用方 context；`.admissionOnly` 必须带受检原 admission 的完整 `admittedContext`。reader 不要求也不获取 fresh Phone context，结果不声称该 context 是 Phone 当前观察，不能据其推断旧 epoch 是否仍有效。两类都只准后续显式原协议 setup；均不是 055 accepted/current 证据或录制准入。外部不能自行构造一个正例；协议仍可被测试 double 实现，026 必须使用原受管 facade，不能把任意实现当生产凭据。

MatchStore 提供同步 actor 方法作为 async protocol witness，并增加仅 internal 测试 hook：

```swift
func checkedWatchRegistrationSetupEvidenceV4(
    expectedIdentityGeneration: Int64, deviceID: String, publicKey: String,
    afterSnapshot: (@Sendable () throws -> Void)? = nil
) throws -> CheckedLocalWatchRegistrationSetupEvidenceV4
```

原 facade 只追加以下转发，不 reopen DB、不缓存结果、不创建另一 Store：

```swift
extension SQLiteSessionRepository: WatchRegistrationSetupEvidenceReadingV4 {
    public func watchRegistrationSetupEvidenceV4(
        expectedIdentityGeneration: Int64, deviceID: String, publicKey: String
    ) async throws -> CheckedLocalWatchRegistrationSetupEvidenceV4 {
        try await store.watchRegistrationSetupEvidenceV4(
            expectedIdentityGeneration: expectedIdentityGeneration,
            deviceID: deviceID, publicKey: publicKey)
    }
}
```

## 4. 同一快照的严格生产规则

先核 `AuthorityWire.identifier(deviceID)`、`AuthorityWire.deviceKeyID(publicKey:)`，expected generation 在 `0...9_007_199_254_740_991`。要求原 Store 的固定 `authorityTrust` 存在，按实际 `syncEnvironment` 的 production/development case 核其固定 environment；不接收调用方提供另一份 trust 或任何 Phone context，不触发 relay。若 snapshot 有 admission，再对实际 stored context 重跑 `WatchRegistrationContextV4` initializer、要求 deviceID 与其 phoneID 原 UTF-8 不同，并核其 environment 等于原固定 trust。

然后只开一次 `BEGIN DEFERRED`。先 budget/read 原 identity-generation 以建立快照，调用 internal hook，再比 expected generation；不在任何 await 中持有事务。其余完整检查、结果构造及 COMMIT 都在同一个同步 actor 调用；任意失败 ROLLBACK 并抛原 typed error。不得嵌套 `db.transaction` 或另一个 reader 的 BEGIN。

复用实际 internal helper：055 的 `watchEvidenceBudgetV4(table:id:)` / `watchEvidenceValueV4(_:id:)`、原 `identityGenerationV4()`、`checkedV4(_:row:table:key:)` / `readLifecycleV4(_:_:)`、`StoredWatchAdmission`。`checkedV4` 已验证 SHA256、decode 和 canonical 回编码 bytes 相等；重新调用 context initializer 补上 Codable 不重跑 initializer 的约束。原 `db.validateLocalErasureLayoutV4()` 是 internal、read-only，复用其 schema4 exact layout/quick_check 拒绝未知表、列或 trigger，不调用任何擦除方法。

AuthenticationEvidence 的 budget/value/locked helper 是 private；052 的 read/source/history/proof helper 是 private，公开 context 会开 `BEGIN IMMEDIATE`。不能假定它们是可复用 API。052 的 `validateDeletionControlRowsLockedV4()` 虽为 internal，但 setup 要求全部 delete-control history 缺席，直接有界 presence 拒绝即可，不能把其合法保留控制当空 setup。

### 4.1 lifecycle 全行 allowlist 与预算

不以“已知坏 prefix”黑名单判空。只允许最多两行：可选 exact `identity-generation` 与可选 exact `watch-admission:<expected deviceID>`。全行 metadata 查询使用 `LIMIT 3`，先检查行数、原 key bytes 与长度，不能先加载任意大 payload/id：

```sql
SELECT length(CAST(id AS BLOB)), length(payload), length(checksum),
       typeof(id), typeof(payload), typeof(checksum),
       substr(CAST(id AS BLOB),1,161)
FROM lifecycle_steps_v4 ORDER BY rowid LIMIT 3
```

- 最多 2 行，key 原 bytes 长度 1...160、SQL type 为 text；从有限 BLOB 用严格 UTF-8 解码，并验证解码再编码与原 bytes 相等。NUL、非法 UTF-8、非 exact key、第二 admission 或未知状态拒绝。
- 仅允许的行，payload SQL type 必须 blob、每行 0...32,768 bytes，checksum SQL type text 且 length 64，总 payload 至多 65,536 bytes。先 budget 再 decode，不能 SELECT 全部大 payload 后才限量。
- generation 行若存在必须经原 `identityGenerationV4()` 完整 checksum/canonical/range 核验；缺行沿原语义为 0，不新增行。
- admission key 必须与 `watch-admission:` + 输入 deviceID 原 bytes 精确相等。经 `watchEvidenceValueV4(StoredWatchAdmission.self,id:)` 完整校验原 admission checksum/canonical bytes；重建实际 stored context，核其 account/cloud/phone identifier、epoch 正数/上限、environment 与 fixed trust、phoneID 不等于原 Watch deviceID；严格公钥解码/keyID，公钥 UTF-8 与输入相等，再原样返回完整 `admittedContext`。没有 expected context 参数，不能在此承诺与尚未获取的 fresh Phone context 相等。
- 没有 admission 返回 `.empty` + `admittedContext:nil`；有且仅有上述原 admission 返回 `.admissionOnly` + 原完整 `admittedContext`。非零 generation 也只按本快照与 expected 值核验，不声称它是首次 generation。有效但属于旧 Phone epoch/身份的 stored context 不会因某个不存在的 expected context 参数被拒绝；其 freshness 与完整身份不匹配必须由 026 在本地 preflight 之后、原服务之前拒绝。

任何 `watch-attempt:*` / `watch-receipt:*` / `watch-current*`（包括合法 closed、legacy registered 缺 marker、孤立/partial/损坏变体）、`auth-*`、`control-queue:*`、`lifecycle-result:*`、`normal-intent:*`、`migration-*`、`deletion:*`、`delete-control-*`、`analytics-state` 或未知行都拒绝，不因其“已完成”而过滤。

### 4.2 其他 schema4 表的存在性检查

原 own-base `SessionDependencies.swift:66–90` 只建目录、原 Store 与内存 sync identity；`PersistentDeviceIdentityProvider`（同文件 122–158）把 `football-record.identity.v1:<UUID>` 写在独立 URL 文件，只读 `matchIDs()`，不把 identity 写进 SQL。`MatchStore.init` / `SQLite.init` 建 schema/user_version/WAL/FULL，无 application 默认 INSERT、无 SQL meta/deviceidentity 表。schema 定义、autoindex、PRAGMA 不是 application rows，保留；provider 文件不由本 reader 读取、删除或重写。

因此本叶子允许上述正常初始化，但要求下列真实 38 张非 lifecycle 表逐表 `SELECT 1 FROM <literal table> LIMIT 1` 为零；只用代码内固定表名，任一存在都拒绝，无需解码其大 payload：

```text
account_binding_v4 control_intents_v4 authority_results_v4 authority_projection_v4
peer_grants_v4 peer_contexts_v4 peer_inbox_v4
cloud_applied_batches_v4 cloud_checkpoints_v4 cloud_records_v4 cloud_history_v4
cloud_cursors_v4 cloud_deletions_v4
matches events commands outbox inbound diagnostics completion
capture_identities capture_revisions capture_operations capture_operation_history
business_outbox commands_v2 completion_confirmations completion_v2
sync_delivery_v3 sync_fragments_v3 sync_context_v3 sync_registry_v3 sync_routes_v3
sync_sequences_v3 sync_inbox_v3 sync_acknowledgements_v3 sync_ack_controls_v3
sync_receive_progress_v3
```

此清单只以已核原生初始化为依据；本轮未验证 held026 的真实 M4 make 在所有表的初始化结果。后续 026 的 R26-W1 实际 make 转 GREEN 是必须门槛；若另有正常事实，由 root 按 actual 差异收口，不能清默认数据、放行未知历史或随意扩大 allowlist。

### 4.3 typed 拒绝与无 mutation

| 情形 | 确定行为 |
| --- | --- |
| expected generation/device/key 或实际 stored context 无效、预算/SQL类型/key非法 | `AuthorityError.invalidWire` |
| 缺固定 trust | `AuthorityError.unavailable` |
| trust/sync/stored context 环境、原 device/key 或 expected generation 不符 | `AuthorityError.identityChanged` |
| 任意其他事实/历史、第二 admission、未知状态 | `AuthorityError.unavailable`；不降级 `.empty` |
| 允许行 checksum/canonical 损坏 | 原 `StoreError.corruptPayload`；DecodingError 在本边界映射为 `AuthorityError.invalidWire` |
| schema、SQLite、close 或 rollback 错误 | 保留原 typed Store/SQLite 错误；不能 catch 后返回正例 |

只执行受检 SELECT/只读 PRAGMA 与 BEGIN/COMMIT/ROLLBACK。不调用 admit/save/accept、vault、网络、signer、resource factory、close、清数据或 repair。成功与失败均测试全表 rows、user_version 和本连接 total_changes 原样，错误后读事务已释放。

## 5. root 后续交给 026 的消费契约（不在本任务实现）

026 原作者仅可在显式 `.registerWatch`、无绑定且无 Watch pending 的原 unbound managed-empty Watch owner、无 attachment/capsules/pair seal 时请求 setup projection；必须从原 facade 读取。不得把它通用替换全动作的 055 pre-gate：`.signIn` 与没有 attempt 的 `.recover` 不因此获得 fresh 资格；原 Phone pending auth recover 和已有 Watch pending 的原 ID recover 继续原路径。纯 admission 的重试是用户显式 registerWatch，不推断旧 registrationID。

消费顺序必须保持如下，不得先拿 context 再本地分类：

1. 只用原 generation、原独立 installation deviceID 与原 signer publicKey/keyID，调用本地 setup reader。遇 legacy/receipt-only/closed/partial/未知历史立即 typed 拒绝，**此时 relay context exchange、register dispatch、vault/SQL修复计数均为零**；不能从配置或缓存补 context。
2. 仅本地 `.empty` / `.admissionOnly` 正例后，才调用实际 relay 获取 fresh 完整 Phone context。核 fresh 独立 identity、完整 account/cloud/phone/epoch/environment、原 bytes 与原 owner/signer 相符。若首个 projection 有 admittedContext，必须与 fresh context 的完整 canonical/raw 关联逐字节相等；empty 的 nil 不冒称已匹配 Phone，也不把历史 context 当 fresh getter。
3. 任意 await 后复核原 owner/lifetime、独立 identity/device/key、原 generation。用相同 expected generation/device/key 再读本地 setup，比较两次原 state、optional admittedContext（nil状态及完整 canonical bytes）、device/publicKey/keyID/generation 全等。若首次 empty 在 await 中变成 admissionOnly，或任何 context/key/generation 变化，即拒绝，不把它视作本次可继续的新 setup。
4. 只有上述全部通过才调用原 `WatchRegistrationService.admitCurrentIdentity`。随后仍由原服务控制 admission、challenge、签名、保存 attempt、转发、接受和 vault 时序；这些步骤及其最终 tails 仍受原 generation/lifetime 检查。

026 必须新增 fresh Phone context 的 account/cloud/phone/epoch/environment 逐项不匹配、原 admission 与 relay context 不同、复读 state/context/key/generation 变化、重开无缓存 context、四 legacy 入口零 context-exchange/零 dispatch 回归。它们属于 026 消费测试，不伪装成本 reader 的 expected-context 权限保证。

只有原请求尚未持久化且原服务尚未向 registerWatch 发送时，本地受检 setup 才允许显式重新取 challenge、创建注册 requestID。HTTP challenge 成功本身不等于 registerWatch 已发送；一旦存在 attempt/unknown，不用本 API 换 ID，只能原 requestID recover。knownAbandoned 证明原 attempt 封闭而非历史从未 commit；本叶子仍拒绝其历史，不开放 closed/abandoned 后的新登记，也不宣称当前已有受验证的 fresh 后续流程。它只解决未形成 attempt 的纯 setup 重试，其他流程保持原 scope，后续另案处理。

禁止 catch 055 异常或 nil 当 fresh、清 admission、造 current marker/placeholder attempt、猜旧 ID、切 Phone 或从旧 receipt 回填证明。055 对纯 admission 继续 unavailable。legacy registered 缺 marker、receipt-only、closed/unknown attempt、partial/corrupt 四类入口仍须零网络、零 vault、零 SQL 修复。真实注册后仍必须重新取得 055 current proof、精确原 scope/pair seal、credential TTL、独立身份/generation/lifetime/common gate，才能 ready。

本叶子只交 reader，不改 026/058 composition。root 在双审后的 leaf final no-ff 合入 clean/stopped026，再由原 026 作者实现消费与 real M4 regression/reopen、fresh full Integration 和相关 SDK；叶子通过不替代这些门槛。

## 6. TDD 实施任务（本轮全部未执行）

### Task 1: 新 reader 的真实空库与唯一 admission 正例

**Files:** Create Store 新文件和 Store 新测试文件，路径见第 1 节；其他源不写。

- [ ] 在新测试类中复用已存在的 `LifecycleStateTests.context()/store()` 及 `CurrentWatchRegistrationEvidenceTests` 的 internal `attempt(_:key:requestID:context:)` / `signed(_:attempt:result:extra:)` 来构造实际密钥、原 Watch attempt 和签名 receipt；`write/mutate` 也是该测试类 internal，可显式实例化 helper 调用。其 `watchEvidenceTestState` 是 fileprivate，不能从新文件调用：在新测试文件自身定义同类只读全表快照 helper，保存所有 SQLValue、user_version 与 total_changes。
- [ ] 先写下列正例；新 API 未定义造成的编译诊断单列，不称 runtime RED。添加最小可编译 fail-closed scaffold（第 3 节全部 public shape + factory 始终抛 unavailable），再执行新类，捕获至少这两个实际断言失败，0 unexpected；不要用“未找到 API”当行为失败。

```swift
func testPureOriginalAdmissionIsSetupOnlyAnd055StillRejects() async throws {
    let helper = CurrentWatchRegistrationEvidenceTests()
    let c = try helper.h.context(), key = Curve25519.Signing.PrivateKey()
    let attempt = try helper.attempt(c, key: key)
    let store = try helper.h.store(c)
    _ = try await store.admitWatchRegistrationContextV4(
        attempt.context, deviceID: attempt.payload.watchID,
        publicKey: attempt.payload.watchPublicKey)
    do {
        let value = try await store.watchRegistrationSetupEvidenceV4(
            expectedIdentityGeneration: 0, deviceID: attempt.payload.watchID,
            publicKey: attempt.payload.watchPublicKey)
        XCTAssertEqual(value.state, .admissionOnly)
        XCTAssertEqual(value.admittedContext, attempt.context)
        XCTAssertEqual(value.watchDeviceKeyID,
            try AuthorityWire.deviceKeyID(publicKey: attempt.payload.watchPublicKey))
    } catch { XCTFail("the exact original admission must remain setup-retryable: \(error)") }
    do {
        _ = try await store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: 0)
        XCTFail("setup evidence cannot become current registration provenance")
    } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    try await store.close()
}
```

- [ ] 增加 `testFreshNativeStoreReturnsCheckedEmptyAndWritesNothing`：真实新 Store+固定 trust；只给原 device/key 与 expected generation，无 Phone context、无 admission，返回 `.empty`、generation0、原 device/key 全等及 `admittedContext == nil`；全表/user_version/changes 不变。再测试关闭重开相同 Store URL、同固定 trust 后两正例仍成立。
- [ ] 按第 4 节实现完整最小快照；给 metadata/38表检查使用新文件 private literal helpers，所有 helper 必须同步、不另开事务。跑新类 GREEN，保留输入副本、raw log、argv/exit/实际 counts。
- [ ] 明确路径提交 `fix: expose checked Watch setup evidence`；body 记录该阶段真实 RED/GREEN 和剩余负例，不声称全包通过。

### Task 2: 全历史、canonical、预算和真实并发拒绝矩阵

**Files:** 仅同一 Store 新文件与 Store 新测试文件。

- [ ] 逐行实现下表，使用真实 SQL fixture / canonical bytes / 原签名；每项成功或拒绝后均比完整 SQL 快照。不能只 mock reader、造 bool 或清空数据使测试成功。

| 测试方法 | 构造与断言 |
| --- | --- |
| `testRegisteredLegacyWithoutMarkerNeverBecomesSetup` | 用原 save+accept 产生真实签名 registered，再由测试 SQL 仅去 marker；新 reader 拒绝，055 也拒绝，原历史 receipt bytes 保留 |
| `testAnyAttemptReceiptCurrentOrClosedHistoryBlocks` | 分别原 pending、真实 knownAbandoned close、registered receipt-only（nil binding）、孤立 receipt、只有 current/partial current；均拒绝，不能借 pending 过滤 |
| `testForeignMultipleAndUnknownRowsBlock` | 同 device 换 key、异 device 唯一 admission、第二 admission、大小写/非法 UTF-8/NUL/partial key、未知 lifecycle row；原 rows 全保留 |
| `testStoredContextIdentityAndGenerationAreChecked` | 对实际stored admission分别放非法account/cloud/phone identifier、Watch等于phone、epoch0/越界、不同fixedtrust环境，全部拒绝；expectedGeneration±1、负数/越界也拒绝。有效完整stored context原样返回，不声称fresh；freshPhonecontext/account/cloud/phone/epoch不匹配移交026消费测试 |
| `testCanonicalChecksumTypesAndBudgetsFailClosed` | allowed generation/admission checksum坏、JSON缺字段/额外字段/非canonical/错误SQL类型；payload32,769、id161、3行；先metadata限量，拒绝且不rewrite |
| `testPhoneControlMigrationDeletionAndAllOtherTablesBlock` | 遍历实际38表各自插入一条符合该表原schema的 fixture；Phone/watch/waiting/suspended binding；auth-current/attempt/admission/receipt/resolved、migration-latest/checkpoint、deletion/delete-control未知版本、analytics-state；每次拒绝 |
| `testSnapshotNeverMixesOriginalAdmissionWithSecondConnection` | 原连接先读generation建立snapshot后，hook用真实第二 SQLite connection 同事务改 admission完整context及generation、保持原device/key；第一次只得旧generation+原完整admittedContext且不混新值；下一次旧expected被拒。用新expected和原device/key可读取新合法stored context，但不因此把它认作fresh；另以第二连接换key仍拒绝原key输入。026复读比较必须拒绝原state/context/key/generation变化 |
| `testDeferredSnapshotDoesNotNeedWriterAndFailureReleasesIt` | 第二连接持BEGIN IMMEDIATE，reader仍可读旧已提交snapshot；expected错拒绝后释放，writer提交后下一读见新事实，无事务遗留 |
| `testUnknownSchemaOrPartialFactsArePreserved` | 加未知table/trigger或缺失原layout，reader typed拒绝；不迁移、不修schema、不清事实 |

- [ ] 对新增可执行测试先在相应 guard 尚缺的最小 producer 上取得实质 runtime 失败，再补最小 guard；保存分层 RED/GREEN。编译失败、工具/沙箱阻断单列，不充当运行红。
- [ ] focused 命令运行三个原/新类，确认 055 不因 setup reader 改义；每次实际计数按 log 登记，不预填数量。

```sh
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE059-focused --filter 'WatchRegistrationSetupEvidenceTests|CurrentWatchRegistrationEvidenceTests|WatchEvidenceReaderTests'
```

- [ ] 明确两路径提交 `test: cover Watch setup history and snapshot boundaries`，修复若有须在同 owned 新 Store 文件；不修改 055 factory 或测试。

### Task 3: 原 facade、持久 identity 与 coordinator 真实正例

**Files:** 只追加原 `WatchEvidenceReader.swift` 与 `WatchEvidenceReaderTests.swift`。

- [ ] 写 `testOriginalFacadeSetupReaderUsesPersistentIdentityAndCoordinator`：真实原 facade、原 namespace、固定 trust；创建 `PersistentDeviceIdentityProvider(url:repository:)`，读取/重读同 identity 文件；以实际 `MatchSession` 作为 `WatchRegistrationCoordinator` 提交唯一 admission（原协调方法位于 `WatchRegistrationCoordinator.swift:10–29`），构造如下；不存在额外的默认 coordinator 或 write-lane factory。先写断言，再用第 3 节最小原 facade forwarding 修复能力缺失；nil cast 通过 XCTFail 报 runtime RED，不强制 unwrap 成 unexpected。

```swift
let session = MatchSession(
    store: facade, deviceIdentity: provider, clock: SystemSessionClock(),
    ids: UUIDSessionIDFactory(), permits: UnavailableStartPermitProvider(),
    workout: UnavailableWorkoutGateway(),
    environment: .development(databaseNamespace: "watch-setup-evidence"))
let deviceID = try await provider.localDeviceID()
_ = try await session.admitWatchRegistrationContext(
    context, deviceID: deviceID, publicKey: publicKey)
let facadeIdentity = await facade.syncRepositoryIdentity()
let coordinatorIdentity = await session.syncRepositoryIdentity()
XCTAssertEqual(facadeIdentity, coordinatorIdentity)
```

- [ ] 同时构造第二个独立 namespace/facade：第一个为 admissionOnly，第二个仍 empty，两个 `syncRepositoryIdentity()` 不同。关闭重开原 facade，provider identity bytes/原 request相关历史/DB rows 不变，原 admission 可读；不把另库结果当原 owner。
- [ ] 写 `testSetupEvidenceDoesNotChangeOriginal055Behavior`：空 facade 的055仍nil，纯admission的055仍unavailable；随后只走原 save+真实signedaccept，055返回其原完整证据，新setup reader拒绝；原 `testOriginalFacadeExposesOnlyItsOwnWatchEvidenceReader` 保持不改，并运行通过。
- [ ] facade 初始化的 namespace 必须与上述 `watch-setup-evidence` 相同；原 `MatchSession` 的内部 authority mutex/lifetime 保持。禁止为便于测试改 required protocol 或共享工程。focused runtime GREEN 后明确两路径提交 `fix: forward original Watch setup reader`。

### Task 4: 完整本地矩阵、whole source/final 双审与交付

**Files:** 产品/测试仍限四路径；更新本任务两卡。计划通过后内容保留，必要修订另提交重审。

- [ ] 每个新执行层之前，直接复制实际 tracked runtime 输入并记录 Git mode/blob/SHA256/size、工具版本/实际argv/cwd/时间；之后逐项比无漂移。Core完整输入包括其实际 Fixtures/依赖，不仅四个 changed files。不同source、focused/full与编译诊断分层，旧055或026计数不相加。
- [ ] 执行一次 fresh full Core，期望 exit0、实际 XCTest 数/0 failure/0 unexpected；focused已含在full中，不重复累计。

```sh
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE059-core-full
```

- [ ] 执行下列四个最低 SDK MatchSession 构建（包含 Store）；在执行记录中保存当次 `xcrun --show-sdk-path` 的实际路径，不把命令模板当成功。各使用独立scratch目录，期望四个exit0。

```sh
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator --scratch-path /private/tmp/football-record-NATIVE059-sdk-ios-sim
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --triple arm64-apple-ios17.0 --scratch-path /private/tmp/football-record-NATIVE059-sdk-ios-device
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --triple arm64-apple-watchos10.0-simulator --scratch-path /private/tmp/football-record-NATIVE059-sdk-watch-sim
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$(xcrun --sdk watchos --show-sdk-path)" --triple arm64-apple-watchos10.0 --scratch-path /private/tmp/football-record-NATIVE059-sdk-watch-device
```

- [ ] 静态核 ownership、全tree diff、Conventional commits、文档链接/事实、未提交/未跟踪/ignored，并冻结完整 source SHA、输入/证据manifest；停写交 root 和第二位非作者 whole-source 双审。作者自审不算双审。
- [ ] 双审PASS后只收尾任务/验证两卡，提交 final 并停写；两位审阅者复核 exact final、产品/输入bytes与source一致。root 决定 no-ff 到 clean/stopped held026并核 actual merge，作者不merge/push/rebase/archive/delete。
- [ ] 原026作者独立实现第5节消费、原真实HTTP503同owner+重开GREEN、新fresh full Integration及相关SDK；失败保全并重新收口。未完成前059保留活跃依赖，不提前归档；目标接收且依赖结束、全部成果保存后由root native archive、确认实际完成再safe `git branch -d`，queued请求不盲重试/强删。

## 7. 两个计划检查点的静态证据与限制

本轮以 writing-plans / receiving-code-review 和 commit-conventions 编制计划；路径定位先以 `rg --files` 核准，避免把猜测文件名当接口事实。作者只读子任务已在同一 own base 完成 helper inventory 后停读，无第二 writer。

原 de7 计划层树外 `E059 = /Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-059/planning`。直接保存 own effective base 全部 **402** tracked blob 的实际文件副本、mode/Git blob/SHA256/bytes；manifest `effective-base-input-manifest.json` SHA256 `452d3f65251e7830ce946a69cbb739dab29f6bcb315600cb957cd86ac68353f5`，直接bytes与Git全部相等。固定四份026 JSON另存副本与hash，不读取其活跃树。

本次修订独立保存于 `E059v2 = /Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-059/planning-v2`。编辑前直接冻结 de7 全405份tracked实际输入；`base-plan-input-manifest.json` SHA256 `0fc88ce5af64b9f9a1ca5faf9acd853a4dc2deb28d144ac69cd305bd66202e5f`。root R59-P1报告 `plan-review-root-de7b9c3.json` SHA256 `f01396a9472b636a915689ac57340f47b227e32e9c6f0dd8a3f01f001b96c827` 固定副本单列。旧de7计划/checkpoint/输入不覆盖；修订完整tree与增量diff、全部类型/签名/示例一致性、两卡链接及新commit绑定独立checkpoint/manifest。原effective-base402份非本任务输入保持。

两层计划均只有文档/只读源码/Git/文件hash/链接/diff静态检查；零 Swift/Node/HTTP/SQL/tests/build/device/simulator运行。真机不适用：本轮仅规划；后续叶子只验本机Store/reader及SDK编译。它不证明实际Apple/Keychain/iCloud/CloudKit/Health/WC、真实配对/账号/签名/安装/部署、原协议E2E、整包026/M4或App/UI，production仍Unavailable，main/release及原型tag不动。
