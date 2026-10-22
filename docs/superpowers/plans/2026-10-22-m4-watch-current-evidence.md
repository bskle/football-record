# M4 Watch 当前接受来源 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. NATIVE-055 唯一作者执行；产品与测试写入前，须 root 与第二位非作者对本计划 exact commit 双审 PASS。

**Goal:** 为未来真正接受 Watch binding 的原事务保存本地来源，并从原 Store 的同一只读快照返回当前 Watch 接受证据，供 026 另行封存资源及检查身份。

**Architecture:** 在既有 lifecycle_steps_v4 表保存一个版本化、固定 key 的本地 current marker，与原 Watch binding、registered receipt 同事务提交。独立 optional reader 从原 SQLite 复验 marker、原 attempt/receipt、当前 admission/binding/generation 与迁移删除控制；原 SQLiteSessionRepository 仅转发。旧历史缺失来源时明确 blocked，不补写、不推断过去的接受事件。

**Tech Stack:** Swift 6、系统 SQLite3、CryptoKit、XCTest；最低 iOS 17 / watchOS 10；不新增包或 schema。

---

## 1. 实际登记与唯一写入范围

- 唯一作者 `/root/m4_watch_provenance`；审阅 `/root` 与 `/root/m4_recovery_audit`。其他作者在独立树工作，不覆盖或撤销其改动。
- base dev `2cab4640ee3a375da39fdabf0f5a317600b0c263`；root 普通 no-ff 接收 053 final `e0b88df9e8d694555f5f597f3eea508d3a1acaf1`、052 final `bcf2c7fc3b0dfd623f5550618dbf2b55fad3369c` 后 effective actual HEAD `27a0aef4dac7f2beb8189303b75a12ac1e1b53da`。
- 分支 `feat/m4-watch-current-evidence`；工作树 `/Users/liam/.codex/worktrees/m4-watch-current-evidence/20260830_足球记录`；attachment `01a1618d-fcd3-71c3-9837-a328568ed713`；operation `f58758dd-6483-4179-8911-ed747156fba2`。作者已核 branch/HEAD 与 clean（含 ignored）。
- 仅交付 held026 `test/m4-e2e-integration`，登记 target `d155eaaeee02384187966f835d85ce94f079c983`；root 接入前重核。作者不 merge/push/archive，不推进 dev/release/main。

| 唯一路径 | 职责 |
| --- | --- |
| native/Packages/MatchCore/Sources/MatchStore/CurrentWatchRegistrationEvidence.swift | 新 marker、严格历史校验、optional reader/结果、同 SQL 只读快照 |
| native/Packages/MatchCore/Sources/MatchStore/WatchRegistrationPersistence.swift | 原 accept 事务调用 marker 接点；历史 getter/协议保持原义 |
| native/Packages/MatchCore/Sources/MatchSession/WatchEvidenceReader.swift | 新文件，只转发原 store |
| native/Packages/MatchCore/Tests/MatchStoreTests/CurrentWatchRegistrationEvidenceTests.swift | 新文件，真实签名/SQL/故障/并发/库存及擦除 |
| native/Packages/MatchCore/Tests/MatchSessionTests/WatchEvidenceReaderTests.swift | 新文件，原 facade capability 与读取转发 |
| native/Packages/MatchCore/Sources/MatchStore/CapturePersistence.swift | 条件所有权：captureInventoryLockedV4 调用新 marker 严格校验 |
| native/Packages/MatchCore/Sources/MatchStore/LifecycleStatePersistence.swift | 条件所有权：擦除前及当前 zero 检查严格校验并保留 marker |
| docs/superpowers/plans/2026-10-22-m4-watch-current-evidence.md | 本计划 |
| docs/native/tasks/NATIVE-055.md | 任务卡 |
| docs/native/validation/NATIVE-055.md | 验证卡 |

两个条件路径有实际必要：现有 inventory/erase/zero 只认识原控制族，新增行若只被 reader 校验，会在删除流程被无条件忽略。仅增加新 helper 调用，不调整业务表清单或 normal-intent/migration-checkpoint 删除谓词，不删除 marker，不修改既有 gate。AccountKit/Backend/wire/SDK/Presentation/Package/project/required protocol/生产 provider 均不写；扩路径须先交 root。

