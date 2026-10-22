# M4 原始当前认证证据只读投影 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. NATIVE-053 唯一作者直接执行本计划；产品开始前须 root 与 026 消费者两位非作者审阅通过。

**Goal:** 原认证 SQL 已提交、App 资源 scope 尚未封存时，从同一原 SQLite 快照恢复经过固定 trust 复验的当前认证证据，供 026 绑定原资源及独立当前身份观察。

**Architecture:** 新增独立 optional read protocol、不可公开构造的 Sendable 证据值，以及原 MatchStore 的纯读取实现；原 SQLiteSessionRepository 仅转发给自己已有的 Store。读取在无 await 的 `BEGIN DEFERRED` 快照内完成，原协议、数据库、业务 gate、认证写入和所有旧编码不变。证据证明本机原已接受 grant 的来源，不授予当前凭据有效性或业务准入。

**Tech Stack:** Swift 6、原系统 SQLite3、CryptoKit、XCTest；最低 iOS 17 / watchOS 10；不新增依赖。

---

## 1. 实际登记与唯一写入范围

- 作者 `/root/m4_auth_evidence`；审阅 `/root` 与 `/root/m4_integration_resume`（026 消费者）。其他作者正在自己的独立工作树开发，不撤销或覆盖他人成果。
- base 为最新已验证 dev `2cab4640ee3a375da39fdabf0f5a317600b0c263`；分支 `feat/m4-current-auth-evidence`。
- 工作树 `/Users/liam/.codex/worktrees/m4-current-auth-evidence/20260830_足球记录`；attachment `01a1613d-2c64-7f30-a713-87f2f531ad4e`；创建操作 `3895f6fe-3fe2-40d6-ae78-6036ced67370`。作者已核初始 HEAD/base/分支及 clean。
- 仅交付 held NATIVE-026；登记目标为 `885f226adf87866854c987fb6ffb4b2e818bb9a4`，实际合并目标由 root 再核。作者不合并、不推送、不归档、不推进 dev/release/main。

唯一六路径，均为新文件：

1. `native/Packages/MatchCore/Sources/MatchStore/AuthenticationEvidence.swift`：optional protocol、factory-only 结果和 Store 只读快照验证。
2. `native/Packages/MatchCore/Sources/MatchSession/AuthenticationEvidenceReader.swift`：原 SQLiteSessionRepository 的 extension-only 转发。
3. `native/Packages/MatchCore/Tests/MatchStoreTests/AuthenticationEvidenceTests.swift`：真实 SQLite/签名/故障/两连接及原 facade 回归。
4. `docs/superpowers/plans/2026-10-22-m4-current-auth-evidence.md`。
5. `docs/native/tasks/NATIVE-053.md`。
6. `docs/native/validation/NATIVE-053.md`。

第 2 路径已由 root 明确补充登记：原 facade 位于 MatchSession，`store` 是该模块 internal 字段，026 或 MatchStore 模块不能自行读取；新文件只 forward，不改任何既有 Session gate 或协议。所有旧 Sources、Package.swift、schema、工程、AccountKit、合同及 052 的 20 路径均不写。

## 2. 现有事实与证明边界

