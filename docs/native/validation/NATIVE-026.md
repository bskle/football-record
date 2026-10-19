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
