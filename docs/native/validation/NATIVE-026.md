# NATIVE-026 validation

Only actual results are recorded. Product slices and wholecombinedcandidate remain in progress. See [task](../tasks/NATIVE-026.md) and [plan](../../superpowers/plans/2026-10-20-m4-local-integration.md). Dependency025/037/024/028 historicalcounts are notsummed asone026run.

## Dependency merge static layer

Rootinitiated037 ordinarymerge completed as `b795132c6a085f220cf31d375e127ebade7c35bf`. Author explicitlystaged onlysevenregisteredconflicts; otheracceptedinput wasautostaged byGit. FourSwiftfrontendparses, project+fourInfoplutil, bashsyntax, brokerPythonAST, pbxref/dedup, Debug/Releaseisolation anddiffcheck passed. This didnotperform typecheck orhost/App/UI.

Onepathrangeassertion firstsaw duplicatepaths from unresolvedmerge; unique-setverification passed withoutproductedits. Reviewthen found theWatchoverview optionalaction typeerror; originalmerge history ispreserved.

## Watch optional action: actual compile red and green

- Redinput `ef6d86efce52ead420d922d193bcc2a0de2a866f`: WatchMatchView.swift:95 optionalclosure cannot bepassed toButton; xcodebuildexit65.
- Greenproductinput committedas `cd84cfac144cbc4ccca7e8fd9b9e39be3e3cd94b`: one-lineif-let, absentaction hidesbutton. Samecommand exit0/BUILD SUCCEEDED.
- Command: `xcodebuild -project native/FootballRecord.xcodeproj -scheme FootballRecord-Watch -configuration Debug -destination 'generic/platform=watchOS Simulator' -derivedDataPath /private/tmp/football-record-NATIVE026-build/merge-watch/DerivedData CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build`.
- Raw `/private/tmp/football-record-NATIVE026-build/merge-watch/red.log` SHA256 `9deaf9142a8f6eb3fd4311750cf6f630ca6cfd75c94197ff88b5d1bd1cb88343`.
- Raw samefolder green.log SHA256 `72871c4bffd98994235c829c45befc170cf62f6067a10cf71af9877a03611fa0`.
- PriorCore unused-value andAppIntentsmetadata warnings retained. NoApp execution, realSDKservices, accounts, signing ordevices. Notwhole026acceptance.

## Product slices and final gates

026-1/3 record actualred/green andexactsourcecheckpoints next.038checkedboundaries areupstream; nofuture-signature assumption. Finalonefrozen source must runallrelatedhost/Node, minimumSDK, unsignedApps, changedtwo-endUI/375darkmaxfont with input/evidencemanifest andpostrunhashcheck, followedby source/final root+m2 reviews.

RealApple/Keychain/iCloud/CloudKit/Health/WC, Team/Bundle/container/signing, personaldevices, original018physicalcapture andactualdeployment/durability remainunverified. Productionprovider/trust/bootstrap stayUnavailable;026held, M4incomplete, no dev/release/main promotion.

## 026-1: original identity before business storage

Source checkpoint `11a0d4d8c8bd6841a2f8edc29abc9bcc076cd12b`, following fixture-only commit `6c606a7905abea4c260749a8ad83a2a3f23d6291`. One retained ownership lease preserves the original `device.identity` UUID; injected vault material must finish before the first business SQLite facade opens. Existing empty storage missing its original identity/key or retained owner is rejected. This factory is not yet wired into either App entry.

- Initial compile RED was a missing API; the minimal stub runtime RED executed one test with one unexpected failure. These are separate evidence layers.
- The first nine identity tests passed. The first full AppIntegration run then executed 27 tests with two failures: the old pair fixture lacked the newly required managed storage binding; the held-lock fixture prepared end during capture dispatch (expected generation 2, actual 3, state `needsReconciliation`).
- Original assertions remain. Fresh pair roots now bind their explicit fixture ownership before inbox/outbox creation. The held-lock test waits for the actual `.failed` / `.notCreated(.unavailable)` start observation before preparing end. An intermediate selected attempt still failed because merely leaving `.pending` does not prove capture observation completion; its log is retained.
- Independent review identified case-insensitive directory aliases. A real filesystem test verifies matching `lstat` device/inode first, then covers same root, descendant and ancestor aliases. Before the fix it executed one test with 11 assertion failures. The implementation now compares each actual root inode against the other ancestry before any owner/identity/vault write and rechecks during identity verification. Symlink rejection remains. On a case-sensitive volume the test explicitly reports not applicable; this run exercised the case aliases and skipped zero tests.
- Final single AppIntegration run: **28 tests, 0 failures**, including all 10 identity tests. The conservative **233 inputs** were frozen before the run, unchanged afterward, and matched the committed checkpoint byte for byte. The previous nine selected tests are included in these 28, not added to them. `git diff --check` passed.
- Command: `swift test --package-path native/Apps/iOS/Integration --scratch-path /private/tmp/football-record-NATIVE026-build/AppIntegrationHost`.

Evidence folder: `/private/tmp/football-record-NATIVE026-build/bootstrap`.

| Evidence | SHA256 |
| --- | --- |
| `runtime-red-2.log` (stub runtime 1/1) | `dd15fb8af6a170ab6f701578ff9f2fc064bf47132669049a32cc1245da2b2092` |
| `first-source-inputs.json` (first 233 input layer) | `3b7af5a39933d0b3649d95649a64ac8d5ba6f05ede7db1123416189a1ae96925` |
| `full-appintegration.log` (original full 27/2) | `47442fa36375be306d9b4059297b8c4fb8890212d2911393801a7151d4f71dc4` |
| `gate-diagnostic-red.log` (original version conflict) | `06878c9f963213a42b5fc36c548c3e39a8bd907a13c9c39d614477f8e0396138` |
| `case-alias-red.log` | `8b7369db5549d97a4b28192018d5764f67dfd6f9ff7f0b3632a75b73a9e59a22` |
| `first-checkpoint-inputs.json` (final 233 input layer) | `986b6bad8108e579666172e11bcc5d48a8fd799e3f4d6284c5f470bddf61aee3` |
| `first-checkpoint-post.json` (233 / zero differences) | `b793c4487af73076f61dee89d117b2ac626c8033f2cc8412f1a2c3773ecfc1cc` |
| `full-checkpoint-green.log` (full 28/0) | `a51db905d110a6a3de4ab9b10d180c899e8df9dddc4ef13916558aed54f5cc57` |

No SDK services, App/UI execution, signing, device/account setup or whole-026 acceptance is established by this host checkpoint. The original production defaults remain unavailable. Catalog, composition, complete erasure, Watch registration and final combined validation remain pending.

## 026-3 foundation: retained immutable catalog

Source checkpoint `bfe5b2aeb064a24ce31618b42dfb0705f74d4ac7` adds only the catalog, journal and their tests. It does not finish 026-3 or connect deletion to Store erasure. Canonical versioned state retains the original owner inode and parent identities; bounded synchronous transactions replace only the journal with file and directory fsync. Current and retired capsules retain their original digest/revision and raw scope; derived 037 bindings exclude themselves from the digest. Reserve persists the original request/scope/choices/catalog, and seal binds its actual saga intent digest to deterministic child mappings.

- Runtime RED: one selected test / one unexpected `storageBlocked` failure with the minimal boundary. A prior test compilation failed on missing `try`; it is separate from runtime evidence.
- Eight catalog tests passed, including current/retired membership, immutable original binding after global index changes, raw Unicode scope mismatch, unknown/future control and replaced owner, before/after-commit lost-response reopen, and control directories inside business roots.
- Actual 256-member and 1 MiB encoded-journal budget tests reject additions while preserving complete prior journal bytes and all retained control files. No truncation. The selected run took 67 seconds.
- Final complete AppIntegration run: **36 tests / 0 failures**, including the prior 28 and these eight. **236 conservative inputs** were unchanged before/after and matched source commit `bfe5b2a` byte for byte. `git diff --check` passed.
- Raw host output contains macOS CoreData/Contacts helper NSXPC connection diagnostics, with zero XCTest failures. These diagnostics are preserved; the output is not described as free of system diagnostics. No Contacts or real AS/SecItem/CK/HK/WC factory was added or constructed by this implementation.
- Command remains the full AppIntegration `swift test` command recorded above.

| Evidence in the same bootstrap folder | SHA256 |
| --- | --- |
| `catalog-runtime-red-2.log` | `77011fa5ead2e910828d8549b8d954d018979e4eae5eb8b1e805eda639701bc9` |
| `catalog-runtime-red-input.swift` | `273712b8643ed1b0ffe1a1b3181a177e9732e8c6e1a46c343ea81c0abf3307a4` |
| `catalog-budget-green.log` (eight selected tests) | `2537e42dd00b59c091d0db8792bcc9e888085b94ce2e51d09331833003ebcf3d` |
| `catalog-checkpoint-inputs.json` | `191fd21cf3a04450c578fae374f5c848be223105728ee7d0061368d7d4c9e9d5` |
| `catalog-checkpoint-post.json` | `1aa1bb10b26c14b0c64db69bc799f8a639be2cf06522de93662b0476f6e3820d` |
| `catalog-full-green.log` (single complete 36/0) | `49f4c80511fcfe49947595ac45748dc33215db1c51ad6f3def931eb0d1dfaf76` |

Health reservation fields are currently an unconsumed draft: 028 request UUID, selection digest, optional confirmation UUID and a missing-mapping/source/unsupported issue. Exact targets belong in the retained 028 ledger. The bridge and its confirmation/reopen contract are not implemented or verified by this checkpoint. All actual saga creation/seal/first-erasure crash cases and every explicit/background/control-retry resume entrance must still be guarded by the eventual composition. Local aggregate leaf receipts, full membership discovery and application wiring remain pending. No real SDK, account, device, signing, UI or whole-task acceptance is claimed.

## Catalog interruption repair checkpoint (S26-catalog-1 / S26-catalog-2)

Source `c8f0e78d0cbf3b9c4484b4d111dc43a8aafca362` follows root's accepted-038 ordinary merge `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55`. The two findings remain subject to exact root+m2 review; this records author evidence only.

The v2 owner permanently binds two slot inodes and the final directory ancestry. `catalog.json` is a hard link to the committed slot. A normal transaction writes/fsyncs only the inactive original slot, then publishes an exact descriptor hard link containing both revisions and both payload SHA256 hashes. Recovery requires that descriptor, the original owner/slot inodes and the old committed journal to agree before completing the atomic rename. Foreign inode copies, bad hashes/revisions, replaced slots and unknown entries are preserved and rejected. A genuinely missing published journal is never replaced with empty state. Legacy owner-only state has no v2 proof and is preserved with a typed refusal.

Fresh initialization creates a private sibling candidate. Slots, complete owner and the initial journal hard link are fully fsynced there. `RENAME_EXCL` publishes the complete directory, then parent fsync makes the namespace publication durable. No owner-only state is published at the final path. Interrupted unpublished candidates are preserved without prefix scanning, cleanup or adoption; a retry builds a new unpublished candidate and cannot overwrite an unknown/concurrent final directory. Owner bytes are upper-bound encoded with maximum inode widths before the first candidate file, then checked again before writing; the permanent 64 KiB owner and 1 MiB per-slot journal limits are consistent with their readers.