## 2. 已确认事实与方案取舍

原 `watchRegistrationReceiptV4` 只复验历史 attempt 与 signed receipt；`StoredWatchAdmission` 只有 context/publicKey，没有当前 requestID 或已接受 generation。`acceptWatchRegistrationV4` 允许 registered + nil binding，过期恢复可仅持久化 receipt；knownAbandoned 也有历史 receipt。父 Phone/epoch/generation 变更后历史 getter 仍可成功。因此只读查询、pending 为空或分开 await 无法补造过去不存在的 current 来源。

采用原接受事务新增一个 current marker。扫描历史选一条会误把 receipt-only/旧父关系当成当前；扩大 Backend receipt/wire 或改原协议/schema 超出本任务且并非本地证明所需。只向未来确实发生的绑定接受事件写 marker，已存在历史 receipt 的请求永不自动 backfill。

Watch device key ID 必须由原 Watch publicKey 经 `AuthorityWire.deviceKeyID` 派生；receipt.body.keyID 是服务端 authority 签名 key，由 Store 固定 authorityTrust 公钥集合验证，两者不相等也不互相替代。receipt 签名绑定原 requestID/digest/account/epoch/result/Watch registration payload；parent Phone/cloud 来源于原本地 context/admission 与接受 tuple 的一致性，不声称是独立 signed claims。marker 是 checksum/canonical 本地控制事实，不防所有 metadata 协同重写/数据库回滚；026 仍须原资源 owner、独立当前身份、signer 与 lifetime。

## 3. 精确 marker 与接受事务

仅新增固定行 `lifecycle_steps_v4.id = "watch-current-v1"`，保留原表结构及 user_version。固定 key 不拼 requestID，不占用 052 的 requestID 命名族。保留 namespace `watch-current*`，reader/inventory 拒绝该族中未知 key/version 或额外行。

新文件内 internal Codable/Equatable 类型：

```swift
struct StoredCurrentWatchRegistrationV1: Codable, Equatable {
    let version: Int                  // always 1
    let requestID: String
    let requestDigest: String
    let acceptedGeneration: Int64
    let acceptedBinding: AccountBindingV4
    let admittedContext: WatchRegistrationContextV4
    let watchPublicKey: String
    let watchDeviceKeyID: String
    let receiptDigest: String
}
```

marker 不保存 credential/secret/caller trust/verified Bool；原 attempt/raw receipt 仍在原 watch-attempt/watch-receipt 行。admittedContext 是接受时验证的本地 admission/context 快照，不是新签名或补出的 admission generation；acceptedGeneration 明确是本地接受世代。

在原 `acceptWatchRegistrationV4` 一个 `db.transaction` 内：

1. 保持原 expected generation、原 attempt 精确相等、participant 与 fixed trust receipt `.registered` 验证。
2. 在原 binding 写入前读取 prior receipt，并用新 helper 严格校验已有 marker 的历史完整性；保存 `isFirstReceipt = priorReceipt == nil`。原 first-proof raw 冲突继续抛 conflict。
3. 原 nonnil `watchBinding` 分支完成 role/watchID/account/cloud/epoch/environment/unsuspended 和 current-role 检查后，写原 binding。只有此分支且 isFirstReceipt 时，构造 version1 marker：原 attempt requestID/digest、原 effective/expected generation、刚接受的 binding、当前 admission 的已验证 context/key、派生 deviceKeyID、原 verified receipt raw SHA256；以 writeV4 写固定 marker。
4. nil binding 的 Phone authorizer、Watch receipt-only、服务层过期降级 receipt-only 均不写/刷新 marker；closeWatchRegistrationV4 不写 marker，knownAbandoned 永不触发本接点。
5. 同一事务继续写原 receipt，再原 afterReceipt/beforeCommit 故障点；beforeCommit/afterReceipt 回滚 binding+marker+receipt，afterCommit 丢响应保留三者。

