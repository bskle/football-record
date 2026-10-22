# M4 账号最终投影检查 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. NATIVE-056 唯一作者执行；产品与测试写入前，须 root 与第二位非作者对本计划 exact commit 双审 PASS。

**Goal:** 让原 AccountStatusModel 在全部异步持久读取之后、发布身份已核对的 UI 投影之前，同步执行调用者提供的附加否决检查。

**Architecture:** 增加兼容的 `finalCheck: @MainActor () throws -> Void` overload，沿用原 repository、binding 字节比较、generation 与 model lifetime 检查。检查不逃逸、不存储、不认证，也不读取或构造外部 authority；执行后再次核对原 model token/stopped，随后在无 await 的同一 MainActor 段发布投影。

**Tech Stack:** Swift 6、Observation、XCTest、原 SQLiteSessionRepository；最低 iOS 17 / watchOS 10，无新依赖。

---

## 1. 登记、所有权与交付边界

- 唯一作者 `/root/m4_presentation_publish`；非作者审阅 `/root`、`/root/m4_recovery_audit`。其他作者在独立树工作，不覆盖、撤销或混入其改动。
- 原始及 effective base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，来自已验证 dev。root 已在创建前登记任务/owner/base/target/五路径，创建后核对 actual HEAD、分支与 clean（含 ignored）。作者复核结果一致。
- 分支 `fix/m4-account-final-publish`；树 `/Users/liam/.codex/worktrees/m4-account-final-publish/20260830_足球记录`；attachment `01a16197-99bc-71f0-9989-31f43c8d06d6`；operation `da2132a5-a435-4986-86f8-7e11836caea2`。
- 仅交付 held026 `test/m4-e2e-integration`，登记 target `d155eaaeee02384187966f835d85ce94f079c983`；root 接入前重核实际 target。作者不 merge/push/archive，不推进 dev/release/main。

| 唯一路径 | 责任 |
| --- | --- |
| native/Modules/MatchPresentation/Sources/MatchPresentation/AccountStatusModel.swift | 兼容 guarded overload、最终同步检查、回调后 token/lifetime 校验 |
| native/Modules/MatchPresentation/Tests/MatchPresentationTests/AccountStatusTests.swift | 沿原真实 repo/held-read fixture 的基线、运行红绿、兼容与重入回归 |
| docs/superpowers/plans/2026-10-22-m4-account-final-publish.md | 本计划 |
| docs/native/tasks/NATIVE-056.md | 任务卡 |
| docs/native/validation/NATIVE-056.md | 验证卡 |

禁止写 Apps/026、MatchCore/AccountKit/CloudSync、shared configuration、Package、scripts 或其他树。需要扩路径先向 root 报告。树外日志、直接输入副本和 checkpoint 放在 `E/NATIVE-056`，其中 `E=/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation`。

## 2. 现存行为与选定接口

当前 `AccountStatusModel.swift` 的公开 `admitIdentity(_:expectedIdentityGeneration:)` 先通过 internal read seam 读取 PresentationAccountAdmissionRead，再 await 原 repository generation；原 token/stopped、binding 各字段 UTF8 bytes、expected/read/durable generation 等全部匹配后，直接设置 checkedIdentity/identityVerified 并 apply。`canEnterRecording` 不依赖 026 的 composition.admittedScope。调用方在方法返回后才检查 credential TTL，不能证明真实 ready 赋值前已经检查。

最小变更保留原公开签名和 internal read 调用的源码兼容；不新增 staged token、provider、配置或 authority DTO。以下为实施目标完整方法块：