- Original real-process RED: four tests / seven failures (two unexpected). The writer's fsynced-owner and fsynced-pending hooks terminate a child with `_exit(86)`, bypassing Swift cleanup; the old final path then cannot reopen. A 705-byte control path in 300 short directory levels writes a 143,081-byte owner that its 64 KiB reader rejects.
- Reproducible old-writer regression layer: seven boundary tests / 15 failures (four unexpected), 330 inputs unchanged. Exact writer/test snapshots and manifest are retained; the fixed writer was restored byte for byte before green verification. Hooks absent from the old writer correctly fail their expected-child-exit assertions and are not represented as old crash windows reached.
- Final single complete AppIntegration run: **43 tests / 0 failures**, including **15 catalog tests** and **13 child exits with status 86**. It covers initialization after stage creation, slot sync, zero-length owner creation, owner sync, before directory publication, after directory rename and after parent sync; normal transaction before journal rename, after rename and after directory sync; and three negative publication variants. Initial unpublished fixture files are preserved on retry.
- Negative cases retain wrong-hash descriptors, same-name foreign inodes, replaced slots, legacy owner-only bytes and genuinely missing journals; a concurrent final directory containing foreign bytes is preserved. Existing 256-member and 1 MiB no-truncation boundaries remain included.
- The deep path now rejects before creating any owner/journal (observed owner bytes: zero). All **330 conservative inputs** were unchanged before/after and matched the committed source byte for byte. `git diff --check` passed. The run took 99 seconds.
- Raw host output retains 104 CoreData helper diagnostic lines with no XCTest failure. These are not represented as empty diagnostics or real SDK readiness. The crash tests demonstrate process interruption, not power-loss or whole-machine durability.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `catalog-crash-red.log` (first four-test RED) | `f4b24259b1579f8a78d7ee629365ef159a4bd95d52aa99b918ad267922778278` |
| `catalog-crash-red-writer.swift` | `3b4a8ed14810c967d06b3b17615928ed8484c9a834970364b1a6b3c4951aec57` |
| `catalog-crash-regression-red.log` | `fc5de232e8fa6e56189e36461ece750ab7432ccf9213022703bc68450203f477` |
| `catalog-crash-red-inputs.json` | `ceda9b4bd893a97766300ccd4d5e79d5af7ee0991ca371425c91d52d61db1edb` |
| `catalog-crash-red-post.json` | `719cd984707f089b9548313f858a5f7718c78edde204535d076e58bfc7251d18` |
| `catalog-crash-red-tests.swift` | `f30b021478b08b9951fa0303f63f63f70546c07c172aea8e508e1565f7ce8283` |
| `catalog-crash-checkpoint-inputs.json` | `2cd84c155c3dce73854108d6b06659a29a1a8ea43b76162c80e4434e5e5c7df0` |
| `catalog-crash-checkpoint-post.json` | `6f0d72b999dcd763c7e9ce851be17b142066909e6d147dc4fc25d174d6b9e3cf` |
| `catalog-crash-full-green.log` | `fb65386fdfd23bcafd9f1e0485825525b8d0c8051d532dd9924091ea51d3b318` |

This repairs only local catalog publication. Health remains upstream 039; typed Watch relay remains upstream 040. Neither WIP API is consumed here. Same-facade composition, every deletion resume entry, complete owned-leaf receipts and final combined App/UI/SDK verification remain incomplete. No real accounts, devices, signing, SDK factories or long-lived branch promotion was performed.

## Catalog reopen stabilization (S26-catalog-3)

Source checkpoint `21ada8f864d66599d36413b51f56834ac6d4b280` follows actual accepted-039 ordinary merge `27e83a50dcb0c08f7c5b3688e6fb86d5c9045b60`. This records author evidence; the new finding remains subject to exact independent source review.

A process can terminate after directory or journal rename and before directory fsync. Reopen now validates the original owner, held root, slot and ancestor identities, opens and checks the original publication parent, then fsyncs the catalog directory and parent before returning durable state or reusing the inactive slot. It rechecks identities after synchronization. A synchronization error preserves all names and bytes and blocks the operation; a later healthy reopen can retry. Recovery after a pending descriptor rename passes the same barrier. The normal publisher cannot leave an extra descriptor linked to the current slot: it publishes a different inactive slot and atomic rename consumes the descriptor. That unsupported state is now preserved and rejected rather than cleaned up.

- Reproducible old-logic RED: **four tests / 18 failures (one unexpected)**, with all **332 input bytes unchanged**. Exact old-logic writer/catalog/test snapshots are preserved. The test-only injected failure was not honored by the old reader; old slot reuse mutated retained bytes, and the old current-slot branch deleted the extra descriptor.
- Minimal fix selected GREEN: **four tests / zero failures**, including **six actual child exits with status 86** after initial or normal publication rename. Completion tracing occurs after the real fsync calls; injected failure verifies refusal before mutation.
- Final single complete AppIntegration run: **72 tests / zero failures** (28 original, 19 catalog, 25 accepted Health bridge tests), **19 actual child exits with status 86**, and **332 inputs unchanged before/after and matching the committed source byte for byte**. Existing catalog capacity, ownership, interrupted initialization, unknown/control and negative descriptor coverage remains included. `git diff --check` passed. The run took 103 seconds.
- Raw host output retains **104 CoreData/Contacts helper diagnostic lines** without XCTest failure. This establishes local process-interruption and synchronization-order behavior; it does not demonstrate a real power cut or whole-machine durability.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `catalog-sync-frozen-red.log` | `2fdf8aa2561016629eced9ff85810a7166579a249481bb2995232f8f473918ec` |
| `catalog-sync-red-inputs.json` | `efc64e7851087ef80a4e527bfed4759f94edca32b635b0fc3dd51b428e72f624` |
| `catalog-sync-red-post.json` | `f7a6f59b40d90d0ed4ab4603d2241522a58b29e838d9fee1160a28af5abbc5fa` |
| `catalog-sync-red-M4CatalogJournal.swift` | `13836ed915df48a763c88a10aace619ba9639b7bb6f8af4c38d63dc9d84ffa75` |
| `catalog-sync-red-M4OwnedDataCatalog.swift` | `c1d5a3b4e55c6b2ce40ec77a4b93a1ab813c7126e4028638685c32683442b842` |
| `catalog-sync-red-tests.swift` | `18fa837cbfb9cbb6afebe203a2dd568d391d9123fbea7a884a7c02147535f1da` |
| `catalog-sync-selected-green.log` | `bf2a2ad0fbf247ab6850f68ab07e0a15d5c2d44a97b6092d5217bf6f4f0c16fb` |
| `catalog-sync-checkpoint-inputs.json` | `a2b28be2292deb1f955c0deccadbf445c9117975b3fa4749edc0a7153fff8a99` |
| `catalog-sync-checkpoint-post.json` | `f3aa1ee0b79f25cea5c77c773d78a0530e5a7b97ca4b5212b6241dbf3ba95b83` |
| `catalog-sync-full-green.log` | `b70e404c67aafbeab1779a7e5189cf80c5b88f1f6c07a3cada7bb8f966b0adb2` |

The separate dependency-039 root run was 68/0 with 332 unchanged inputs, not added to these 72. Default/Release provider gates remain unavailable. No real SDK factories, account/device setup, signing, App/UI execution or long-lived branch promotion was performed. The clean handoff pauses author writes for root's accepted-040 ordinary merge; it is not whole-026 source/final acceptance.

## Recovery cancellation/join and scoped account factory

Root's separate accepted-040 dependency run at `ee06ba98a3a3f69020c42b60f25f6802b3d05b1b` was 86/0 with 334 unchanged inputs. RecoveryInbox source `1e522821309c47e77400a61883d44468d521c2f8` then adds an explicit detach boundary: clear old pending signals, cancel and join even a cancellation-insensitive recovery, refuse attachment during an active worker/join, and let concurrent detach callers await the same worker. Existing pre-attachment coalescing and in-flight wake assertions remain. Runtime RED was **four tests / ten failures**; selected GREEN was **four / zero**. The following frozen full AppIntegration run was **90/0**, including those four cases, with **335 inputs unchanged and matching that source commit**. A first green compile attempt failed on inferred `Task<Void?, Never>`; explicit `Task<Void, Never>` corrected the type before runtime verification.

Evidence under the same bootstrap folder: `recovery-inbox-red.log` SHA256 `351e6341840a829f5bb5a794f2ea815de7a6870c0593602f74c6fb842820c510`; `recovery-inbox-related-green.log` SHA256 `be0f31913d8b3fa080d98fa343c59b1bdc227ab9b3aefde88cc9eb97d1f8c1bf`; `recovery-inbox-checkpoint-inputs.json` SHA256 `5a2584776c1c514e6e0774bd7036cb5d36574c86adaa41a519e540eec6c52c08`; post SHA256 `6e971da125e946c4c3018ebbba2106b18a2f4880c8bca8192569931127c101aa`.

Factory/admission source `b860c117520deb5368ff451eae4fc080f0a7a263` uses original prepared identity/vault before the one database facade, `AuthorityStartPermitProvider` rather than a simulation permit, original Session and same-facade services, followed by 038's checked AccountAppContext factory. An injected current dual-identity observation is required explicitly; a retained matching credential does not admit on open. Admission checks raw account/cloud/device/key and environment, compares the current durable binding/generation across awaits, and only then calls existing AccountKit admission and checked presentation projections. Default real services remain unavailable. No App entry or complete action controller is wired by this checkpoint.

- Factory/current-identity initial runtime RED: **four tests / four unexpected unavailable failures** at the minimal boundary.
- Frozen scoped GREEN: **four tests / zero failures**, covering exact same facade/Session, no credential-only admission, default unavailable identity, fresh matching Apple/cloud observation and a durable generation change during the observation await.
- The complete six-case composition selection still has **three failures in two retirement tests**. The actual original Session capture probe observes returned generation 3 followed by generation 4 after its suspended gateway returns; old model snapshot/history also remain referenced. The two business assertions stay in the suite. NATIVE-042 owns the upstream permanent retirement/task-drain repair; 026 will connect its exact accepted API afterward. This is an acknowledged upstream block, not a whole-suite PASS.
- All **337 inputs** remained byte-identical around both selections and match the committed checkpoint. `git diff --check` passed. No real SDK, account/device/signing/App/UI execution or whole-026 acceptance is established.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `composition-factory-red.log` | `6069335d4fb122d840117fb2361c276ee20f70f20f6e559e063956d2f8da7a4d` |
| `composition-factory-checkpoint-inputs.json` | `3666bb82ba95810e509b527fb2b78fee928b63b9ce6704b17e5e910a0c235444` |
| `composition-factory-checkpoint-post.json` | `80be208180807bace9835e297f66fd39c41a13e3e83511367b1adc4d20055ef5` |
| `composition-factory-selected-post.json` | `80be208180807bace9835e297f66fd39c41a13e3e83511367b1adc4d20055ef5` |
| `composition-factory-frozen-selected-green.log` | `f9706f319fd87de4f1749005b1f2d0d18a68bee0d242b963c7eeb8073dab47bb` |
| `composition-factory-checkpoint.log` | `3b0c767c9e392c5422b4326b65a1a1d97068e2184dc747e900404866ed4fb0f3` |

The earlier 90/0 belongs to the RecoveryInbox-only source layer. It is not relabeled as a full pass of the later factory checkpoint containing the two known retirement regressions.

## Bounded first receipts and independent membership revision

Source `4be4a5c00bd4cfc3e476be750493a51c0422ef1b` is new catalog work after the separately reviewed 21ada crash-recovery repair. `membershipRevision` is separate from the publication journal revision. Capsule additions/retirements advance membership; reserve/seal/receipt progress does not change its revision/digest or original 037 binding. Optional absent fields preserve the prior canonical v1 shape. A prior reserved/sealed journal uses its original plan catalogRevision and exact full capsule membership evidence, rather than treating a later journal revision as new membership. Mismatching plan/member evidence is refused.

The retained receipt stores the original parent intent digest, catalog digest, capsule digest, stable child ID, kind, leaf digest and exact canonical first bytes. Each payload is at most 16 KiB, with the unchanged complete journal limit of 1 MiB and 256 capsules; complete replacement bytes are checked before publication. A transaction accepts an identical first response idempotently and rejects a changed response or foreign binding. Known typed payload validation distinguishes Store control evidence, 033's own request digest, 024's parent request digest and 037's original request/intent digest. These records alone never establish actual current zero or whole-device erasure.

- Existing API membership RED: **one test / four failures**. Reserve/seal previously moved the reported index revision and digest without changing members.
- Actual old-writer RED: **one test / two failures**, using unmodified 21ada catalog writer bytes. The original owner/slots/catalog directory remains at `/private/tmp/football-record-NATIVE026-build/legacy-membership-original`; it has journal revision 3 and original plan membership revision 1. New-reader verification passed **two selected tests / zero failures**, preserving every original fixture file byte, device and inode. Exact writer source matches 21ada's Git bytes. Ordinary-suite coverage also constructs the prior v1 canonical shape explicitly; it is distinct from the actual old-writer run.
- Receipt runtime RED: **three tests / 14 failures** at the no-op persistence boundary, then green after minimal implementation. The first RED attempt had 15 failures because the unsealed fixture used XCTUnwrap before the expected throwing boundary; that log is retained and not substituted for the corrected runtime RED.
- One new selected run: **six tests / zero failures**. It includes immutable first-response replay after lost commit response, before-commit refusal and payload budget, changed parent/catalog/capsule/child/leaf refusal, independent membership, old format reopening, and typed receipts from actual local ledger/staging/DeviceSync APIs. The DeviceSync default returns pending/unresolved; an explicit controlled protocol drain is separate from any WC/native driver claim. 033's returned digest is retained, not recomputed or replaced by its parent digest.
- One complete AppIntegration run: **102 tests / three failures**, with **25 catalog tests / zero failures**. The only failing cases remain the two registered NATIVE-042 retirement regressions (three assertions). All business assertions remain active. **337 inputs** were unchanged before/after, and match the committed source byte for byte. Nineteen real child exits have status 86. Host diagnostics retain 119 CoreData/Contacts lines. `git diff --check` passed.

