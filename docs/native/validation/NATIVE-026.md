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