- `AccountLifecyclePersistence.swift:59` 的 `acceptAuthenticationV4` 在一个事务内接受原 attempt + 原固定 trust 签名 receipt，写 binding、`auth-current` 与 `auth-receipt:<ID>`；afterCommit 可在正面事实存在后抛 responseLost。
- `AuthorityPersistence.swift:22` 的 `currentBindingV4` 只读 canonical/checksum 并检查 trust environment；`bindAccountV4` 也能产生 binding，单独的 binding 不等于原认证证明。
- `currentAuthRequestIDV4` 只读字符串。`pendingAuthAttemptsV4` 虽复验签名，却只过滤原 attempt 列表，不能返回与当前 binding 同一快照关联的 grant。
- 原 `identityGenerationV4` 将缺失 identity-generation 行解释为 0；初始认证保存的 auth-admission 合法为 0，不能把这一正常初始状态伪判为缺证明。
- 原 `SQLite.transaction` 是 `BEGIN IMMEDIATE`；本新增读取不用它，使用新文件内 `db.execute("BEGIN DEFERRED")`、SELECT、COMMIT 和错误时 ROLLBACK。actor 内同步，无 await、无 INSERT/UPDATE/DELETE/DDL、无诊断写入或 quarantine。
- `VerifiedAuthorityReceiptV1` 已为非 Codable、私有构造的固定域验签结果。auth receipt 明确签名 requestID/digest/account/epoch/result；device/key/cloud 通过原已持久化 AuthAttempt 与 binding 的一致性关联，receipt 没有这些独立 signed claims。transient auth canonical body 不持久化，因此本功能不重建含 Apple 字段的原请求，也不承诺检测“所有无签名本地 metadata 被协同重写且 checksum 重算”的攻击。026 仍须独立当前身份、原资源 owner、signer/key 与世代/lifetime 检查。
- auth receipt 没有 credential expiresAt；只读复验不把 issuedAt 当作新鲜登录、不检查不存在的凭据 TTL、不把历史本地提交证明当作服务端当前授权。

## 3. 公共类型与错误语义

所有声明位于第 1 新文件：

```swift
public protocol CurrentAuthenticationEvidenceReadingV4: Sendable {
    func currentAuthenticationEvidenceV4(
        expectedIdentityGeneration: Int64
    ) async throws -> VerifiedLocalAuthenticationEvidenceV4?
}

/// Provenance only: this result never admits recording or refreshes a credential.
public struct VerifiedLocalAuthenticationEvidenceV4: Sendable {
    public let binding: AccountBindingV4
    public let identityGeneration: Int64
    public let currentAuthRequestID: String
    public let attempt: AuthAttemptV4
    public let admissionGeneration: Int64
    public let receipt: VerifiedAuthorityReceiptV1
    fileprivate init(binding: AccountBindingV4, identityGeneration: Int64,
                     currentAuthRequestID: String, attempt: AuthAttemptV4,
                     admissionGeneration: Int64, receipt: VerifiedAuthorityReceiptV1) {
        self.binding = binding
        self.identityGeneration = identityGeneration
        self.currentAuthRequestID = currentAuthRequestID
        self.attempt = attempt
        self.admissionGeneration = admissionGeneration
        self.receipt = receipt
    }
}
```

结果不 Codable、无 public/internal memberwise init、无 caller trust 或 verified Bool。协议为独立 capability，不给任何原 repository 增加 required 方法。

| 状态 | 结果 |
|---|---|
| expected generation 非 0...JS-safe 整数 | AuthorityError.invalidWire |
| 原有效 generation 与 expected 不同、原 binding 已 suspended、原 admission 与有效世代不同 | AuthorityError.identityChanged |
| binding/current 指针及所有 auth-attempt/admission/receipt/resolved 行都不存在 | nil；仅表示没有认证证据，不声称目录新建或旧业务为空 |
| 合法 pending attempt，或 Watch binding 没有 Phone auth 指针 | AuthorityError.unavailable；保留原恢复/Watch 路径，不制造 Phone 证明 |
| current 指针存在但 binding/attempt/admission/receipt 缺失、互相矛盾、terminal resolution 存在 | AuthorityError.intentMismatch；不回退到历史 receipt 或另一个 attempt |
| trust 不可用、environment 不一致 | AuthorityError.unavailable |
| checksum/canonical 失败 | 原 StoreError.corruptPayload 或原 decode/AuthorityError.invalidWire，保留全部原 bytes |
| receipt 签名无效、固定 trust key 不含原 key | 原 verifier 的 typed failure |

registered 只能对应未 suspended 的 `.phone`；waitingMigration 只能对应未 suspended 的 `.waiting`。后来的 suspended、Watch 或 migration 改写状态不由历史 auth receipt 补造证明；无法重新建立该当前 tuple 时 typed blocked。026 在已持久化的 waiting attachment 与原 migration 控制证明上恢复过渡，后续实际 active grant 单独接受与封存。