Actual old writer capture, before catalog implementation changed:

```sh
M4_LEGACY_CATALOG_ROOT=/private/tmp/football-record-NATIVE026-build/legacy-membership-original M4_LEGACY_CATALOG_MODE=capture swift test --package-path native/Apps/iOS/Integration --scratch-path /private/tmp/football-record-NATIVE026-build/AppIntegrationHost --filter '^AppIntegrationTests.M4OwnedDataCatalogTests/testLegacyReservedPlan'
```

The new reader uses the same command with `M4_LEGACY_CATALOG_MODE=read`; it does not recreate/copy/rebind that fixture. The before/after manifests retain absolute paths, SHA256, device and inode. Normal whole-suite runs use a separate fresh controlled fixture, preserving this original evidence.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `catalog-membership-red.log` | `0314fd368a011d270072eb84c432b5d5e99465218d6739c0b3f5a4436a2785b8` |
| `catalog-legacy-original-writer-red.log` | `8c35a8b2288cf1f23379a67fbaf75cbae3a9f76677794011ffeba9863a3aba5a` |
| `catalog-membership-old-writer.swift` | `c1d5a3b4e55c6b2ce40ec77a4b93a1ab813c7126e4028638685c32683442b842` |
| `catalog-legacy-original-before.json` | `5b0c6e00bcf54e72fb959b6ebebcecbec82653ff1fc74c0f53ff6378ace8593a` |
| `catalog-legacy-original-after.json` | `0d3881d5f12b33bff2b721464f30744a7a95f1a95df923f692b3fdc8c2d3dea9` |
| `catalog-receipt-red-2.log` | `eeaa767c49779cd07addbffe46ebfce726cfc65760857cf97708b7459c828cb3` |
| `catalog-receipt-red-source.swift` | `837e5ab5a0de456915fa8c0d1772a3030bf99e063a204845393d5b3047795645` |
| `catalog-receipt-red-tests.swift` | `11628a30e919c0382ce00fd6bb4a8406c6884690fb0b73ef03adce83eecb70ac` |
| `catalog-receipt-checkpoint-inputs.json` | `c4f96a70cc4db433384e611628633ba3dc9f55db767d36dd48793018b57057dc` |
| `catalog-receipt-checkpoint-post.json` | `80be208180807bace9835e297f66fd39c41a13e3e83511367b1adc4d20055ef5` |
| `catalog-receipt-six-green.log` | `68c73897f3e879216e9085ca713ca693ce94595a07892c4ddaacf342aa1cfe7b` |
| `catalog-receipt-full-host.log` | `657d63a0972d0fba36b97f0d5687306af96983e74388008fe3944422c6f0e719` |

Fullseal, aggregate current-zero replay, Store erasure/control retention, every resume entry and App integration remain pending. This checkpoint is not a complete full-suite PASS, real SDK/device/account validation, power-loss proof or whole-026 acceptance.

## Erasure evidence and counter capacity preflight

Source `90340d4ccc35c3f453e4afc1473e251bea1d15a5` follows root's accepted-041 ordinary merge `cd468eef50e73f830359f0f10b088f97f72f2861`. The separate root combination was 132 tests / three failures with 339 unchanged inputs; its dependency log SHA256 is `5bdc5da3a3a758bac65f7bad7c3abfb30bc9572a8106682892eef5348af2c81c`. Neither run is a whole-suite PASS.

The journal limit stays 1 MiB and membership stays at most 256 capsules. A private, never persisted encoding bounds every missing required first receipt at the existing 16 KiB payload maximum, the real frozen identifiers/digests and maximum integer widths. It leaves 16 KiB for bounded Health raw/prepared references and aggregate fullseal metadata. Future schema must remain within that allowance. The encoding is size evidence only: zero-filled placeholder payloads are invalid receipts and are never returned, written or used as completion proof. Each original plan is checked before reserve publication/replay, seal, first receipt mutation and explicit erasure preflight. A remaining-write counter guard permits one write per missing receipt plus 16 bounded preparation/seal steps; idempotent retries do not consume writes. Overflow or insufficient space is a typed, preserving refusal.

- Space RED: **two tests / six failures** against the preflight-less writer. A 48-capsule catalog could publish a deletion plan without enough space for its possible first receipts; an original sealed plan reopened without an erasure barrier. The actual writer generated `/private/tmp/football-record-NATIVE026-build/legacy-preflight-original` before the fix.
- Space selected GREEN: **four tests / zero failures**, including immutable first receipts and actual typed leaf receipts. The new reader rejected the same original old-writer plan without altering its identifiers or any file byte, device or inode. Normal-suite compatibility fixtures are separate from this actual original writer fixture.
- Counter RED: **one test / three failures** with a canonical sealed journal at revision UInt64.max-1. The new preflight rejects reserve replay, seal replay and erasure admission before any progress can overflow or business erasure starts. Original bytes remain unchanged.
- One frozen complete AppIntegration run: **135 tests / three failures**. Catalog **28/0**, accepted retained-artifact **30/0**, Health bridge **25/0** and Watch relay **14/0** are included in that run. Only the two existing NATIVE-042 retirement cases fail (three unchanged business assertions). The run retains 19 real child exits with status86 and took 135 seconds.
- All **339 conservative inputs** remained unchanged before/after and match the committed source byte for byte. `git diff --check` passed. The aggregate dispatcher and every resume/erasure entrance still need to invoke capacity preflight before mutating any leaf. This checkpoint does not prove fullseal, current zero, Store erasure, quiescence, real SDK/device/account behavior, power-loss durability or whole-026 acceptance.

Actual old-writer capture used the exact preflight-less source and test snapshots below:

```sh
M4_EVIDENCE_BUDGET_ROOT=/private/tmp/football-record-NATIVE026-build/legacy-preflight-original M4_EVIDENCE_BUDGET_MODE=capture swift test --package-path native/Apps/iOS/Integration --scratch-path /private/tmp/football-record-NATIVE026-build/AppIntegrationHost --filter '^AppIntegrationTests.M4OwnedDataCatalogTests/test(EvidenceCapacity|LegacyPlanWithoutCompletionSpace)'
```

The fixed reader uses the same original path with `M4_EVIDENCE_BUDGET_MODE=read`. The before/after manifests record zero changed bytes or inodes. No fixture copy, identity replacement, limit increase, truncation or prior plan reset is used.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `catalog-evidence-capacity-red.log` | `5c5dafedebb1f1563591406026b9c221c353420a64e62513f33ce704ad465862` |
| `catalog-evidence-capacity-red-source.swift` | `400a61f94c7cfb58fc549d8042ba10612c64749bb85e9641b05d7b25372f31ae` |
| `catalog-evidence-capacity-red-tests.swift` | `e04cab5c1d85e3f4dc7a9147fc2e401ab0bbfc59ae9bd6c4b7bcab06cee35393` |
| `catalog-evidence-legacy-before.json` | `723305ff415f88741c0436113529d061e82253d4eb9dfc8ff0606cf0b15c56d5` |
| `catalog-evidence-legacy-after.json` | `0d3881d5f12b33bff2b721464f30744a7a95f1a95df923f692b3fdc8c2d3dea9` |
| `catalog-evidence-capacity-selected-green.log` | `30cffa8980a8b40024d9c5a80e611670bbc2f74a04c1dbe1278a45f71142a6fa` |
| `catalog-evidence-counter-red.log` | `e0401e196a647628e862fc2389729af9b1bf33912528b8bb0b6c37c8d9e04a8e` |
| `catalog-evidence-counter-red-source.swift` | `382d89905b421eaee78019961fe9a9fe818cfebc5e78503e6ad3cf8085e5636b` |
| `catalog-evidence-checkpoint-inputs.json` | `bade7b3036d5f74cfeedb178e052c1b2b40f9a666546cba0a0834807ebd530c0` |
| `catalog-evidence-checkpoint-post.json` | `cc8a7cb011eb9691c236935b75de75759d44d799abe54558fb9bf7071bcc2a76` |
| `catalog-evidence-checkpoint-commit-match.json` | `3e32807697094d3bf0e7b4e33a59ce907ef7e5071d104c23416028d7724f6bb6` |
| `catalog-evidence-full-host.log` | `afa8235f1aff6da8796f6bb2ff36fd1d4be2526f59ac14bd1104146a1ee2f217` |

## Concrete staging and DeviceSync receipt replay

Source `977cfeb8324d9e37c03ca6c43dc35ee6a4f54ce3` adds only the owned leaf executor and its standalone recovery tests. The internal executor is component-scoped; Store and cloud-ledger cases throw unsupported. It is not a conforming whole-aggregate driver and does not establish fullseal or actor quiescence. Before and after the actual operation it checks the original plan parent/digest, stable child, capsule, original paths/inodes/ancestors and capacity preflight. Explicit staging control routing must match all three retained coordination files before any constructor. DeviceSync reopen never calls bind or creates a new ownership provenance. Existing cached receipts do not skip the real leaf API; first bytes are retained and read back unchanged.

- Actual minimal-boundary RED: **four tests / six failures (two unexpected)**. The exact source and tests are preserved.
- First green attempt retained one wrong-error failure for an unregistered control; membership is now checked before opening it. The next attempt found the supported `/var` system alias needed existing canonical normalization; both logs remain preserved. Assertions were retained.
- Final scoped **seven tests / zero failures** cover original staging receipt across reopen, restored staging directory refusal, default DeviceSync unresolved drain, explicit controlled drain followed by restored-frame refusal, unregistered control no-file creation, wrong original parent/digest, retired membership, replaced retained owner, and unknown device inventory preserved without invoking drain. The controlled drain is a protocol fixture and supplies no native WC proof.
- Frozen complete AppIntegration: **142 tests / three failures**, 134 seconds. All seven leaf tests pass. Only the two unchanged NATIVE-042 retirement cases fail (three business assertions); none are removed or skipped. **341 conservative inputs** have zero before/post differences and match the exact committed source. `git diff --check` passed.
- 033's accepted replay currently verifies receipt/fence but exposes no all-epoch current-zero readback. This concrete leaf executor leaves cloud-ledger unsupported and reports the exact upstream gap rather than inventing an inventory or claiming cached-receipt success. Store actual saga proof, aggregate/fullseal/resume gates and App wiring remain pending. No real SDK/account/device/App/UI execution, power-loss or whole-candidate acceptance is claimed.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `local-leaves-red.log` | `d1a4e4499512cb26f82873d2935a0d581c65d7017c93fe349f2ee18b7171c862` |
| `local-leaves-red-source.swift` | `99f9d36a4bbc5b269403b377580f95cea050d3e667f942a1010a890f05bdc01e` |
| `local-leaves-red-tests.swift` | `0afc0483b710176ce73af7d2a30fb82d30ae8db47d05a4049187e2adbb3892f9` |
| `local-leaves-seven-green.log` | `9494190a89682270925d7d7723f5f01167d617900dbba2831e688df521f6700c` |
| `local-leaves-checkpoint-inputs.json` | `a7d02a8673a11db73c070fcc3f53d55ff2568714a77b726fa57a015f0ac60726` |
| `local-leaves-checkpoint-post.json` | `5e0c2674f925cb3df4d386f96bb2f0930f58ee164e6b825fdc5486b5d876da5b` |
| `local-leaves-full-host.log` | `c80850895fd7f5c822bff7f0cb65cbb0b5ffbb370c4075e77ad6daaa9ee5e250` |

## Bounded Health artifact references and immutable fullseal persistence

Source `b7050006c45f6c2ee9bca7d95d542fa93db591c8` consumes accepted 039/041 and 028 APIs without editing those paths. New optional catalog fields omit nil and preserve old canonical records. Initial reserve binds the original valid raw artifact digest; prepared references carry original raw/prepared/parent digests and stable 028 request/confirmation/selection IDs. Fullseal publication checks original saga scope/choices/intent, actual raw/prepared canonical mapping and the read-back 028 request plus explicit confirmation. Immutable CAS/readback preserves exact prior bytes. The 041 provider only reads the catalog's real stored Health seal; it does not construct or persist a substitute.