```swift
  /// Called only after the identity service has admitted the current identity.
  /// This checks its projection against durable truth; it does not authenticate.
  public func admitIdentity(_ binding: AccountBindingV4, expectedIdentityGeneration: Int64) async throws {
    try await admitIdentity(binding, expectedIdentityGeneration: expectedIdentityGeneration, finalCheck: {})
  }
  /// Runs an additional synchronous veto after durable projection checks.
  /// Passing this check does not authenticate or grant business authority.
  public func admitIdentity(_ binding: AccountBindingV4, expectedIdentityGeneration: Int64,
                            finalCheck: @MainActor () throws -> Void) async throws {
    try await admitIdentity(binding, expectedIdentityGeneration: expectedIdentityGeneration,
      read: { try await PresentationAccountAdmissionRead.read(self.repository) }, finalCheck: finalCheck)
  }
  func admitIdentity(_ binding: AccountBindingV4, expectedIdentityGeneration: Int64,
                     read: @MainActor () async throws -> PresentationAccountAdmissionRead,
                     finalCheck: @MainActor () throws -> Void = {}) async throws {
    guard !stopped else { throw AuthorityError.identityChanged }
    let token = UUID(); generation = token; identityVerified = false; checkedIdentity = nil; phase = .suspended
    let value = try await read()
    let durableGeneration = try await repository.identityGenerationV4()
    guard !stopped, generation == token, expectedIdentityGeneration >= 0,
          value.identityGeneration == expectedIdentityGeneration, durableGeneration == expectedIdentityGeneration,
          let current = value.binding, !current.suspended, !binding.suspended,
          presentationBindingsEqual(current, binding) else { throw AuthorityError.identityChanged }
    try finalCheck()
    guard !stopped, generation == token else { throw AuthorityError.identityChanged }
    checkedIdentity = (current, expectedIdentityGeneration); identityVerified = true
    apply(current, authIDs: value.authIDs, watchIDs: value.watchIDs)
  }
```

原 read、两次 generation、byte equality 与 pending/waiting/production unavailable 语义不删减。新增检查仅能附加否决；无返回 proof、verified Bool、新 public init、SQL/网络/vault 写入。throw 沿原 async throws 传播；本次 admission 在开始就已经清旧 verified 状态。同步 callback 可调用 pauseIdentity/stop/requireReload，故 callback 后再次核原 generation/stopped；保留其收紧状态，不在失败分支写回旧投影。检查与 callback 后重核至 apply 之间无 await。

026 的最后独立身份观察、完整当前 auth tuple、原资源 owner/pair seal 与原 credential 策略由 026 自己实现。本接口只提供最终同步 veto 发布点；不声称 external identity/SQLite/vault 全局原子，也不提供未来有效期 lease。026 在本任务 source/final 双审并由 root 实际接入相关复验之前不消费提案 API。

## 3. 测试内容

所有新增测试写在原 `AccountStatusTests.swift`，复用该文件的 `accountRepository`、private binding helper 和原 AccountActionGate；无 mock authority 或额外 repository facade。以下方法放入该文件已有 AccountStatusTests extension。

### 3.1 原 API held-read 基线

```swift
  func testLegacyAdmissionHeldReadPublishesOriginalProjectionWithoutExtraVeto() async throws {
    let repo = try accountRepository("legacy-final-check-baseline"), b = try binding(.phone)
    try await repo.bindAccountV4(b)
    let model = AccountStatusModel(repository: repo, development: true, action: { _ in })
    let entered = expectation(description: "legacy read held"), gate = AccountActionGate(entered)
    let expiresAt = Date().addingTimeInterval(1)
    let admission = Task {
      try await model.admitIdentity(b, expectedIdentityGeneration: 0, read: {
        let value = try await PresentationAccountAdmissionRead.read(repo)
        XCTAssertLessThan(Date(), expiresAt)
        await gate.hold(); return value
      })
    }
    await fulfillment(of: [entered], timeout: 3)
    XCTAssertFalse(model.canEnterRecording)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while Date() < expiresAt && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertGreaterThanOrEqual(Date(), expiresAt)
    await gate.release(); try await admission.value
    XCTAssertTrue(model.canEnterRecording)
    try await repo.close()
  }
```

这是兼容基线，表示原 API 不检查该外部期限，不能写成产品缺陷 runtime RED。它先在原未改产品上真实执行并保存 argv/log/exit/input bytes；新 guarded API 另测拒绝，旧 API 保持既有兼容责任。

### 3.2 guarded held-read 实际过期与同步否决