## 4. 快照算法和严格验证

外部 public Store 方法调用同文件内 internal 同步 helper；helper 仅保留一个可选 `@Sendable () throws -> Void` 的 afterSnapshot 测试回调，默认 nil，不增加存储字段或公共配置。回调在首次 generation SELECT 建立快照后、其他读取前执行；测试用第二真实 SQLite 连接提交变更，证明后续读取不会拼接新旧状态。生产入口永不设置回调。

```swift
extension SQLiteSessionRepository: CurrentAuthenticationEvidenceReadingV4 {
    public func currentAuthenticationEvidenceV4(
        expectedIdentityGeneration: Int64
    ) async throws -> VerifiedLocalAuthenticationEvidenceV4? {
        try await store.currentAuthenticationEvidenceV4(
            expectedIdentityGeneration: expectedIdentityGeneration)
    }
}
```

第 2 文件只需 `import MatchStore` 和上面 extension。

Store helper 必须按顺序执行：

1. 校验 expected generation 的非负/JS-safe 范围；BEGIN DEFERRED 在 do/catch 之前成功后才进入事务体。
2. 原 `identityGenerationV4()` 是首次读并建立 SQLite snapshot；使用既有缺失=0 语义。执行可选 afterSnapshot 回调（无 await），随后要求 effective generation == expected。
3. 从同一快照读 original binding 与 currentAuthID。对新查询先用 `length(payload)` 拒绝超预算，再调用原 `checkedV4`/`readLifecycleV4`；单行 payload 上限 32768 bytes，currentAuthID 用原 ASCII identifier grammar，proof raw 仍按原 verifier 的 16384 bytes 上限。SELECT 控制行不无界加载全历史 payload；无 current 时只以 bounded EXISTS/LIMIT 1 查询 auth 行是否存在。
4. 完全无认证事实时返回 nil；pending/Watch/partial 按上表处理。不调用原 pendingAuthAttemptsV4 作为 current proof，不扫描选择一个“看起来已接受”的旧 grant。
5. 由原 currentAuthID 精确读取 `auth-attempt:<ID>`、`auth-admission:<ID>`、`auth-receipt:<ID>`，以及该 ID 的 resolution。任意 resolution 与已接受 current receipt 同时存在均拒绝。auth-admission 必须存在且 == effective generation；不 advance、补写或恢复丢失行。
6. 用 AuthAttemptV4 initializer 重验已读字段与 keyID/publicKey；要求 attempt.requestID == currentAuthID，binding.deviceID/cloudSpaceID/environment 与原 attempt 逐 UTF8 bytes/enum 相等、trust environment 一致，binding 不 suspended，epoch 合法。不能靠 String 规范等价替代原 bytes。
7. 调用原 `VerifiedAuthorityReceiptV1.verify(raw, expected: AuthorityExpectedIntent(requestID:currentID,digest:attempt.requestDigest,operation:.authApple,accountID:binding.accountID,epoch:binding.activationEpoch), trust: Store 自己的 authorityTrust)`。要求 `.registered/.phone` 或 `.waitingMigration/.waiting` 对应，auth-purpose receipt 的 match/lock/recordingDeviceID 为空，migration/peerGrant/registration/lostRecovery/deletion 均 nil。
8. 在同一事务内构造 factory-only 结果；COMMIT 成功后返回。任何失败执行 ROLLBACK；rollback 失败也必须抛出，不静默留下事务占用。没有 await、诊断写入或借用资源关闭。

两个 expected/account/epoch 的来源是同快照原 binding，不是从 receipt 自己取回 expected 值。结果每次调用都重新验证；禁止缓存上一轮成功。

## 5. 具体 TDD 和提交顺序

### 053.1 计划 checkpoint（当前）

- [ ] 仅创建本计划、task、validation 三文档；核对六路径所有权、链接和实际 base。
- [ ] `git diff --check` 及三文档链接检查；本轮不运行产品或预填通过数。
- [ ] 明确路径暂存，提交 `docs: plan current authentication evidence reading`。body 记录 plan-only、未执行产品验证及双审 gate。
- [ ] 给 root 与 026 消费者 exact SHA；等待两位审阅者通过，产品源与测试尚未存在。