Metadata encoding is bounded to 16 KiB. Capacity preflight removes already-published metadata from its private size-bound copy before adding that same fixed reserve, so subsequent preparation cannot double-count the allowance promised before erasure. Complete journal 1 MiB, membership256, first receipt16KiB and independent artifact-store limits stay fixed. Complete raw capture facts stay in 041; the catalog is verified not to contain their raw capture token. Existing capsule identities are revalidated before seal publication.

- Initial fixture attempts separately failed compilation on a missing import/internal scope helper and then failed at the repository's required trust boundary. These logs remain preserved; public scope construction and explicit controlled development trust corrected the fixture without upstream changes.
- Actual intended runtime RED: **one test / one unexpected storageBlocked failure** at the new seal boundary, after real 041 raw/prepared and 028 confirmation operations. Exact red source/tests are preserved. The first green compile required an explicit throwing-comparison marker; its log is separate.
- Scoped **nine tests / zero failures** includes the prior seven actual leaf cases and two new Health cases. Real SQLiteSessionRepository saga, 041 retained raw/prepared store and 028 SQLite ledger are composed. Before confirmation the fullseal is refused without mutation. Identical replay/reopen preserves original seal and catalog bytes; changed raw/prepared inputs cannot replace it. Honest missingMapping has no invented artifact reference or fullseal. The Health driver is unavailable and no Health deletion executes.
- One complete frozen host run: **144 tests / three failures**, 134 seconds. Only the two unchanged NATIVE-042 retirement cases fail (three business assertions). **341 inputs** have zero before/post differences and match the exact source commit. `git diff --check` passed.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `fullseal-runtime-red-3.log` | `142a47fa0468ff029fbcae15e413fcfd06a99daaf3feb306a8ef7505ff798fad` |
| `fullseal-red-source.swift` | `c3998f3f2f91902935ddb38e1c42a093f772b5fb68289261d32f990003d3d31c` |
| `fullseal-red-tests.swift` | `0e4de06249696ce523c961d40e70872d97446f727c9d5b59c2c08d989565c7b8` |
| `fullseal-nine-green.log` | `9d0df53fe6f7c48bfc3ac4aa93bfaa2679f089bc674897e5e3a0a083c4dc9439` |
| `fullseal-checkpoint-inputs.json` | `e22a947f2ebeb20a578c5f07643924f213941cbc39fa8ab9969498152b3808e6` |
| `fullseal-checkpoint-post.json` | `5e0c2674f925cb3df4d386f96bb2f0930f58ee164e6b825fdc5486b5d876da5b` |
| `fullseal-checkpoint-commit-match.json` | `3ba37faa952024aa17c173228f4dfdfa918d1d5280de99e76f0875fcc32248bf` |
| `fullseal-full-host.log` | `846f93556eb7ac17f0234732acead9ceb12ad0bd8953bfde86140a5076eb26b3` |

This checkpoint publishes coherent retained control evidence. The composition must still enforce fullseal/capacity/quiescence at every explicit/background/retry erasure entrance and recover createSaga-before-seal interruptions using the original parent. Store and all-epoch cloud-ledger current-zero boundaries remain reported upstream gaps; cached component progress does not prove them. Actual original-session retirement depends on accepted 042. App wiring, full aggregate erase/resume, real SDK/account/device/signing/App/UI checks, power-loss and whole-026 source/final acceptance remain incomplete.

## Accepted-042 retirement and original context/identity task drain

Source `23459343d04f49cddf07d327cdb222b2eb6a1a23` follows root's ordinary merge `12cb0cfabc0619ddb07784603f313623c26aa080` of accepted042 final `dd38dc2`. Root's separate related merge checks were SessionRetirement11/0 and Integration35/1; the latter retained one original capture generation assertion until this composition integration.

The owner now synchronously gates model business entry, awaits the original Session's permanent retirement and durable capture observations, then joins/clears the model. Shared quiescence callers join the same task. Original identity admission tasks are owned, cancelled and joined even when their observer ignores cancellation; lifetime/business gates are rechecked after the final durable generation await. Later admission on the retired composition is rejected. The Session and original repository remain available for saga control operations; quiescence does not close the DB.

The old IntegrationContext uses the same three phases and a shared throwing shutdown task. Only success closes its original repository. A failed drain propagates to IntegrationLifecycle.replace, which retains the original retired context and never constructs/publishes a replacement. Failed business gates stay permanent; a subsequent shutdown can retry the original durable drain. No `try?` converts a failed drain into successful close.

- Actual original two-case retirement RED after accepted042: **two tests / one failure**. Old call order returned generation3 and then wrote generation4. Three-phase selected composition GREEN was **seven / zero**, with original return/final generation4=4, snapshot/history assertions intact and a new same-facade saga survival check.
- First full run at that intermediate layer was **145/2**, 344 unchanged inputs. Both failures were prior IntegrationContextTests expecting old UI feedback counts2/1 after the new042 retirement contract deliberately clears them. The original successful counts remain asserted before retirement; retirement now explicitly requires zero and no subsequent repopulation from fresh-model actions. This compatibility adjustment is distinct from the following product failure regressions.
- New owned exit/identity runtime RED: **five tests / seven failures**. Actual uncooperative identity observation outlived quiescence; original capture shutdown closed its DB before the positive observation; forced durable drain failure still called the replacement factory and discarded the original context. The two feedback compatibility failures are included in this red run. The first attempt lacked the fixture's MatchCore import and is preserved separately. Exact red composition/context/test snapshots remain in bootstrap.
- Final related selected run: **13/0** (Composition8, IntegrationContext4, DevicePair1). The forced-failure fixture deliberately closes its repository before returning a positive gateway observation to produce a real drain failure; this proves typed replacement refusal and original-context retention, not recovery of an externally closed connection. Leaf042 separately proves retry of retained SQL failures.
- Final frozen complete AppIntegration: **148 tests / zero failures**, 140 seconds. All **344 conservative inputs** remain identical before/post and match the source commit byte for byte. `git diff --check` passed. Previous 144/3,145/2 and all original red logs keep their own source layers; they are not relabeled.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `retirement-042-runtime-red.log` | `b706d2d925320ba7813af13996ed1e57629e36d1cef08e93cbd2ac2f8c8746c4` |
| `retirement-042-selected-green.log` | `7545ea623d32a81bc183751185cf66f96863ccef662a1d1767f31aed884355db` |
| `retirement-042-full-host.log` (intermediate145/2) | `ddcc1bdb62f6a042d7c5b665ff63c9b53e83e2ac81cd03ea184bdc47b4799d7b` |
| `retirement-owners-runtime-red-2.log` | `83bc5da3cf1020fac669f010f56f2e59b4f1b9f1eaee74268446ef92187fd1d9` |
| `retirement-owners-selected-green.log` | `922f0d0d9ae6fdc0a641e317ea3bee5723b239e17590adb95a8cdad9f2767196` |
| `retirement-owners-checkpoint-inputs.json` | `5d258715919d662add5d430c8828bc2fc7c7a9fe0afd0023ff3b663e48d91319` |
| `retirement-owners-checkpoint-post.json` | `5bade929294b6fcaa7fb3ebc44eb1fb92b132e8b68e44b79b8b4c449a3ea5296` |
| `retirement-owners-checkpoint-commit-match.json` | `1369cb59b6cd556dad81c82f78c41f944dbef8388b6277614f829a7762dcecb1` |
| `retirement-owners-full-host.log` (single148/0) | `ee856b9dca830e392bb8299b539778b34ac2efc0f2d3cab7e0aff980306125f5` |

This is source/host retirement integration only. Every composition deletion resume still needs the original general parent/catalog/choice/child/capacity/quiescence guard. Health.delete additionally requires real039/041/028 fullHealthSeal at Store/transport erasure, while typed missing/source issues preserve Store and allow independent Cloud progress. Full current-zero aggregate interfaces, App wiring and real SDK/device/account/signing/App/UI/power-loss checks remain incomplete.

## Original resume guard and independent Health issue components

Source `df6e4eb52c206d67262344508b1bb2376c63bdcb` adds guarded original-parent/catalog admission and forwards every Lifecycle/control-queue operation through the same original Session/sync identity. It creates no replacement facade or Session. A resume requires durable original parent digest, whole frozen membership and deterministic children, scope/choices, existing capsule identities, capacity and business/identity quiescence. A valid raw artifact is read back from the actual041 store; an honest typed Health issue remains retained with original Store business. Analytics-off and transport fence are restored idempotently rather than assuming requestDeletion's prior-saga return performed them.

Store and local-transport entrances apply the extra Health.delete condition: actual retained raw/prepared bytes, the catalog's persisted fullHealthSeal, stable028 request/confirmation and exact entry readback. Health.keep needs no artificial Health mapping. Health issues fail dependent local/Health progress while independent Cloud can complete. New transport completion remains typed unsupported pending accepted044/045 current-zero aggregate; health completion updates require the actual028 local receipt.

- First intended four-case runtime RED: **4/11**. Without the forwarding gate, three typed Health issue fixtures erased their actual original Store witness, raw service/coordinator calls bypassed an unsealed parent, and generic delete did not yield unknownOriginal. A prior fixture attempt missed the receipt signature domain and is preserved separately. Correct fixtures use the existing domain and actual verified backendDeleted receipts.
- Expanded actual RED: **seven tests / 14 failures (two unexpected)**. It includes a real close/reopen of original identity lease, SQLite facade, catalog and ledger before recovering the original pre-backend saga; original request/capability survive. The red source/catalog/tests are preserved exactly.
- First green attempt retained one real unavailable failure because the forwarding object omitted the original public ControlQueueInboundCoordinator capability. Forwarding that same Session capability corrected pre-backend recovery, without no-op protocol conformance or leaf changes.
- Final frozen selected AppIntegration recovery run: **16 tests / zero failures**, containing the seven new cases plus nine previous actual leaf/fullseal cases, with **344 inputs unchanged before/post and matching the exact source commit**. Direct transport calls also verify the same typed Health-seal rejection. `git diff --check` passed. This is a related selection, not a complete155 run or whole026 PASS. Parent requested the minimum clean dependency handoff; prior148/0 stays a separate source layer.
- Independent Cloud uses an explicit controlled protocol fixture; it proves call ordering/component states, not a real CloudKit zone deletion. Actual local signed saga state, persisted minimal capability, catalog, Store witness and SQL ownership are used. Health executes no actual driver, no real SDK services are constructed and production defaults remain unavailable.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `deletion-guard-seven-red-2.log` | `d6c3c1a67d390bb776c833147c4f7951f8fbae46ee5f915ac1eea470523137ee` |
| `deletion-guard-red-catalog.swift` | `57f942f2cd670713c8a68a744b044f1aebe99da2b4a65c49084e925e8746bb4f` |
| `deletion-guard-red-source.swift` | `752936f8a51e4ba903c8ce00c33a0bd6a2cc8a213be2f661fcd07e243dbb4003` |
| `deletion-guard-red-tests.swift` | `e5d76ed13c4fc00c1c97d016941eb40caec6f755d77ba796a19369d1a52b0620` |
| `deletion-guard-seven-green.log` (intermediate7/1) | `5d1a828b08995d4249be7ef7a6b223ab46c72392b780eef25f13f3fd582e83bf` |
| `deletion-guard-frozen-green.log` (single16/0) | `e40b7fc8ce5d6d500221e7220db5f12e5a429663c195102e27e0104a6169c758` |
| `deletion-guard-checkpoint-inputs.json` | `4b8a7164497041cbe79a46727954aca016c6dd4848eddc6cc661165a0d45e140` |
| `deletion-guard-checkpoint-post.json` | `5bade929294b6fcaa7fb3ebc44eb1fb92b132e8b68e44b79b8b4c449a3ea5296` |
| `deletion-guard-checkpoint-commit-match.json` | `d8c36c3a541dcbc01b8958927a60b0aa84ec56b4eb3d00148ff1c2163c471bac` |

Root's newly reported S26-lifecycle-replace-overlap remains open: current=nil across awaited shutdown can let another MainActor replace build early and overwrite the first result. Its real RED/serial fix will follow root's044/045 dependency merge. The existing148/0 did not cover that overlap and is not treated as its closure. App action/AccountService task ownership, true full-Health aggregate admission/execution, creation-to-seal crash windows, final close and complete owned current-zero composition remain pending. No device/account/signing/App/UI/power-loss or whole-candidate acceptance is established.