```swift
  func testFinalCheckRejectsCredentialExpiredWhileOriginalReadWasHeld() async throws {
    let repo = try accountRepository("final-check-expiry"), b = try binding(.phone)
    try await repo.bindAccountV4(b)
    let model = AccountStatusModel(repository: repo, development: true, action: { _ in })
    let entered = expectation(description: "guarded read held"), gate = AccountActionGate(entered)
    let expiresAt = Date().addingTimeInterval(1)
    var checks = 0
    let admission = Task { () -> AuthorityError? in
      do {
        try await model.admitIdentity(b, expectedIdentityGeneration: 0, read: {
          let value = try await PresentationAccountAdmissionRead.read(repo)
          XCTAssertLessThan(Date(), expiresAt)
          await gate.hold(); return value
        }, finalCheck: {
          checks += 1
          XCTAssertFalse(model.canEnterRecording)
          guard Date() < expiresAt else { throw AuthorityError.staleAttestation }
        })
        return nil
      } catch { return error as? AuthorityError }
    }
    await fulfillment(of: [entered], timeout: 3)
    XCTAssertFalse(model.canEnterRecording); XCTAssertEqual(checks, 0)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while Date() < expiresAt && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertGreaterThanOrEqual(Date(), expiresAt)
    await gate.release(); let error = await admission.value
    XCTAssertEqual(error, .staleAttestation); XCTAssertEqual(checks, 1)
    XCTAssertFalse(model.canEnterRecording); XCTAssertEqual(model.phase, .suspended)
    try await repo.close()
  }
  func testFinalCheckThrowClearsAnEarlierReadyProjection() async throws {
    let repo = try accountRepository("final-check-throw"), b = try binding(.phone)
    try await repo.bindAccountV4(b)
    let model = AccountStatusModel(repository: repo, development: true, action: { _ in })
    try await model.admitIdentity(b, expectedIdentityGeneration: 0)
    XCTAssertTrue(model.canEnterRecording)
    do {
      try await model.admitIdentity(b, expectedIdentityGeneration: 0, finalCheck: {
        XCTAssertFalse(model.canEnterRecording)
        throw AuthorityError.unavailable
      })
      XCTFail("additional veto must propagate")
    } catch { XCTAssertEqual(error as? AuthorityError, .unavailable) }
    XCTAssertFalse(model.canEnterRecording); XCTAssertEqual(model.phase, .suspended)
    try await repo.close()
  }
```

Date 真实流逝决定过期，ContinuousClock 只限制测试等待；不注入 production fake clock，不把固定 sleep/yield 次数当并发证据。原 read hold 是实际 barrier；callback 在 hold 时不执行、释放后拒绝，不能提前检查后跨 await 继续 ready。

### 3.3 原持久拒绝与同步 callback 重入

```swift
  func testDurableRejectionDoesNotCallFinalCheck() async throws {
    let repo = try accountRepository("final-check-durable"), b = try binding(.phone)
    try await repo.bindAccountV4(b)
    let model = AccountStatusModel(repository: repo, development: true, action: { _ in })
    let wrong = try AccountBindingV4(accountID: "other", cloudSpaceID: b.cloudSpaceID,
      deviceID: b.deviceID, activationEpoch: b.activationEpoch, role: b.role, environment: b.environment)
    var checks = 0
    for (value, generation) in [(b, Int64(1)), (wrong, Int64(0))] {
      do {
        try await model.admitIdentity(value, expectedIdentityGeneration: generation, finalCheck: { checks += 1 })
        XCTFail("durable mismatch must reject before veto")
      } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
      XCTAssertFalse(model.canEnterRecording)
    }
    XCTAssertEqual(checks, 0); try await repo.close()
  }
  func testSynchronousFinalCheckCannotRevivePausedStoppedOrReloadedModel() async throws {
    for change in ["pause", "stop", "reload"] {
      let repo = try accountRepository("final-check-reentry"), b = try binding(.phone)
      try await repo.bindAccountV4(b)
      let model = AccountStatusModel(repository: repo, development: true, action: { _ in })
      var checks = 0
      do {
        try await model.admitIdentity(b, expectedIdentityGeneration: 0, finalCheck: {
          checks += 1
          switch change {
          case "pause": model.pauseIdentity()
          case "stop": model.stop()
          default: model.requireReload()
          }
        })
        XCTFail("synchronous tightening must invalidate original publication")
      } catch { XCTAssertEqual(error as? AuthorityError, .identityChanged) }
      XCTAssertEqual(checks, 1); XCTAssertFalse(model.canEnterRecording)
      XCTAssertEqual(model.phase, change == "stop" ? .unavailable : .suspended)
      XCTAssertEqual(model.requiresReload, change == "reload")
      try await repo.close()
    }
  }
```

