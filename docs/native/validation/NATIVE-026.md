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