## Serial replacement overlap repair

Source `ef557edd01bb099b145b57ce1980c9fd11ccba9d` adds a MainActor FIFO replacement gate across shutdown and the next factory. A second caller waits while the original positive capture observation is held, then retires/closes the first replacement before constructing the second. When the actual durable drain fails, both queued callers retry the same original retired context and neither factory runs. No cancellation or failure is converted into a successful close. The tests retain all earlier business and generation assertions.

- Actual RED: two new tests / nine assertion failures, no unexpected failures. The broken implementation ran the second factory before the held original drain returned, produced second-before-first ordering, and allowed a factory through the failed drain. Exact pre-fix product/test bytes are preserved.
- GREEN: one related AppIntegration run **15/0** (IntegrationContext6, Composition8, DevicePair1). All **346 inputs** are unchanged before/post and match the exact source commit. `git diff --check` passes. This does not rerun or combine the old148/0 and16/0 layers.
- Base is root's actual044/045 merge `c01d5c067f39f473e95ebff136a5a7d2f33aac8e`. Their separate root current-zero checks are Store14/0, SessionRetirement11/0 and Cloud7/0; no combined whole-candidate claim follows. The empty ignored MatchCore `.swiftpm/xcode/` directories remain as the saved exception.

| Evidence in the bootstrap folder | SHA256 |
| --- | --- |
| `replacement-overlap-red.log` | `feafdf73b8338dee43d6cdc8205b97e3bec02e5d0a5385ed617a52fc824014ab` |
| `replacement-overlap-red-source.swift` | `f4a7589766883a3716af11fc6c9d92b20da43a9e4ad99ad7f6b26c0d91dbc55e` |
| `replacement-overlap-red-tests.swift` | `aa8bf5e9cf0f90fa3b4f7506ffd3fdccb18c2263d45086c77ec396f77de02127` |
| `replacement-overlap-related-green.log` | `1a5c974e737fd9fe2567622d02b0f37cb9ad3be45ef7329d25e387711b224633` |
| `replacement-overlap-checkpoint-inputs.json` | `3c7772cc7b3cb9c84341c5f1e2f21c76a48fc05e68a9d56e5f5a9cb897c71b3a` |
| `replacement-overlap-checkpoint-post.json` | `dc7a3caf7184696da2a7fb294a9e969b4670050de63f5c2cb528d1a8d2ed82ed` |
| `replacement-overlap-checkpoint-commit-match.json` | `1bf340c1188a1749f778cea5218794337059311d35053ff9f36a58e2bdb35b22` |

Independent review still controls finding closure. Remaining aggregate work must use accepted045 concrete read-only original Store witnesses and always invoke accepted044 Cloud replay, preserve first receipt bytes, and verify all owned components. Final Health selection must follow original capture writer join and match all retained original facts; an earlier immutable raw artifact that omits late positive facts cannot authorize Store erasure. Accepted043 mailbox drain inspection is still unavailable at this checkpoint. Default providers remain unavailable; real SDK, device/account, App/UI, power-loss and whole026 checks are pending.


### Cancellation during original shutdown

Follow-up source `47559320f844f2d30f29309f7542c6a373497335` checks cancellation again after original shutdown joins and before the next factory. A held original capture still delays the cancelled caller's return and all queued factories. Once its positive observation is durable and the original facade closes, the cancelled caller throws CancellationError without constructing a replacement; the queued valid caller then builds exactly once.

The added runtime regression is **RED1/2**, followed by one frozen related **16/0** (Context7, Composition8, DevicePair1). All346 inputs are unchanged before/post and match the exact source commit; previous15/0,148/0 and16/0 guard selections retain their own layers. No real SDK/account/device/App/UI or whole026 check is claimed.

| Evidence in bootstrap | SHA256 |
| --- | --- |
| `replacement-cancellation-red.log` | `509c9287c7db3cc8af9e10e19b3006512f775e5f53db857f9c3537644f25744f` |
| `replacement-cancellation-red-source.swift` | `b539ba5fee4d9f3ee717816a4fef8da1a0e17c86c6af220ffaa49fc2ea9df319` |
| `replacement-cancellation-red-tests.swift` | `93484223910fde29cbe9637060468d3a5775eeb3057799bd37f6171cc5860706` |
| `replacement-cancellation-related-green.log` | `765b4e7ba3f7afa558ea1a412127a6179852984e8630d9dbb215d46a607a5b10` |
| `replacement-cancellation-checkpoint-inputs.json` | `15964f582ae09eedd5376c367917b058c2015cc0ab5ab10efd553b44338eb3fb` |
| `replacement-cancellation-checkpoint-post.json` | `dc7a3caf7184696da2a7fb294a9e969b4670050de63f5c2cb528d1a8d2ed82ed` |
| `replacement-cancellation-checkpoint-commit-match.json` | `19971b6189dde1095cb99ec23c9a8e01ff4d6d61b5b89d7f2c5f7a740d0b52bf` |


## Concrete original Store and Cloud local leaf replay

Source `49c3258e053928c5a8d33882eee6dc471cf11a75` consumes accepted044 and045 without editing their source. Cloud ledger routing verifies the original catalog root/controls before constructor entry, opens that exact inode, invokes concrete `eraseLocalTransport` on every attempt, closes the connection, then verifies capsule identity again and retains exact first canonical bytes with CAS/readback. An existing catalog receipt never skips current all-epoch canonical inventory checks.

Store dispatch requires an explicit original composition route. The composition compares the capsule with its private identity-bootstrap DB anchor, joins its original business/capture writer, checks Session/repository identity, and invokes the accepted045 read-only witness for the original parent/digest/raw scope. Stable evidence binds the original backend receipt digest and DB capsule; it omits changing Saga revision. Another facade or absent original route cannot represent another Store. This is a fresh point-in-time query on every replay; its retained stable receipt is not current authorization.

- Actual runtime RED: three new tests / three unsupportedComponent errors, all unexpected as the behaviors were not implemented. The route constructor seam was present but did not change dispatch; exact red leaf/test bytes are preserved.
- First GREEN3/0 covers actual original-inode ledger reopen, target old-epoch canonical upload restoration, unknown live schema, legal foreign-scope preservation, stable original Store receipt across Saga revision changes and actual close/reopen, missing/wrong Store routing, and restoration of normal-intent business after first receipt. Restored/unknown bytes and first receipts remain unchanged when replay refuses completion.
- Frozen related selection: **27/0**, containing Recovery19 and Composition8 in one run, with **346 inputs unchanged before/post and matching source49c3258**. `git diff --check` passes. Earlier148/0, guard16/0 and replacement16/0 are separate input layers.

| Evidence in bootstrap | SHA256 |
| --- | --- |
| `concrete-leaves-red.log` | `2b2e56a3992e4ca375472c8accc5be5687cb26ad588726d19d03f6f8db84cc7f` |
| `concrete-leaves-red-source.swift` | `b1f82d91bab9ed76de60b28b02225ae8f0e65f5c34344bfb820c9701fa29bb8b` |
| `concrete-leaves-red-tests.swift` | `435c8527ca6edadf58691769c780d1793fe5109b1f76ed374024ca713219a312` |
| `concrete-leaves-three-green.log` | `feb5db8d15ce15f216ff3d2c27e454a8bfc3cc90f8129bec1ae7de3a941aa29c` |
| `concrete-leaves-frozen-related.log` | `2bf2782bb8220645ed77384513a9c10ba5c328ad3d6bef51d2b151a33b638b7e` |
| `concrete-leaves-checkpoint-inputs.json` | `36e635fe13d9abcd00b5dcb42ee2d1975ce17ebdf39c7b2d6cc3ec536356856f` |
| `concrete-leaves-checkpoint-post.json` | `dc7a3caf7184696da2a7fb294a9e969b4670050de63f5c2cb528d1a8d2ed82ed` |
| `concrete-leaves-checkpoint-commit-match.json` | `93472a38c935c7210841e9b64f14ffb98bef80b20c42399e3f37473f5d92e27a` |

All-catalog aggregate completion remains unsupported at this checkpoint. It must include every current and retired component and freshly replay historical completed progress. Accepted043 mailbox drain and046 full capture inventory are still pending inputs. Health selection cannot be inferred from empty Store after erasure or from045's post-erasure witness; unknown or extra Store without original Saga/facts stays incomplete. No SDK, account, device, App/UI, power-loss or whole026 acceptance follows from this selection.


## Partial retained local aggregate and preserved047 failures

Source `462d11827a13f6f11da309c31726e59b188b430d` adds explicit whole-catalog local composition on the original facade. Before Store erase, an injected copy-drain checker must verify original scope/parent/digest, all Store routes must identify their own original DB capsules, and the existing parent/catalog/choice/child/capacity/retirement gates must pass. The production default checker throws unavailable and preserves Store business while independent Cloud can advance. Its current controlled fixture is a local protocol test only; it does not inspect043's actual mailbox.

Store completion always invokes fresh045 and saves/readbacks stable first bytes. Transport aggregation then invokes every non-Store leaf in the frozen membership, including retired namespaces. Final receipt membership must equal the full catalog, and copy drain is checked again. Historical completed progress is rechecked before and after controller resume; completion updates require the same concrete checks. Missing Store routes and pending DeviceSync drainage remain incomplete. No new Session or business DB is created by these operations.

- Initial aggregate attempt was **5/8**, with two unexpected fixture errors from a noncanonical DeviceSync root name. This log is preserved; the fixture was corrected to the existing public `DeviceSync` layout. The valid actual runtime RED is **five tests /14 failures, zero unexpected**.
- Aggregate selected GREEN is **5/0**. Cases cover default unavailable copy drain retaining Store with independent Cloud completion; current/retired five-capsule membership spanning four kinds; same-parent retry after pending DeviceSync; unknown additional Store blocking before the original Store erases; and fresh Store/every-leaf replay despite historical completed progress. First receipts, original request/capability and restored unknown data remain preserved.
- Separate Cloud regressions are **two tests / six failures, zero unexpected**. On the original inode after an external catalog receipt exists, deleting internal fence/receipt and restoring an original canonical upload leads the existing leaf to fresh-erase it again. Restoringv3 additionally causes the ordinary constructor to create/migrate schema before erase. The exact external first bytes still match, proving CAS alone is insufficient. Both tests require original rows/schema/version to remain unchanged and are retained without skip or relaxed assertions for047. No026 product SQL/schema inspector is introduced.
- Frozen related selection is **34 tests / six failures**, all six assertions in those same two047 cases; the other32 pass, including the five aggregate cases. **346 inputs** remain identical before/post and match the source commit. This is partial related evidence, not a complete host run or acceptance of the Cloud proof-loss boundary. `git diff --check` passes.
- Health.delete with an otherwise matching raw/prepared/fullseal is explicitly unsupported before Store erase until accepted046's complete original capture inventory is connected. Valid raw facts must follow original writer join; empty Store after erase and045 post-erasure current-zero cannot reconstruct or prove the original selection. Typed missing/source issues still preserve Store and allow independent Cloud.

| Evidence in bootstrap | SHA256 |
| --- | --- |
| `local-aggregate-five-red.log` (fixture layer5/8) | `8b8f46b6478fe7c3e16afc8c29b8759aabc704eb6f03db3df2139c95e505a75d` |
| `local-aggregate-five-red-2.log` (actual5/14) | `e92fe4602449c1d1a3bf354f7e221eb89c17d4daf8810975ce80e3f3db2e219e` |
| `local-aggregate-red-source.swift` | `23620437f6bb61ab6d85cf8128730f67103dffeed10265d3ae37035c7ddc9b61` |
| `local-aggregate-red-tests.swift` | `31e9dfed7eec1dfdf6b46512fefef521ca95402606ee4a547e6915f1b821d69a` |
| `local-aggregate-five-green.log` | `8256b607b003f8133a250a27c217db34d03a27f2f78f560069e71cf79f005a2d` |
| `cloud-proof-loss-red.log` | `141f2e8353a0867600918b1f5912a3334258a50cf03c6970c3a223e01c424276` |
| `cloud-proof-loss-red-report.json` | `04466c50b8adc73e601db497c4a80f98d253450f6434f1489a5a2a8e8af5d2e2` |
| `local-aggregate-frozen-related.log` (single34/6) | `a87e258bb1651291630db6f4184dc4912e16f62c21d3b15a62868928b786a33f` |
| `local-aggregate-checkpoint-inputs.json` | `1f39cf43f2481a85447c19525a2b4e8b9fdba8a84c7016fd910491d7075cc943` |
| `local-aggregate-checkpoint-post.json` | `dc7a3caf7184696da2a7fb294a9e969b4670050de63f5c2cb528d1a8d2ed82ed` |
| `local-aggregate-checkpoint-commit-match.json` | `6e95bb08b3a880c3630c9485f580361f52ec238dbe32ab93b44322668e96f619` |