既有 `testCheckedAdmissionRejectsEveryChangedBindingFieldAndGeneration`、raw Unicode bytes、held read pause/stop/refresh/reload/newer/durable 与 requiresReload/stopped context 测试全部原样保留。新 tests 不用 callback 改 binding 或造 authority，只检查发布边界。

### 3.4 新旧正路径与原 phase 兼容

在既有 `testCheckedAdmissionUsesPersistedBindingAndKeepsWaitingPendingUnavailableGates` 的每个旧 admission 及原断言之后，插入 guarded 同等调用，不替换原调用：

```swift
      var readyChecks = 0
      try await model.admitIdentity(b, expectedIdentityGeneration: try await repo.identityGenerationV4(),
                                    finalCheck: { readyChecks += 1 })
      XCTAssertEqual(readyChecks, 1)
      XCTAssertEqual(model.phase, role == .waiting ? .waitingMigration : .ready)
      XCTAssertEqual(model.canEnterRecording, role != .waiting)
```

原 unavailable model 旧断言之后插入：

```swift
      var unavailableChecks = 0
      try await unavailable.admitIdentity(b, expectedIdentityGeneration: try await repo.identityGenerationV4(),
                                          finalCheck: { unavailableChecks += 1 })
      XCTAssertEqual(unavailableChecks, 1)
      XCTAssertEqual(unavailable.phase, .unavailable); XCTAssertFalse(unavailable.canEnterRecording)
```

原 Phone pending 旧断言之后插入：

```swift
        var pendingChecks = 0
        try await model.admitIdentity(b, expectedIdentityGeneration: try await repo.identityGenerationV4(),
                                      finalCheck: { pendingChecks += 1 })
        XCTAssertEqual(pendingChecks, 1)
        XCTAssertEqual(model.phase, .pending); XCTAssertFalse(model.canEnterRecording)
```

passing veto 不绕过 pending/waiting/production 的原 gates；两种 API 的结果同等。guard 不授予 recording 或认证能力。

## 4. 执行、验证与提交步骤

### 056.1 计划 checkpoint（本轮唯一授权写入）

- [ ] 仅写本计划和 task/validation draft；核三个相对链接及五路径所有权。
- [ ] `git diff --check`，只暂存三个文档，提交 `docs: plan final account projection checks`；body 写 plan-only、无产品测试执行、硬件不适用。
- [ ] 树外 checkpoint 保存 exact plan commit/base/三文档 mode/blob/SHA256/bytes/clean（含 ignored），交 root+second 后停写。不得自动进入后续步骤。

### 056.2 原行为基线与明确分层的 RED

- [ ] root+second plan PASS 且 root 明确放行产品后，先仅添加 3.1 的原 API 测试，运行下面 exact filter；预期基线 PASS，记录实际计数而非预填。

```sh
swift test --package-path native/Modules/MatchPresentation --scratch-path /private/tmp/football-record-NATIVE056-host --filter AccountStatusTests.testLegacyAdmissionHeldReadPublishesOriginalProjectionWithoutExtraVeto
```

- [ ] 加 3.2/3.3 测试与 3.4 guarded 调用，原产品未提供 overload 时运行 `--filter AccountStatusTests`，将 missing-symbol/argument 编译失败独立保全，不称 runtime RED。
- [ ] 先加入第2节的 overload 和默认 internal 参数，但暂时不调用 finalCheck、无新增 callback 后检查。运行 3.2 的 exact expiry 测试与 3.3 reentry 测试，预期真实断言 RED：veto 调用次数0、过期返回 nil/ready、未执行同步收紧。保全该运行的直接输入、日志与实际失败计数，不提交忽略 veto 的临时实现。
- [ ] 实现 `try finalCheck()`，暂时不加 callback 后 guard；运行 3.3 reentry exact filter，预期真实 RED：pause/reload callback 后仍错误发布，stop 内部 phase 被覆盖。此诊断层只证明重入缺口，不写成最终实现。保全直接输入与日志。