重放：首次绑定提交后同 request/raw/gen 重放验证已有 marker而不重写，不改变 acceptedGeneration。旧版本/receipt-only 已存在 receipt、marker 缺失时，保留原接受方法历史幂等行为，**不创建 marker**，current witness 仍 blocked；只有未来新 request 真正首次接受产生来源。较新 request 已替换 marker 后，旧 request 重放不把 marker 指回旧 request；原 participant/generation 检查继续执行。新 request 首次真正绑定可替换通过历史校验的旧 marker，原 attempt/receipt 保留。损坏/未知版本 marker 不被新接受覆盖抹除。

## 4. Optional API、同快照与错误

```swift
public protocol CurrentWatchRegistrationEvidenceReadingV4: Sendable {
    func currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: Int64)
        async throws -> VerifiedLocalWatchRegistrationEvidenceV4?
}
public struct VerifiedLocalWatchRegistrationEvidenceV4: Sendable {
    public let binding: AccountBindingV4
    public let identityGeneration: Int64
    public let currentWatchRequestID: String
    public let acceptedGeneration: Int64
    public let attempt: WatchRegistrationAttemptV4
    public let admittedContext: WatchRegistrationContextV4
    public let watchDeviceKeyID: String
    public let receipt: VerifiedAuthorityReceiptV1
    public let latestMigration: AuthorityMigrationV1?
    fileprivate init(binding: AccountBindingV4, identityGeneration: Int64,
                     currentWatchRequestID: String, acceptedGeneration: Int64,
                     attempt: WatchRegistrationAttemptV4,
                     admittedContext: WatchRegistrationContextV4,
                     watchDeviceKeyID: String, receipt: VerifiedAuthorityReceiptV1,
                     latestMigration: AuthorityMigrationV1?) {
        self.binding = binding; self.identityGeneration = identityGeneration
        self.currentWatchRequestID = currentWatchRequestID
        self.acceptedGeneration = acceptedGeneration; self.attempt = attempt
        self.admittedContext = admittedContext; self.watchDeviceKeyID = watchDeviceKeyID
        self.receipt = receipt; self.latestMigration = latestMigration
    }
}
```

结果无 Codable、无 public/internal memberwise initializer，只有同文件校验 factory 可构造。新Session文件 `import MatchStore`，extension SQLiteSessionRepository conform optional capability，方法体仅 `try await store.currentWatchRegistrationEvidenceV4(expectedIdentityGeneration: expectedIdentityGeneration)`。无新增required方法/extra facade/network/vault/gen mutation/资源关闭。

Store同步helper `checkedCurrentWatchRegistrationEvidenceV4(expectedIdentityGeneration:afterSnapshot:)` 用 `BEGIN DEFERRED`；afterSnapshot 是 internal 默认nil的 `@Sendable () throws -> Void` 测试钩子，生产入口不设。无await；成功COMMIT后返回，任意失败显式ROLLBACK，回滚错误不吞掉。

1. expected generation 仅0...9007199254740991。对identity-generation先查length再读，沿原缺失=0语义，首次SELECT建立snapshot；执行测试钩子后要求effective==expected。
2. marker家族先查 `SELECT id,length(payload),length(checksum),CAST(id AS BLOB) ... WHERE id GLOB 'watch-current*' LIMIT 2`：最多1行、key UTF8精确且只接受watch-current-v1。先限payload32768bytes/checksum64，再调用原checkedV4。binding/attempt/receipt/admission/migration-latest也逐行先限相同预算；receipt raw另沿原verifier16384bytes限制。不无界加载Watch历史payload。
3. marker缺失：当前binding.role.watch或存在watch-attempt/receipt/admission任意事实则unavailable；没有Watch事实且非Watch binding才nil，Phone binding可存在。nil不证明namespace空/新建。有marker则部分/损坏/未知来源blocked，不回退历史。
4. marker历史校验：version1、generation/identifier/hash grammar；原attempt.validate包括device proof/challenge/canonical request；marker requestID/digest与原attempt逐UTF8 bytes相等；重建acceptedBinding/context原initializer，role.watch/未suspended且完整account/cloud/WatchID/epoch/environment一致；marker publicKey/derivedKeyID正确；receiptDigest等于原raw hash；用Store固定trust原verifyWatchRegistrationV4验registered和原purpose字段。历史校验不要求current gen/admission/binding，允许过期marker作为保留控制事实。
5. current检查：currentBinding逐canonical bytes等于marker acceptedBinding、role.watch/未suspended；effective gen==acceptedGeneration。按原WatchID精确读当前StoredWatchAdmission，context/key与marker和attempt字节一致；完整parent Phone/cloud/account/WatchID/epoch/environment全相等。admission不声称含generation，仅marker记录真实接受世代。
6. 同snapshot对migration-latest先限长，再原latestMigrationV4固定验签；存在非activated migration则identityChanged。bounded `deletion:% LIMIT 1`存在即identityChanged，不将坏行解释为空；不写/接受控制。verified latestMigration放入结果，缺失为nil；无删除阻断仅是本次snapshot结论。
7. 每次重验Store trust/environment、原attempt和current tuple后才factory构造；不缓存、不刷新凭据、不允许recording/cloud/WC。

