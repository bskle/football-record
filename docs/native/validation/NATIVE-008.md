# NATIVE-008 validation and handoff

Source candidate: `754b28b18f44261b0bcd7869b098380a50a8100b`. Original base: `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`. Verified NATIVE-011 dependency: `f26d60de81fb5afa90e2f16044a09675d71ee834`, synchronized by root ordinary task merge `85c2cd72e2810b82a354a0a63237712cd50a28fc`. Core source and shared contract remain byte-identical to verified f26. Production module code remains source6706092; later source commits b33daac/754b28b add tests only.

Author `/root/m2_workout_capture`; source754b28b passed independent quality review by `/root` and specification review by `/root/m2_review`. This final document head is delivered for handoff review. State is compiled/automatically verified with source dual review PASS, pending relevant real-device acceptance. No task merge or device acceptance is asserted.

## Latest executed automatic checks

| Check on source754b28b | Actual result |
|---|---|
| WorkoutCapture host XCTest | 40 passed, zero failures: metadata2, cache4, route5, persistence7, lifecycle18, recovery4 |
| Synchronized core regression | 144 passed, zero failures: Core44, Store64, Session36 |
| Explicit arm64 iOS17 simulator SDK | passed without warnings |
| Explicit arm64 watchOS10 simulator SDK | passed without warnings |
| Explicit arm64 iOS17 actual device SDK | compiled unsigned without warnings |
| Explicit arm64 watchOS10 actual device SDK | compiled unsigned without warnings |
| Ownership / whitespace / worktree inventory | only own module and task documents; no ignored build products or unrecovered assets |

The package-local entrypoint `WORKOUT_BUILD_ROOT=/tmp/football-record-NATIVE008 native/Modules/WorkoutCapture/Scripts/verify.sh` completed exit0; actual final stage logs are `20261016T035453Z`. It runs host tests and explicit minimum simulator SDK builds. The actual device SDK checks separately used `swift build --target WorkoutCapture --triple arm64-apple-ios17.0 --sdk <iphoneos SDK>` and `arm64-apple-watchos10.0 --sdk <watchos SDK>` with task-local `iOSDevice`/`WatchDevice` scratch paths. Core tests used `swift test --package-path native/Packages/MatchCore --scratch-path /tmp/football-record-NATIVE008/CoreRegression`, exit0. No device was connected, no signed App produced, and package compilation does not prove App capability wiring or runtime behavior. Apps, Xcode project, entitlements and root scripts were not modified by this author.

## Real gateway, session and SQLite closure

Seven SessionPersistenceTests actually inject AppleWorkoutGateway using a protocol fake driver into public MatchSession and real temporary SQLiteSessionRepository files. Reopening uses new connections to the same physical file, not an in-memory repository. Fake observations/UUID strings are protocol fixtures, never real HealthKit evidence.

- Two original save-failure tests cover start-observation COMMIT failure and savedAwaitingLink observation failure/lost response. Reconciliation retains original operation/token with one creation and one save. nil,nil creates no segment; a later simulated query UUID persists exactly one segment.
- Four terminal cases first persist an unknown start and an already needsReconciliation finish while the actual fake authorization continuation remains suspended. Only then is local start absence persisted and the finish cancelled using NATIVE-011. Before releasing permission, SQL pending is empty, phase is notRecorded(.unavailable), create/save/segment counts are zero, and business remains endedPendingSync with backend lock held. Cases include normal closure, negative-observation pre-COMMIT failure, negative-observation post-COMMIT response loss, and cancellation post-COMMIT response loss with SQLite reopen.
- After permission is released late, original start/end requests still return their first receipts without duplicate events/operations or creation. Durable absence/cancellation also reads correctly through another connection and an entirely new gateway, without an external recovery call.
- A separate simulated process-loss case discards local gateway evidence before absence is persisted. The new gateway only reconciles original operations, retains unknown/needsReconciliation, creates/saves nothing and does not cancel finish. Empty queries and a missing local constructor cannot manufacture absence.

The first b33daac full run exposed a valid generation race in an older test: a recovery observation could COMMIT between end prepare and execute, correctly producing staleGeneration. Test-only commit754b28b now checks the immutable original command has no committed receipt before preparing a new command; uncertain/saved work retries the exact request. Product CAS behavior and original-receipt assertions remain unchanged. That failed historical run is retained; final source754b28b reran all 40 tests, not just the formerly failing test.

## Red-to-green and callback boundaries