Independent reviews and accepted043/046/047 inputs are still required. These fixtures do not prove real Apple, CloudKit, Keychain, Health, WC, signing/devices, App/UI, power loss, production drainage or whole026 completion.


## Original control-task exit ownership and multi-Store preflight

Source `adff0f574424bf6292d1ec838cb1a22e66d55168` owns both resume and generic reconciliation Tasks. Final stop closes entry permanently, cancels each owned Task and joins its actual result, including cancellation-insensitive Cloud and original AuthorityHTTPRelay operations. The same original Session, repository, HTTP client and parent/capability remain available through the join. The controller stop does not close them and is not called by business quiescence. Repeated final stop shares its join Task.

DEBUG development may explicitly inject the existing public AuthorityHTTPRelay protocol into the one original factory/client. Default injection is absent and unavailable. Release/production rejects explicit injection before first business DB open. The host negative fixture uses an isolated development signing material name; it proves early refusal, not production signing. No043 implementation is consumed or copied.

The additional routed Store regression uses two real controlled compositions and their original DB capsules, with the extra Store's original parent Saga absent. Previously the first Store erased before the missing second Saga was discovered. The minimal aggregate now explicitly rejects multiple Store provenance before any Store erasure even when all route paths/inodes match; both business witnesses survive and independent Cloud completes. No product creates another Saga/Session/DB to make provenance appear complete.

- New stop API gate/cancel skeleton actual RED **2/2** shows both control Tasks still outlive final stop. Joining both Task families makes the selected exit cases2/0.
- Routed multi-Store actual runtime RED **1/3** shows first Store progress completed, its witness gone and partial first receipt saved. The first fixture attempt omitted await on a public actor URL property and is retained separately. Minimal unsupported admission gives the combined controller/multi-Store selection **3/0**.
- First frozen related layer **38/7** includes one invalid production-test signer namespace plus the six known047 assertions;346 bytes remained unchanged. Correcting only that fixture to an isolated signer name yields one frozen related **38 tests /6 failures, zero unexpected**, exclusively047's same two cases. All other36 pass,346 inputs are unchanged before/post and match sourceadff0f5. No test is skipped or weakened. `git diff --check` passes.

| Bootstrap evidence | SHA256 |
| --- | --- |
| `controller-exit-red.log` | `01e19d12b2137c1a30ed6f37c6037f88bbe7b84008d32deb045eca081ff8094a` |
| `controller-exit-red-source.swift` | `e45b368ada8e439eb6a971de1075f1ab2d6cea85c5198cd6b5957073621471e9` |
| `controller-exit-red-composition.swift` | `aea80b8b8705d19d2fb276f49ef97d05a32ae3c0d71e2abca1e42823581f1fe6` |
| `controller-exit-red-tests.swift` | `5fc0b2241a11b5e40598b70b45eb50d830729105f972890eda32c2fa04b01833` |
| `controller-exit-two-green.log` | `394468e1ed8db7857e77574e7a44ac88f8f3dc3ac6cc445feb50da033978a242` |
| `local-multistore-runtime-red.log` | `5e33fa760f152c8f690035ac718f348112cee305eb32b992e28fddad2efceefd` |
| `local-multistore-red-source.swift` | `029a9a7e6cbf9943e2acf2844507e8232ff0ccb9f896ac299b31b30fda086973` |
| `local-multistore-red-tests.swift` | `3d947c141692d503678544209a938e5bda8e5ad1ca516b2f57bff119a76a7b00` |
| `controller-and-multistore-three-green.log` | `40d30fd8da5f48bd0169d45c8c468c4ddca283239346ee69a4ba184b9eb4e458` |
| `control-owner-frozen-related.log` (fixture38/7) | `dfb59ca982ace345f653c1df8754037ce5d8c7a8aec082bdd2ea09ddbfd79fd5` |
| `control-owner-frozen-related-2.log` (single38/6) | `4b7745a00ee403d7894a73d119043417343e52fe86d14bb34c7f5696c9b829a9` |
| `control-owner-checkpoint-inputs.json` | `714e8a832f5dc4a1b9f0b9e3b2b6473e4937f36a347e4dc036448dba9560ded8` |
| `control-owner-checkpoint-post.json` | `dc7a3caf7184696da2a7fb294a9e969b4670050de63f5c2cb528d1a8d2ed82ed` |
| `control-owner-checkpoint-commit-match.json` | `ade40255165ecf0f940d0e51a05bba42e86a9f412f91c414f97df557be883db4` |

Composition's throwing final close, public Void context callback safety and App/serial-replacement routing are a following independent slice.043 mailbox,046 full Health inventory and047 strict Cloud reopen/replay remain blocked dependencies. No whole026, true SDK/device/account, App/UI, production or power-loss acceptance is established.


## One original final resource-close owner (approvedB)

Source `80e4d8148c79f2a10e440b281fa56e7b31856f79` keeps038's public AccountAppContext.shutdown Void signature. Its M4 callback now routes to the composition's one shared throwing close Task and explicitly records lastCloseFailure on refusal. The callback retains the original owner until successful close; success releases that link. The composition does not call context.shutdown inside its own shared Task, so concurrent callback/throwing callers do not await themselves. IntegrationContext.account holds the exact same owner/model/Session/facade and propagates close errors to the existing serial replacement gate.

Final close synchronously gates UI/business/current identity entry, joins the original Session's durable capture facts, joins every live registered resume/reconcile controller, closes the original typed Watch relay, then invokes prepared.close. The original HTTP client remains available through control join. Client resource teardown from043 is still a subsequent accepted dependency. Controller registration after final close starts returns a permanently stopped controller. Existing fixtures now close through their actual owner; no new business facade or Session is constructed for closure.

Prepared.close validates its original retained identity lease before DB closure or lease release. Moving that owner inode aside and placing foreign bytes at the path produces a real typed **identity-lease preflight refusal**. The original DB/lease and Saga/capability remain retained, public Void close exposes lastCloseFailure, throwing close rejects and queued replacement factories do not run. After restoring the same original inode, the same owner closes successfully and the original parent/capability reopen unchanged. This is not a test of SQLite.close itself failing, power loss or actual device failure. Foreign fixture bytes are retained separately.

- Runtime RED: **4 tests /15 failures, zero unexpected**. Public context close returned before the held original capture and lost its positive observation; account replacement skipped lease refusal and ran queued factories; composition close skipped a held registered control; Void close dropped its failure and original Saga facade. Exact red product/context/controller/test snapshots are retained.
- Selected GREEN: **4/0**. The held capture setup uses explicit unbound development facts on the one original M4 facade and its original Session/gateway. It does not claim authenticated authority recording or SDK exercise. Capture positive facts are read back after closing/reopening the same original DB.
- Final frozen related run: **60 tests /6 failures, zero unexpected**, solely the same two047 cases/six assertions. The other58 pass: Composition11, Recovery29 passing out of31, Context7, Identity10 and DevicePair1. This run also overlaps public Void and throwing close while the original capture is held, proving both wait and complete without recursive join. **346 inputs** are identical before/post and match source80e4d81; `git diff --check` passes. All earlier source layers remain separate.
- Explicit workout/HTTP protocol injection is DEBUG+development only. Default/Release/production remain unavailable and injection is refused before opening a production DB. No actual SDK factory, account, device, signature or capability is enabled.

| Bootstrap evidence | SHA256 |
| --- | --- |
| `composition-close-four-red.log` | `571afc9b110ad80b8ee5fa0e93d7d81ccaf8e447c47a73f228e58b06dd4bfc64` |
| `composition-close-red-source.swift` | `ef04956535c9eb58adef9a57f8d3a425b534abf571bdf287a7c7269d54318039` |
| `composition-close-red-context.swift` | `22a70671f81ed222e75feba577bdd7a8a9d2ddaf281dbdb6828aee367a177250` |
| `composition-close-red-controller.swift` | `a05c0d981a74629c67f27963d93106cf90c66c6a2a069b26e1d20f3d4a5ce7d9` |
| `composition-close-red-composition-tests.swift` | `f129242768ebb5beea0216cedd2ef277740be5ce5fca0a04c1d0d5fa29d8dbbf` |
| `composition-close-red-recovery-tests.swift` | `2e48d5296104d24529cc67b7c8439f2967b4588d0fb6f9723d3e04685f7a4640` |
| `composition-close-four-green.log` | `a394284b9606e77abfd03c4c759913a92be3c5f8d61b76fd292fc0ea11ea9f9e` |
| `composition-close-frozen-related.log` (single60/6) | `a257b937f1fec74bfbbd5d7b67f439dd616968144847ea28fb80b8f4b656e512` |
| `composition-close-checkpoint-inputs.json` | `11325aa57e5f51fbe8ef764303f8a84c68d6d2101e8ca6ab4589fcd62d575806` |
| `composition-close-checkpoint-post.json` | `dc7a3caf7184696da2a7fb294a9e969b4670050de63f5c2cb528d1a8d2ed82ed` |
| `composition-close-checkpoint-commit-match.json` | `0bfa5fd20221b95eb5e19f6d7cc969779defc0402dcf32b00d482367c6e07343` |

This clean dependency handoff stops author writes until root returns the tree. Accepted043/046/047 must be ordinary-merged and their actual APIs consumed after review. Both known047 tests remain intact. Final App route assembly, full Health selection coverage, mailbox drain and strict Cloud replay, complete build/test matrix, real SDK/device/account/App/UI/power-loss and whole026 acceptance remain pending. Empty ignored `.swiftpm/xcode/` metadata remains the saved exception; no cleanup or long-lived branch promotion is performed.


### Strict Cloud proof replay checkpoint

Source `91a2e7b12475452342e81c94b53eb4f6d406e0f2`, on actual dependency merge5658e4: original missing-internal-proof and restored-v3 cases were RED2tests/6assertions and become2/0 through accepted047 APIs. Frozen related Composition11 + Recovery31 = **42tests/1unexpected**;349 inputs before/post/commit0diff. The remaining test is `testConcreteCloudLeafPreservesUnknownLiveLayoutAfterFirstReceipt`: the strict constructor fails before its first receipt on a legitimate initialized v4/WAL DB that has no business write or WAL sidecars. Original DB/inode and copied bytes are preserved; a read-only SQLite probe also fails quick_check while immutable read-only inspection returns ok. This is an upstream boundary under investigation, not a SQLite close failure or device failure. No added enqueue, skipped assertion or schema repair is used.

Evidence: `strict-cloud-postmerge-red.log`, `strict-cloud-two-green.log`, `strict-cloud-checkpoint-inputs.json`, `strict-cloud-frozen-related.log`, `strict-cloud-frozen-related-post.json`, `strict-cloud-commit-match.json`, `strict-cloud-empty-wal-fixture.json` and preserved SQLite copy under `/private/tmp/football-record-NATIVE026-build/bootstrap`. Frozen related log SHA256 `9a2483854833559a960fdadee6c44354e4a4e63f9563eb3d52a0a5efdbff5b8f`. No whole026, App/UI, real SDK, account/device or power-loss claim.


### Original Session gate before held identity join