### 053.2 编译缺 API 与真实运行 RED 分层

- [ ] 在 owned 新测试定义真实临时 SQLite harness，沿原 LifecycleStateTests 的 key/trust/attempt/receipt 方式调用原 saveAuthAttemptV4 / acceptAuthenticationV4。首个用例完整断言原 raw receipt/binding/attempt/currentID/gen/admission 读回。

```swift
func testCommittedAuthenticationEvidenceReopensOriginalGrant() async throws {
    let fixture = try acceptedFixture(result: .registered)
    try await fixture.store.close()
    let reopened = try fixture.reopen()
    let evidence = try await reopened.currentAuthenticationEvidenceV4(
        expectedIdentityGeneration: 0)
    let value = try XCTUnwrap(evidence)
    XCTAssertEqual(value.binding, fixture.binding)
    XCTAssertEqual(value.attempt, fixture.attempt)
    XCTAssertEqual(value.currentAuthRequestID, fixture.attempt.requestID)
    XCTAssertEqual(value.identityGeneration, 0)
    XCTAssertEqual(value.admissionGeneration, 0)
    XCTAssertEqual(value.receipt.raw, fixture.receipt.raw)
    try await reopened.close()
}
```

`acceptedFixture(result:)` 在该新测试内创建临时路径、原开发固定 trust、AuthAttemptV4，签名原 authority receipt domain，经过原 Store 的 save/accept 两事务，不直接伪造 accepted 行。fixture.reopen() 用同 URL、同 trust 和开发 namespace 新建 Store，不创建新身份/数据库文件；两 handle 操作只在明确测试中使用。

- [ ] 运行 `swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE053-host --filter AuthenticationEvidenceTests.testCommittedAuthenticationEvidenceReopensOriginalGrant`，保留真实 missing API 编译 RED。
- [ ] 新产品仅加入公共声明与返回 `throw AuthorityError.unavailable` 的占位方法，保留相同测试真实运行失败；不把编译 RED 称安全行为红。
- [ ] 实施第 4 节完整快照逻辑以及原 facade forwarding，重跑本用例 GREEN。

### 053.3 原始状态与故障矩阵

所有测试在 owned 新测试文件中调用真实 Store/SQLite，以下是明确断言，不镜像私有 if 条件：

| 命名用例 | 输入及关键断言 |
|---|---|
| testFreshStoreHasNoCurrentAuthenticationEvidence | 原新 Store 返回 nil；generation 仍 0，无新增任何 row |
| testPendingOrPartialAuthenticationDoesNotBecomeEvidence | 只 save 未 accept 的原 attempt、缺 pointer/binding/attempt/admission/receipt 等各自返回 typed failure，原 pending bytes 不变 |
| testCommitResponseLossRetainsExactOriginalEvidence | 原真实 afterCommit Store fault 抛 responseLost，关闭/重开读原 receipt 和原 request，无再认证或重写 |
| testBeforeCommitFaultCannotPublishEvidence | beforeCommit / afterReceipt 回滚无 binding/current/receipt；原 attempt 仍保留且不返回 evidence |
| testWaitingGrantNeverProjectsRegisteredPhone | 真 waitingMigration/.waiting 返回 waiting证据；变 binding role phone 即使 checksum 正确仍失败 |
| testSuspendedOrAdvancedGenerationNeverBorrowsHistoricalGrant | 原 suspendAccountV4 后旧 expected 被拒，新 expected 也不能借旧 admission/receipt；generation/原 raw 不回退 |
| testCanonicalForgedBindingAndPointerCannotBorrowGrant | 对 account/epoch/device/cloud/environment/role 或 currentID 单项合法 canonical/checksum改写；重新调用失败，旧成功不缓存 |
| testOriginalAttemptKeyAndAdmissionMustMatch | keyID、公钥、digest、requestID、admission/current-generation、resolution 等单项损坏或矛盾时失败；原 bytes 不补写 |
| testSignatureUnknownKeyAndUnexpectedPurposeFieldsFailClosed | 坏签名、未知 trust key、非 authApple/result-role、非空 lock/match 或其他 purpose payload 不返回 evidence |
| testOversizedAndNoncanonicalRowsRemainUnmodified | 超过单行预算、raw receipt 超限、unknown JSON字段/重编码不等或坏checksum失败，不 quarantine/修复 |
| testReadSnapshotCannotMixConcurrentBindingAndGeneration | afterSnapshot 回调在第二真实 SQLite连接提交变更；此次只读返回完整旧快照或其合法失败，下一次观察完整新状态，绝不组合旧generation/新binding |
| testReadSucceedsWhileAnotherConnectionHoldsWriter | 第二连接持 BEGIN IMMEDIATE；本 API 在其回滚前通过，证明未抢写锁；无任意 sleep，以 explicit expectation/barrier 收束 |
| testReadHasNoSQLWritesAndReleasesSnapshotAfterFailure | 比较 sqlite schema/user_version、全部表有序行、db total_changes（通过同 actor 测试扩展读取）及相关页/控制 payload；错误后同原连接仍可执行正常读取与后续合法原写入 |
| testOriginalSQLiteSessionFacadeForwardsSameEvidence | 用现有公开 facade构造/save/accept，通过 optional protocol cast 读取，并与同 facade 的 binding/gen/raw 原事实一致；不新建额外 facade 来代理读取 |