| 状态 | typed结果 |
| --- | --- |
| 非法整数/marker版本或预算 | AuthorityError.invalidWire |
| gen不一致/suspended/current tuple或admission变化/迁移删除阻断 | AuthorityError.identityChanged |
| marker缺失但有Watch事实或Watch binding | AuthorityError.unavailable |
| marker部分缺失、原request/digest/key/receipt矛盾 | AuthorityError.intentMismatch；原conflict沿原typed错误 |
| trust缺失/environment不一致 | AuthorityError.unavailable |
| 原checksum/canonical/signature/key失败 | 原StoreError/AuthorityError/解码typed失败；保留bytes |
| 无Watch事实且非Watch binding | nil，非业务准入 |

## 5. 库存与擦除分类

新 `validateCurrentWatchRegistrationRowsLockedV4()` 仅做第4节marker家族metadata/预算/历史完整性；不要求current tuple/controls、不BEGIN、不写诊断。legacy缺失marker允许库存；unknown/extra/malformed marker拒绝，不通过删除坏行修复。

只在三个原入口增加调用：captureInventoryLockedV4现有deletion-control验证后；eraseLocalBusinessV4任何DELETE前；validateLocalBusinessErasedV4生成zero witness前。保留marker、原watch attempt/receipt/admission和saga/capability；business表/normal-intent/migration-checkpoint沿原策略删除。gen变化/删除后旧marker可通过历史库存验证，但current reader必须拒绝；保留不等于资源授权。

## 6. 任务、TDD、提交与checkpoint

### 055.1 计划（当前唯一准入）

- [ ] 仅本计划+task/validation两draft；检查相对链接/所有权与git diff --check。
- [ ] 指定三路径暂存，提交 `docs: plan current watch acceptance evidence`；body注明plan-only/无新增产品测试。
- [ ] 树外checkpoint记exact SHA、三hash、base/deps/clean；交root+second双审，停写。

### 055.2 原接受事务（Store新文件/新Store测试+原WatchRegistrationPersistence）

- [ ] 新测试自带真实Curve25519 challenge proof和authority domain签名fixture，沿原admit/save/accept非nil Watchbinding；不直接伪造成功marker。
- [ ] 先写 `testFirstWatchBindingAcceptancePersistsMarkerAtomically`：原accept后关库，真实SQLite查watch-current-v1恰1行，重开原receipt/binding不变。旧实现实际缺marker产生断言RED，无需新API；执行前直接保全输入和原log/exit。
- [ ] 实现第3节marker/constructor/历史helper与原事务接点，跑同测试GREEN。新增beforeCommit/afterReceipt/afterCommit独立fixtures，断言三项原子性；同request重放marker bytes不变。
- [ ] 运行 `swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE055-host --filter CurrentWatchRegistrationEvidenceTests`，实际0失败后指定路径提交 `feat: persist current watch acceptance provenance`。

### 055.3 同SQL reader与原facade（新Store/Session文件及两新测试）