### 056.3 最小实现与 targeted GREEN

- [ ] 落实第2节完整方法块，最终同步 callback 后加 `guard !stopped, generation == token`，其后原赋值/apply 之间无 await。
- [ ] 运行完整 AccountStatusTests（包含真实 TTL、throw、durable mismatch、重入、旧 gates），预期0失败。逐项检查仍使用原 repository，callback未存储/no escaping/public verified flag，其他 source 零改动。
- [ ] 指定两路径暂存，提交 `feat: check final account projection before publication`，body 只写本轮真实运行结果和未验边界；不携带日志/临时失败实现。

### 056.4 source 固定矩阵

每次执行前直接复制以下四包所有 tracked `Package.swift`、`Sources`、`Tests`、`Fixtures` 运行时输入至树外，并记录 git mode/blob/SHA256/bytes；运行后重扫，要求0漂移。保留工具版本、cwd、literal argv、exit、实际 XCTest 数、原始日志 hash。scratch 和 SDK build 各自隔离；源变化则废止旧 current source 结论，重新冻结受影响矩阵。focused 已包含在 full 中，不叠加计数。

```sh
swift test --package-path native/Modules/MatchPresentation --scratch-path /private/tmp/football-record-NATIVE056-presentation-full
SDKROOT056=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$SDKROOT056" --triple arm64-apple-ios17.0-simulator --scratch-path /private/tmp/football-record-NATIVE056-sdk-ios-sim
SDKROOT056=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$SDKROOT056" --triple arm64-apple-ios17.0 --scratch-path /private/tmp/football-record-NATIVE056-sdk-ios-device
SDKROOT056=$(xcrun --sdk watchsimulator --show-sdk-path)
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$SDKROOT056" --triple arm64-apple-watchos10.0-simulator --scratch-path /private/tmp/football-record-NATIVE056-sdk-watch-sim
SDKROOT056=$(xcrun --sdk watchos --show-sdk-path)
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$SDKROOT056" --triple arm64-apple-watchos10.0 --scratch-path /private/tmp/football-record-NATIVE056-sdk-watch-device
```

- [ ] source checkpoint 列 exact SHA、五路径 diff、直接 before/after/current 输入等同、全部分层日志和实际计数；停写交 root+second whole source review。
- [ ] 不运行其他包 host tests/App/XCUI，不能把四 SDK compile 写成设备验证。原协议/账号、录制、锁、Cloud、WC、Health 和 026 consumer 尚未从本任务获得新能力。真机不适用：本任务只改软件查询投影的同步否决接缝。

### 056.5 final 文档与交付

- [ ] source 双审 PASS 后只更新 task/validation 两卡，保留产品/测试/plan 精确 source bytes，提交 `docs: record final account projection validation`。
- [ ] final checkpoint 记录 parent/source/final、两卡增量、产品输入不变、clean（含 ignored），交 exact final 双审再停写。
- [ ] root 后续普通 no-ff 接入 held026，验证 actual merge SHA 相关输入/Presentation/Integration；026 在该实际 producer 可用后才继续自己的资源封口，不提前称 M4 完成。root 执行后续归档和 safe branch-d，作者不提前操作。

## 5. 自检

接口名与当前 model/test 精确匹配；原 read seam 是测试既有接口，新增 default 参数兼容其旧调用。新增 guard 不改变 durable checks 或原 phase 优先级；callback 后同步 recheck 防止收紧状态被复活。基线 PASS、缺 API 编译失败、忽略 veto 运行失败、缺 post-callback guard 运行失败及最终 GREEN 各自保存，不混称原实现已有该 API。没有新增 provider/authority/时钟或额外数据访问，没有跨所有权改造。