Source `b871387c58d49170a1a1f82fc2ed324a4ade17ee`: an original Session request is prepared before a cancellation-insensitive identity observation is held; quiesce must yield actual typed `SessionError.retired` while that observer remains held. Executing the same prepared request must issue zero first Authority HTTP requests. Actual old-code RED1test/3assertions records absent typed gate, non-retired execute error and HTTPcount1. Minimal ordering repair gives the same case1/0 and frozen Composition12 + Context7 + DevicePair1 =20/0, including original held-capture positive facts and replacement failures.349 product inputs before/post/commit0diff. No new factory, Session, DB, or real provider is used.

Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/quiesce-identity-gate-`: red.log/red-source.swift/tests.swift, green.log, inputs.json, frozen-related.log, post.json and commit-match.json. Related log SHA256 `2334ec845754cdfab2d0257f4d6cf2084d82459df66a2239d24dc3576cf46a90`. This is separate from048 public shutdown/held intent commit and from the earlier strict replay42/1unexpected layer; not whole026/App/SDK/device acceptance.


### Complete046 Health inventory and completed Store recovery

Source `cb5e7d504ced83fcf83292fb9453db1a77e9bf29`, frozen349 before/post/commit0diff. Canonical runtime RED3tests/8assertions → scoped3/0, then frozen related Composition12 + Recovery34 + Context7 + DevicePair1 =54tests/1unexpected (sole existing strict empty-WAL Cloud constructor case, other53 pass). Related log SHA256 `9b772c8babf79ee183035c365df05016333edaeea7c33787abfc240ff200f89e`. Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/health-inventory-`: red-initial.log (initial fixture authority-timing error), red-canonical-fixture.log (stable runtime RED), red-M4AccountComposition.swift/red-M4LocalTransportDeletion.swift/red-tests.swift, green-initial.log, green-reopen.log, inputs.json, frozen-related.log, post.json and commit-match.json.

The fixture uses public canonical StoreCommit facts on the one original M4 facade before account binding. For the stale-selection case, raw is frozen before a second original pending capture; the real original Session/gateway is held, its permanent gate is observed, linked evidence is released/persisted/joined, and only then is that same facade bound and the original parent sealed. Binding mid-capture would invalidate this explicit seed authority provenance, and that initial failed fixture remains separately logged. This is controlled unbound-development evidence, not authenticated capture or E2E.

Valid first erase and actual close/reopen keep raw canonical bytes, same parent and first receipt bytes. Historical completed reads use fresh045 on the same original Store; empty046 inventory never replaces the old raw selection. Stale late-linked facts reject with identityConflict and preserve original business while independent Cloud completes. A removed canonical capture parent still returns empty old matchIDs but the actual046 complete inventory raises StoreError and preserves the original Store and raw artifact. Full Health SDK deletion, production copy drain, real accounts/devices and whole026 remain unverified.


### Controlled043 original clients, actual copy drain and final close

Source `09c78a049aa6b104b6220c851d858c8d3ffabc61`: new-interface compile RED is logged separately; after construction/attachment, the real original client lifecycle RED was2tests/10assertions/0unexpected. Before wiring ownership, a pending Apple mailbox result escaped quiesce and undrained final close incorrectly released original DB/lease. Minimal original-composition quiesce/finalclose wiring gives unchanged lifecycle2/0; namespace/production-beforeDB and second-facade rejection complete scoped4/0. The test sends real controlled043 Apple and same-parent Cloud-delete protocol messages, not fake adapter success. Quiesce cancels/joins original Apple work while the same original Cloud-delete client continues for the already accepted parent. Unknown mailbox bytes are preserved and block copy drain and final DB close; removing only the fixture-owned exact file permits original close retry and same-parent DB reopen. This is a client/mailbox ownership refusal, not a SQLite close failure or actual device fault.

Frozen related Composition14 + Recovery36 + Context7 + DevicePair1 =58tests/1unexpected, solely the already preserved strict empty-WAL Cloud constructor issue;57 pass.350 inputs before/post/commit0diff. Separate non-DEBUG `swift build -c release --target AppIntegration` passes on the macOS14 host; no lowest iOS/watch SDK, App/UI, real SDK, account/device, power-loss or whole026 acceptance is inferred.

Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/controlled-clients-`: interface-red.log, owner-red-initial.log (initial unexpected release-path layer), owner-red.log (runtime2/10), red-M4AccountComposition.swift/red-M4ControlledAdapters.swift/red-tests.swift, owner-green.log, scoped-green.log, inputs.json, frozen-related.log, release-host-build.log, post.json and commit-match.json. Related log SHA256 `70bd67d1c15587ba26dc1b338cacebcb71ce871857d1dbafad9c30ba498484d1`; Release host log SHA256 `22b4f9143d57f68aa526d9fd29f4b1ebfc04fd19775bee65f2ffde08e437f0f2`. UI AccountService late durable-acceptance and public048 early-owner path remain separate integration work. Author stops clean for root048 merge.


### Actual M4 public early-owner integration after048 merge

Source `c8864ade5a6ecf7f21aaa21c18ac385ff2d5245a`: original M4 RecordingModel.start is held at an already dispatched original Authority HTTP request. Calling public AccountAppContext.shutdown twice must establish the actual original SessionError.retired gate while the original operation is still held, then join it before releasing the original DB. Actual old caller RED1test/1assertion → frozen related23/0;351 before/post/commit0diff. One original HTTP call is explicitly asserted; this is not048's pre-first-permit fixture. Same repo/Session identity, permanent old gate, cleared UI and original intent with no permit/events on actual DB reopen are retained. No new factory/Session/DB or real SDK is substituted.

Evidence `/private/tmp/football-record-NATIVE026-build/bootstrap/public-owner-048-`: red.log, red-source.swift, tests.swift, inputs.json, frozen-related.log, post.json and commit-match.json. Related log SHA256 `694e13d72973f751043f20f83375339527cb349383a9e0318e37c6b081a39b04`. Historical controlled58/1unexpected and Release build remain distinct. This caller scope does not close whole026, App/UI,050 account/Watch service retirement or real account/device gates.


### Completed controlled result cannot cross the second identity await

Source `89a70f714fbd0a7fc6c2315601427fca19b6d2eb`: actual Apple and Cloud.save protocol work completes before a DEBUG reply-only hook holds the real original repository's second identityGenerationV4 reply. Quiesce establishes permanent admission stop while that reply is held; releasing it must reject success. Runtime RED2tests/2assertions/0unexpected → frozen related10/0;351 before/post/commit0diff. The original generation and repo identity remain equal before/after; no DB/Session/identity is fabricated. The repair retains original generation equality while adding fresh post-await stop/final-stop/lifetime checks. Controlled HTTP/Saga policy and original join behavior are retained.

Evidence `/private/tmp/football-record-NATIVE026-build/bootstrap/controlled-late-generation-`: red.log/red-source.swift/tests.swift, inputs.json, frozen-related.log, post.json and commit-match.json. Related log SHA256 `03aa17f32cbf934b3ab88e6eaadb9d064ed872d3d48033ec95106bae51affb46`. This exact10 selection contains new Apple/Cloud cases, controlled ownership/isolation and public/identity lifecycle regressions; it is not the historical full58 run or whole026 acceptance.


### Formal default App startup remains unavailable before DB opening

Source `45a742336c1dfe2ec5add670d27d8bd9c2a89420` routes the normal iPhone and Watch entry through M4ApplicationBootstrap.production. It returns typed unavailable without reading Debug configuration, adopting legacy files or opening a business DB. A host regression passes both fresh and preexisting-file roots plus development/UI/device flags, preserving file lists and bytes; the preexisting arbitrary bytes are an adoption sentinel, not a claim of valid SQLite data. The no-context App branch displays unavailable/retry without constructing a fake repository or Session. M4ApplicationContext retains one original composition and exposes its throwing final-close owner; the full controlled App assembly/action lifecycle is still a later slice. Existing explicit Debug scenarios and Presentation compatibility factories are retained at this checkpoint.

- New API compile RED is preserved in production-bootstrap-interface-red.log. Frozen exact new host regression:1/0.
- Two actual unsigned generic **Debug** Simulator App build commands exit0: FootballRecord-iOS and FootballRecord-Watch. Build logs contain minimum iOS17/watch10 targets and BUILD SUCCEEDED, with zero Swift compile errors. No App/UI execution, Release App build or real provider/device/signing acceptance is inferred.
- All351 product inputs are byte-identical before/after and match the source commit; diff-check passes.
- An earlier regex unintentionally matched the AppIntegrationTests module and ran188tests/1unexpected. The sole failure is the preserved testConcreteCloudLeafPreservesUnknownLiveLayoutAfterFirstReceipt strict empty-WAL constructor issue awaiting049. This run has no before-input manifest and is explicitly expanded/unfrozen evidence, not whole026 PASS; its raw log and metadata are retained without another full-suite rerun.

Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/production-bootstrap-`: interface-red.log; related-green.log and expanded-run.json (unfrozen188/1); inputs.json; frozen-assembly.swift/frozen-phone.swift/frozen-watch.swift/frozen-tests.swift/frozen.diff; frozen-selected.log; phone-sim-build.log; watch-sim-build.log; validation-results.json; post.json and commit-match.json.

| Exact log | SHA256 |
| --- | --- |
| frozen-selected.log | `878d2421bd00f97ab70f7c461420ab50d1b3e7813b283c30b3f29fff58fb3c62` |
| phone-sim-build.log | `08ab106a68af4d98b7a270d1af79a5a6baa86f8756d27bd6141399f9d60806f8` |
| watch-sim-build.log | `2541824ffac556495d5898738ea71057dc3cd78b70a751b10b074ee26707f660` |

This clean handoff is for root to ordinary-merge accepted049. Full controlled App service ownership, independent fresh identity inputs, retained material/Phone inbox seams, Node E2E, whole026 source/final review and deferred real SDK/account/device validation remain separate.


### Complete original account and Phone service task ownership

Source `e84c224368d6481a0a450fd4aa554b9835a4d404`, based on accepted050 actualmerge0e7292df9b1f4eef2edc31d3d7954eee92ceb892. The one original facade/Session and real AccountService accept a fixture-authority signed original pending recovery reply. Before the first local binding, independent account/cloud/environment/generation observation is required; after the original service and credential tail finish, another fresh observation and existing checked038 admission are required. No configured subject or retained credential stands in for current identity. The first-local-binding fixture is explicit pending AuthAttempt recovery, not a new Node signup. Positive verified SQL and original attempt bytes remain retained on later mismatch.