- [ ] targeted 新测试真实 RED/GREEN 均保存命令/退出码/原日志；fixture 编译或工具失败单独分层，修正后不称产品行为红。
- [ ] 源码冻结后一次运行完整 Core（四 XCTest 可执行项）和四 fresh MatchSession 最低 SDK 编译；失败归属本任务再修，未改旧模块的 warning 原样保留。
- [ ] 显式暂存三个 owned 新 source/test 文件，提交 `feat: read current authentication evidence from one snapshot`；plan 中必要精确声明调整可同 source 提交但不改旧合同。

## 6. 最终命令与证据

```sh
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE053-host
```

完整计数来自每个可执行项原输出，不把 focused 与 full 相加。四 SDK 的每条命令使用独立 scratch：

```sh
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$SDK_PATH" --triple "$TRIPLE" --scratch-path "$SCRATCH"
```

SDK_PATH 逐条来自 `xcrun --sdk <SDK> --show-sdk-path`，不复用猜测路径：

| SDK | TRIPLE | SCRATCH |
|---|---|---|
| iphonesimulator | arm64-apple-ios17.0-simulator | /private/tmp/football-record-NATIVE053-sdk-ios-sim |
| iphoneos | arm64-apple-ios17.0 | /private/tmp/football-record-NATIVE053-sdk-ios-device |
| watchsimulator | arm64-apple-watchos10.0-simulator | /private/tmp/football-record-NATIVE053-sdk-watch-sim |
| watchos | arm64-apple-watchos10.0 | /private/tmp/football-record-NATIVE053-sdk-watch-device |

树外证据根为 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-053`。保存计划审阅、Git base/parents/branch/ownedfiles、原 RED/GREEN、工具/SDK 版本、完整命令/退出码/count、全部 Core runtime Package/Sources/Tests/Fixtures 的 before/post hash、source Git blob/hash/size、零漂移及 final 再对照。输出不含 token、Apple code、私钥或生产账户信息。

Root 与消费者对 source 双 PASS 后仅两张 task/validation 卡收尾，产品/测试/计划 bytes 保持 source；final 再双审。实际目标合并、merge验证、归档与 safe branch-d 均归 root，依赖未消费前保留工作树。

本任务为本机 SQLite 软件读取，无真实账号、设备或原生服务调用，真机不适用；SDK 仅编译。未运行 App/UI、真实 Apple/Keychain/iCloud/CloudKit/Health/WC、签名、部署或 M4 整包验收，默认生产 provider/bootstrap 继续 Unavailable。