- [ ] 写 `testCommittedWatchEvidenceReopensOriginalAcceptance`：原fixture接受关库重开，新API逐项断言rawreceipt/attempt/binding/currentRequestID/accepted与effective gen/parent/cloud/derivedDeviceKey；保留missing-API编译RED，再API仅抛unavailable产生同测试运行RED，第4节实现后GREEN。
- [ ] Session测试自带原签名fixture和同一SQLiteSessionRepository；先capability cast非nil断言在无转发时真实RED，再extension-only转发使同raw/tuple读取GREEN。
- [ ] 增独立拒绝用例：legacy去marker后历史getter仍可读且current unavailable/读取和重放不补写；receipt-only/Phoneauthorizer/knownAbandoned无marker；新request替换+旧重放不倒退；parent/epoch/gen变化后旧getter保留/current拒绝；同gen错binding/admission/key/derivedkey/request/digest/receipt；异purpose签名/unknownauthoritykey；unknownversion/extra marker/超限/坏checksum/noncanonical全部bytes保全。
- [ ] 真实第二SQLite连接在afterSnapshot回调提交gen+binding，当前读返回完整旧snapshot、下一读拒绝旧gen；另一连接持BEGIN IMMEDIATE仍只读成功；全表rows/user_version/同连接total_changes前后精确相等，失败后同连接可正常原写入。无sleep调度。
- [ ] 两测试类focused GREEN后指定路径提交 `feat: read current watch acceptance evidence`；不将cards标完成。

### 055.4 库存/擦除（两conditional consumer+新Storehelper/test）

- [ ] 新fixture真实接受Watch后保留原marker，走独立有效原Phone删除控制fixture（仅测试受控tuple变化），原saga/signedbackend receipt/erase流程；不把Watch witness当删除授权。断言marker/原attempt/receipt/admission及saga/capabilitybytes保留、business清零，current因gen/suspended/deletion拒绝。
- [ ] unknownversion/extra marker/原关联缺失分别送inventory、erase前、zero验证。旧consumer未校验仍成功的真实RED后，加第5节三调用使GREEN；失败前后所有business/controlrows不变，不删除坏行。
- [ ] focused GREEN后提交 `fix: validate retained watch evidence during local erasure`，只暂存两consumer与新helper/test。

### 055.5 同冻结输入完整矩阵与双审

- [ ] 每次红绿执行前直接复制两Package所有tracked Package/Sources/Tests/Fixtures到树外，记录git blob/mode/SHA256/bytes、工具版本、argv/cwd/exit/实际计数/rawloghash；after零漂移。scratch只在/private/tmp。
- [ ] 完整执行下列Core和AccountKit，再四最低SDK。focused已含于full的不叠加；代码变化则重新冻结受影响矩阵。

```sh
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE055-core-full
swift test --package-path native/Modules/AccountKit --scratch-path /private/tmp/football-record-NATIVE055-account-full
SDKROOT055=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$SDKROOT055" --triple arm64-apple-ios17.0-simulator --scratch-path /private/tmp/football-record-NATIVE055-sdk-ios-sim
SDKROOT055=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$SDKROOT055" --triple arm64-apple-ios17.0 --scratch-path /private/tmp/football-record-NATIVE055-sdk-ios-device
SDKROOT055=$(xcrun --sdk watchsimulator --show-sdk-path)
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$SDKROOT055" --triple arm64-apple-watchos10.0-simulator --scratch-path /private/tmp/football-record-NATIVE055-sdk-watch-sim
SDKROOT055=$(xcrun --sdk watchos --show-sdk-path)
xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk "$SDKROOT055" --triple arm64-apple-watchos10.0 --scratch-path /private/tmp/football-record-NATIVE055-sdk-watch-device
```

- [ ] 冻结source，checkpoint列全输入/日志/限制；停写等root+second源码双审。实际Apple/Keychain/iCloud/CloudKit/Health/WC/签名设备/部署/whole026未验，SDK只编译。本机事务/reader不需用户接设备。
- [ ] source两PASS后只改task/validation，提交 `docs: record current watch evidence validation`；product/tests/plan保持source bytes。交exact final增量双审再停写。
- [ ] root负责held026实际no-ff/复验和后续安全归档branch-d；依赖在途保留树，不晋级release/main，不称M4完成。