- Placeholder Model callback RED:4tests/8assertions/0unexpected. Its initial missing-try fixture compilation log remains separate.
- After minimal service wiring, actual held vault.replace (signature verified and original Session SQL already committed) reveals premature quiesce and public/throwing close releasing the original DB:5tests/3assertions/0unexpected. An earlier timing-insufficient4/0 log is preserved separately, not relabeled as meaningful owner RED.
- Minimal direct Phone forwarding plus a held real original signed HTTP request reveals premature business acknowledgement; a failed new current cloud observation also left the old ready UI admitted:3tests/2assertions/0unexpected. The initial wrong endpoint type compile log is separately retained. The accurate accepted040 type is M4PhoneWatchRegistrationEndpoint.
- The same eight final cases pass8/0. They prove original credential-tail join, public Void/throwing shared owner, DB retention and reopen, same repository/Session identity, fresh pre/post identity, prior admission removal, Phone context/retired rejection and complete Phone call join. The Phone fixture returns an explicit unavailable HTTP error after release; it is not a successful backend registration. Callback errors return before the outer caller invokes drain, so tracked callbacks never await their own business join.
- Frozen related **79/0** in one command: Composition23, Recovery38, Context7, Identity10, DevicePair1. Separate non-DEBUG Release macOS14 host AppIntegration product build exits0. All **353 inputs** remain unchanged before/post and match the source commit; diff-check passes. This does not repeat or absorb root's earlier188/0/Session66 evidence, minimum mobile SDK/App/UI, real provider or Node E2E validation.

Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/service-owner-`: unwired-initial-compile.log; unwired-red.log/source.swift/tests.swift; unowned-initial-green.log (timing layer); vault-tail-red.log/source.swift/tests.swift; vault-tail-green.log; phone-initial-compile.log; phone-red.log/source.swift/tests.swift; eight-green.log; inputs.json; frozen-source.swift/frozen-tests.swift; frozen-related.log; release-host-build.log; validation-results.json; post.json and commit-match.json.

| Frozen log | SHA256 |
| --- | --- |
| frozen-related.log | `f74c1acc124b5ed2f0d10de835cecd8543865af0adf0444321409f5e8038f2bf` |
| release-host-build.log | `51723bf6a952b7fde545644df4adcd25b3bc27a25a665e12c44eef881e68b388` |

identityChanged and Lifecycle action callbacks remain explicitly unavailable here; no blanket business gate is applied to original Saga/Lifecycle controls. The existing registered deletion resume/reconcile owners still drain only at final close. Full control action ownership, new signIn/Watch protocol coverage,051 material/inbox assembly,052 pending-deletion fresh reauth and whole026 source/final review remain subsequent work; no unreviewed APIs or new DB/Session are used.


### Additional fresh signIn and complete Watch protocol coverage

Test-only source `056fa7c619e83a2c9dec856c0cac7dea1709387c` leaves implementation e84c224 byte-identical. The fresh Phone case drives the real original AccountService challenge, actual043 Apple mailbox, original device challenge signature (verified by the controlled relay), signed authority receipt, first local binding and second independent identity observation through the public Model callback. No pending AuthAttempt is preseeded for this case. The configured subject deliberately differs from the independent current identity fixture.

The Watch cases drive original WatchRegistrationService with040 typed relay and actual043 phone-context/phone-register mailbox calls. One complete successful path obtains two original context observations, retains exact canonical attempt and receipt bytes, binds only the original Watch device credential and checks one repo/Session. The second path holds actual vault.replace after original positive SQL; original Session retirement must become typed retired while full business drain still waits and the original DB remains readable. Releasing the credential tail permits drain, retains positive facts and never readmits the old UI. These tests use explicit signed protocol replies, not a real Node backend/Phone process, SDK or production authority.

Scoped3/0 then one frozen full Composition class26/0;353 before/post/commit0diff, diff-check0. Frozen log `/private/tmp/football-record-NATIVE026-build/bootstrap/service-fresh-flows-frozen-composition.log` SHA256 `2b58ae60063ad1f434df9b96a6c1122733aace59ba010bd66d1065ae59c27d7d`. inputs.json, post.json, frozen-tests.swift and commit-match.json share prefix service-fresh-flows-. Earlier fixture-config-initial.log preserves strict namespace3unexpected; three.log and diagnostic/diagnostic-counts logs preserve noncanonical Challenge3unexpected and finite original invalidWire/read/HTTP counts. canonical.log is the corrected3/0. The fixture corrected its own namespace/canonical encoding; no product or upstream source changed.

The previous service-owner79/0 and Release product build remain separate evidence. They are not combined into a fabricated82-test single run.051/052 have not been consumed; full material/inbox/control assembly, actual Node E2E, App/UI, real account/device/provider and whole026 acceptance remain pending.


### Cancelled late factory result retains and drains its original owner

Source `80101c5dbe23befc1794e90a42aeb2f959622054` keeps cancellation tied to the actual caller Task through the asynchronous factory. If that caller was cancelled while the factory was held, the real returned context becomes the retained current owner before shutdown is awaited; only successful shutdown clears it and returns CancellationError. A close failure propagates its original error, retains that same owner and prevents the next factory. This uses the existing FIFO without an unstructured worker or a synthetic cancellation flag.

Two actual regressions were RED2tests/3assertions/0unexpected, then the unchanged two cases pass2/0. The first holds the original Session capture gateway inside the real factory, cancels its caller, queues a valid replacement and proves the original positive observation is joined/persisted before DB close or the queued factory. The second replaces the actual retained identity.owner inode with a foreign fixture file and proves the original identity-lease preflight refuses close, the original DB remains readable, both cancelled and queued calls receive failure, and no queued factory executes. Restoring the same original inode permits retry of that same unpublished owner. This is a lease-preflight refusal, not SQLite.close failure or a device fault; the capture fixture is explicit unbound development.

The first frozen related command was36tests/1unexpected: the existing Watch credential-tail fixture enumerated an outgoing mailbox JSON that the real client consumed before Data(contentsOf:). Its original log and353-input before/post manifests remain preserved. Root-approved helper-only commit `e980e7fdeaa544b8e93eed71d8139f47033a3b6f` retries exactly NSCocoaErrorDomain/NSFileReadNoSuchFileError260 at that read; other reads and JSON errors still throw. It neither changes product behavior nor removes business assertions, and the fixture race is not counted as product RED.

After that separate fix, the exact frozen related command passes **36/0** (Context9 + Composition26 + DevicePair1),353 inputs before/post/commit0diff and diff-check0. Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/factory-cancellation-`: red.log/red-source.swift/red-tests.swift, green.log, fixture-race-frozen-related.log/fixture-race-inputs.json/fixture-race-post.json, inputs.json, frozen-source.swift/frozen-tests.swift/frozen-mailbox-tests.swift, frozen-related.log, post.json and commit-match.json.

| Log | SHA256 |
| --- | --- |
| red.log | `0e55288b272c2c92c14db266af47475c5354ce5dbb534be06501412265bdfef7` |
| green.log | `7773e7dce34ca9ee0d89809757faa35774786ea6e66c406022aecab29a6ebbad` |
| fixture-race-frozen-related.log | `aeb5d0d3688e516e438bfa12e0617e70d9491fc3d39cb61dd64b736f3c27fca2` |
| frozen-related.log | `15c156bc4418b7ab1197b406dfedebf03f7ea17d53d5a5fba6a8765f0b0205ca` |

No Release/SDK/App/UI matrix was rerun for this scoped checkpoint. The previous79/0, Composition26/0 and Release host build remain separate layers;36/0 is not whole026 acceptance. Author stops clean for accepted051 dependency handoff, preserving empty .swiftpm/xcode metadata. Material/inbox and control reauthentication assembly, actual Node E2E, whole026 source/final reviews and deferred real account/device/provider tests remain pending.


### Original identity control and independent DEBUG observation input

Control source `102c3d23fd92d12b32b2ff1485c616979a786185` and independent input source `eba525e8433017ac37792fadd7c3d681806a4ed6` are separate logical commits based on actual051 mergea20dcb0. Original identityChanged placeholder produced runtime2tests/12assertions/0unexpected; unchanged2/0 after routing the action to its own shared control Task, never to the business group it must drain. Actual original Session persists suspension/generation, original vault drops the old credential, original real SQLiteCloudLedger records accountChanged, analytics are off and the same facade/Session remain. A held original identity observer cannot delay the permanent Session gate or readmit the old UI. The third case proves missing ledger returns unavailable after permanent business retirement, retains original binding/generation, permits installation of the real original ledger/scope and retries the same owner; repeated successful action does not increment generation again. Final close cancels/joins the identity control before releasing resources. The registration binds the supplied original scope against the original binding; a new observed identity never selects old ledger scope. App assembly has not supplied this resource yet.

The DEBUG observer borrows an explicitly prepared private directory with apple-account.json and cloud-space.json. Both closed canonical JSON objects contain version1, environment development, exact namespace and the same canonical UUID observationID; only Apple contains accountID, while Cloud contains cloudSpaceID and zoneID. Each original file must be current-uid, single-link,0600 and1...16384 bytes; directory0700, original inode/parent chain, no symlink, and full before/after byte readback are checked. No configured subject/cloudSpace, retained credential/binding or pending request supplies identity. Every call rereads the original files, with monotonic generation/lifetime checks across awaits. The observer never creates/modifies/deletes borrowed input; observationID is a pairing label, not real authentication freshness. Three actual file/held-reply cases cover changed in-place contents, pair mismatch, missing input, permissions, identical-byte replacement, parent replacement, wrong environment, extra fields and late bytes/generation. Interface compilation RED is separate; no missing API compilation is presented as a product runtime RED.

Frozen related command passes **52/0** (Context9, Composition29, Identity13, DevicePair1),355 before/post/commit0diff, diff-check0. Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/identity-control-input-`: inputs.json, four frozen source/test copies, frozen-related.log, post.json and commit-match.json. Frozen log SHA256 `8731d2b5c0ece37436b966c4f4c68e7e6bc21463ad3af7e06bbab29834fe4408`. Separate earlier evidence: identity-action-interface-red.log, identity-action-red.log/red-source.swift/tests.swift, identity-action-green.log, independent-identity-interface-red.log and identity-owner-and-input-green.log(5/0 before the extra retry case). No Release/SDK/App/UI/Node E2E or whole026 matrix is inferred. Next assembly work must connect accepted051 material before the sole businessDB, original Phone inbox stop/join and actual original ledger/scope.052 remains unconsumed.


### Original051 Phone inbox follows original business retirement

Source `d594a3a0d2f26e17ce26e5b34618156e0e8d80f6` starts the original accepted051 clients with M4OriginalPhoneAuthorizer, so each incoming typed Phone request calls the same original service after a fresh independent current observation. A successful request uses original device/Session; the next request after changed current cloud identity returns unavailable, removes old ready UI and never borrows configured subject/credential as identity. A held original observation blocks business retirement acknowledgement until it joins, and no response is published after stop. Borrowed incoming requests remain preserved; the fixture broker removes only its exact own request/reply after assertions.

Interface-red.log records the missing new026 start entry separately. Minimal start-only integration produced runtime **2tests/1assertion/0unexpected RED**: quiesce returned while the old inbox could still publish an error on a new incoming request. The accepted051 original stopInbox is now called and joined during M4ControlledAdapters business quiesce, with fresh post-start stop/final-stop admission; unchanged2/0 passes. No mailbox implementation is copied and no full client close occurs during business retirement. The existing real same-parent Cloud-delete/HTTP control recovery tests are included in the related run.

One frozen related command passes **92/0** (Composition31, Recovery38, Context9, Identity13, DevicePair1),355 before/post/commit0diff and diff-check0. Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/original-inbox-`: interface-red.log; red.log and two red source copies/tests.swift; green.log; inputs.json; three frozen source/test copies; frozen-related.log; post.json and commit-match.json. Frozen log SHA256 `0818a80d27ebd71c17f6282e40d12682b21ab79b7553be4d2ea328e6a077a97f`. The earlier52/0 is a separate source layer. No App/SDK/Node E2E or whole026 acceptance is inferred; material-beforeDB/App assembly and original ledger/catalog route provisioning remain next work, with052 unconsumed.


### Formal controlled App uses original051 material and M4 owner

Source `a8f69cba993cd95dc714aebfd0d2599702114064` adds the DEBUG controlled M4 bootstrap. It reads private bounded0600 configuration, then validates the separate borrowed independent observation inputs before namespace/lease/businessDB creation. The original M4IdentityBootstrap lease supplies the same installationID to accepted051 deviceMaterial; returned namespace/deviceID must match exactly, and its original signer/vault precede the only business facade. No legacy DevelopmentAuthorityRuntime, extra Session or fake repository is constructed. Both formal App entries now use this M4 owner, retain it before async activation can fail/cancel, then start original051 Phone inbox only on Phone and perform a fresh checked admission only when a binding already exists. No configuration/retained credential opens recording by itself. The visible marker says development rehearsal/simulated identity.

Three new host cases pass3/0: absent independent input leaves no business namespace or identity lease; Phone and Watch each reopen the same original installation/key on one Session/facade without automatic account admission; and missing original development.key beside an existing DB preserves exact DB/identity bytes without replacement. The initial missing controlled API compilation is in controlled-bootstrap-interface-red.log; controlled-bootstrap-three.log separately retains the missing MatchStore import compiler error, fixed before controlled-bootstrap-three-after-import.log3/0. These compilation layers are not called runtime safety RED.

One fixed355-input snapshot passes **58/0** (new bootstrap3 + production-beforeDB1 + Context9 + Composition31 + Identity13 + Pair1), followed by two actual unsigned generic **Debug** Simulator builds (FootballRecord-iOS and FootballRecord-Watch), both BUILD SUCCEEDED. Inputs before/post/commit0diff; diff-check0. No App/UI run or real provider/account/device/signing operation occurred. Release runtime isolation, actual Node E2E, the full40-SDK/six-App matrix and whole026 source/final review remain later work.

Evidence prefix `/private/tmp/football-record-NATIVE026-build/bootstrap/controlled-bootstrap-`: interface-red.log; three.log; three-after-import.log; inputs.json; five frozen source/test copies; frozen-related.log; frozen-phone.log; frozen-watch.log; validation-results.json; post.json and commit-match.json.

| Frozen log | SHA256 |
| --- | --- |
| frozen-related.log | `c0b9fd19567d1ba76b71868cacd65346f8615fb1ce3bfebb1cab5724347a01b7` |
| frozen-phone.log | `71efb3a276f66f346f6e8005d5f2ecac828c1637d8d6548d7a29805e50be0e63` |
| frozen-watch.log | `040f3377879443119d770a21277aeb426dab3c6c43b2f0cee0a361f742acdb5b` |

This minimal factory still has no actual original CloudLedger/catalog resource owner. Its identityChanged action therefore permanently pauses/joins original business but explicitly returns unavailable without claiming AccountKit's full ledger fence. The next owned resource slice must use real original ledger plus durable catalog scope, preserve unknown/missing mappings and run within complete service/control ownership.052 remains unconsumed. Prior92/0 and52/0 stay separate source layers.