Initial missing-API then runnable lifecycle red assertions preceded gateway implementation. The exact failed-stop condition produced three red assertions; a completed failed stop can retry the same driver, while SDK endCollection/save attempts stay guarded. MetadataReadiness is the same gate consumed by the real Apple callback: deadline does not consume the first actual callback; late success starts location once, or only finishes the original token after terminal state.

Historical sample-time pause windows reject delayed paused GPS batches after resume. Late pre-pause accepted points retain their old continuity so manual distance does not bridge the gap. Invalid accuracy/negative or nonfinite speed stays unknown; actual zero may be available. Fatal route insertion permanently stops that writer.

The production factory consumes RecoveryEvidenceCache’s tested decision: late original session and nil,nil save evidence survive timeout; source plus full match/device/token validation rejects foreign objects; linked proof cannot regress. Cached active→nil,nil directly queries a UUID, empty/locked query retains awaiting proof, and only linked UUID short-circuits. The old awaiting shortcut produced four runnable assertion failures.

The approved fresh-start negative proof requires an actual local fresh perform, no constructor invocation, no real recovery attempt, no positive existence or actual-window evidence, and terminal locking. Local reconcile while authorization hangs adds no unnecessary external recover. Terminal locking latches no-creation proof before permission returns; only original start can report notCreated, non-start observations remain unknown, stale cached responses cannot erase proof, and late permission cannot construct a driver. The preserved negative-sequence red log reports four failures; the 6706092 commit body’s count of six is corrected here without rewriting history.

## Concrete consumer handoff

On the main actor create one LiveMetricsChannel, AppleWorkoutDriverFactory(metrics:) and AppleWorkoutGateway(factory:), then inject the gateway into the single MatchSession. Factory binds saved queries to HKSource.default().bundleIdentifier and all original binding/token values. Observe live metrics independently from SessionSnapshot. The channel, points and metrics are deliberately not Codable; health values do not enter business persistence/outbox or logs.

Watch uses a local soccer/outdoor session, its associated live builder and the data source’s actual collected types. iPhone17 uses a manual builder, actual location-derived distance samples and HealthKit pause/resume events, without inventing a heart-rate source or launching Watch. End drains accepted route points, observes Watch stopped, ends collection, finishes once and ends Watch session after save proof. Builder-owned routes are not separately finished.

NATIVE-010 owns actual Apps, WKApplicationDelegate recovery entry, capability/entitlement/usage text/background mode wiring and signing. Its recovery entry invokes MatchSession.recover so candidate/device checks precede original-session reattachment; it does not create a second current-match index, call startActivity or beginCollection during reattachment. Production permits remain unavailable before M4. Module README lists the exact consumer and capability boundaries.

## Remaining physical acceptance and conservative cases

- iOS17 cannot recover an original manual builder after process loss. Empty/error/locked/timeout queries remain unresolved and cannot justify another workout. An actual saved UUID may close the old segment with recoveryUnavailable, after which MatchSession decides continuation/gap.
- A stopped recovered Watch session may already have an unresolved finish, so it does not blindly call finish again. Active running/paused original sessions reattach their associated builder; unknown save is never relabeled as confirmed recovery failure.
- Pending real-device cases: actual write authorization/refusal/revocation and read privacy; supported sensors/samples; GPS/background/lockscreen; bench versus pause and delayed samples; route association/failure; locked finish nil,nil and UUID after unlock; crash recovery versus user force quit versus reboot; terminal/duplicate callback and saving races. Force quit and reboot do not guarantee restoration.

NATIVE-008 remains on its temporary branch for reviewed NATIVE-010 integration; relevant physical tests must pass before integration into dev. No complete-save, production lock, transport E2E, release promotion, push, upload or distribution is claimed.

## Persisted evidence

Directory: `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-008/`.

`source-inputs-754b28b.json` contains original base, verified dependency, sync merge and SHA-256 hashes for 69 module/core/contract inputs. Its SHA-256 is `4007beaa331fa49356854a4d58c22414eb60315650d57e075991a7212f5e523b`.

Final evidence is `754b28b-host-tests.log`, `754b28b-ios17-build.log`, `754b28b-watch10-build.log`, `football-record-NATIVE008-754b28b-{core,ios-device,watch-device,all}.log`. `evidence-sha256.json` hashes 63 files, SHA-256 `9f5f170c45983b28a0f1e1c8003b8e47ad987dcb27d887e9cbb6e6587b8a9b4d`. Earlier input manifests/red/intermediate/failed logs remain historical investigation evidence and are not final passing checks. Builds and SQLite test data live under task-specific temporary paths outside the worktree.
