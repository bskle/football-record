# NATIVE-008 validation and handoff

Compiled source checkpoint: `670609200dcadc91c61a88f734c0701b01f05896`. Base: `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`. Author `/root/m2_workout_capture`; earlier sourcefcb4020 passed root/spec source reviews, while final review of this checkpoint and the NATIVE-011 synchronized result remains pending. No task merge or real-device acceptance is asserted.

NATIVE-011 merge `f26d60de81fb5afa90e2f16044a09675d71ee834` has been reported by root; actual merged-tree verification is still running at this checkpoint. It is not yet a verified dependency and has not been merged into this task. Root will synchronize after verification, then this author will execute the terminal cross-layer closure and final automatic checks. This record is a checkpoint, not a completed-task handoff.

## Executed automatic checks

| Check | Actual result |
|---|---|
| WorkoutCapture host XCTest at source6706092 | 35 passed, zero failures |
| Original unchanged-base core regression | 131 passed: Core44, Store55, Session32; predates NATIVE-011 |
| Module explicit arm64 iOS17 simulator SDK at6706092 | passed, no warnings |
| Module explicit arm64 watchOS10 simulator SDK at6706092 | passed, no warnings |
| Module explicit arm64 iOS17 device SDK at earlier fcb4020 | passed unsigned, no warnings; post-sync repeat pending |
| Module explicit arm64 watchOS10 device SDK at earlier fcb4020 | passed unsigned, no warnings; post-sync repeat pending |
| Ownership / whitespace / worktree inventory | only own module and task documents; no ignored build products or untracked assets requiring preservation |

Package-local entrypoint: `WORKOUT_BUILD_ROOT=/tmp/football-record-NATIVE008 native/Modules/WorkoutCapture/Scripts/verify.sh`, exit 0 at source6706092, checkpoint stage logs `20261016T031959Z`. It runs host tests plus explicit simulator SDK builds. Earlier sourcefcb4020 device SDK compilation used the same swift build target with `arm64-apple-ios17.0 --sdk iphoneos` and `arm64-apple-watchos10.0 --sdk watchos`, scratch roots `iOSDevice` and `WatchDevice` under the same task-specific /tmp root. No device was contacted or signed App produced. Core regression used its own `CoreRegression` scratch directory; core source is unchanged from base. Apps/project/capabilities/other modules were not touched.

## Red-to-green and cross-layer evidence

- Initial missing-API red then runnable lifecycle assertions preceded the gateway implementation. Stable operation/token binding, original-session reattachment without start, denied writing, unknown reads, same-token terminal cleanup and save ordering are covered with protocol drivers.
- Exact old failed-stop condition produced three runnable assertion failures: second terminal command never stopped or saved. Completed failed stop work now allows retry of the original driver; real SDK endCollection/save attempts remain guarded.
- Historical pause windows reject delayed GPS batches recorded during pause even after resume. A late pre-pause accepted point retains its old continuity so distance does not bridge the pause. Invalid accuracy/negative or nonfinite speed remains unknown; true zero can be available. Route insertion failure permanently stops that writer.
- MetadataReadinessTests use the same readiness gate consumed by actual SDK callback handling: timeout does not consume a real callback; late success starts location once, while terminal state only finishes the original token.
- RecoveryEvidenceCacheTests use the same factory decision/cache: late original session and saved nil,nil survive timeout; source/full-binding query validation rejects foreign objects; linked proof cannot regress. The old awaiting-link shortcut produced four runnable failures. Cached active→nil,nil now directly queries UUID without first recovering a session; empty/locked query retains awaiting proof, linked UUID alone short-circuits.
- SessionPersistenceTests actually inject AppleWorkoutGateway with a fake driver into public NATIVE-007 MatchSession and a real temporary SQLiteSessionRepository, then reopen the same database file through new connections. Start-observation COMMIT failure and save-observation pre-COMMIT failure / post-COMMIT lost response retain the original operation and token; creations remain 1 and save remains 1. nil,nil creates no segment. A later simulated source-validated real-query UUID persists exactly one segment. These are cross-layer protocol tests, not genuine HealthKit samples or UUID evidence.

## Concrete integration interface

Create one main-actor `LiveMetricsChannel`, `AppleWorkoutDriverFactory(metrics:)`, and `AppleWorkoutGateway(factory:)`; inject the gateway into the single MatchSession. Factory uses HKSource.default().bundleIdentifier for saved-object source validation. Live metrics flow independently to presentation; they are deliberately not Codable and never added to SessionSnapshot/business persistence/outbox/logs. The iPhone uses a manual builder, real location-derived distance samples and WorkoutEvents; it does not claim a heart-rate source or start a watch. Watch uses the local live session/builder/data source's actual collected types.

NATIVE-010 owns actual App wiring, WKApplicationDelegate recovery entry, entitlements, usage descriptions, background modes and signing. Its recovery entry invokes existing MatchSession.recover so candidate/device checks happen before original Watch reattachment; no second current-match index, start or beginCollection during reattachment. Package README lists required consumers and capability boundaries. Production permit remains unavailable before M4.

## Known conservative boundaries and physical gate

- iOS17 has no API to recover the original manual builder after process loss. Empty/error/locked/timeout queries remain unresolved; this implementation cannot safely create a new segment from that absence. Only an actual saved UUID can close the previous segment with recoveryUnavailable for MatchSession to decide continuation/gap.
- A stopped recovered Watch session may already have an unresolved finish; it remains conservative instead of calling finish again without proof. Unknown save cannot be relabeled as confirmed recovery failure. Active running/paused original sessions are reattached using their associated builder.
- Source6706092 now proves only a locally fresh original start never attempted construction: while authorization remains pending, local reconcile stays unknown without an unnecessary external recover; terminal locking immediately latches negative proof, before permission returns. Only the original start can report notCreated(.unavailable); finish remains unknown, and cached unknown responses cannot erase the proof. Prior actual recovery/construction/positive existence/window evidence prevents this shortcut. The full persistent finish-cancellation closure requires NATIVE-011 and remains untested until verified synchronization; the new cross-layer regression must hold authorization until finish cancellation is observed before releasing the permission callback. No speculative UUID or completion is manufactured.
- Pending actual-device cases: write authorization/refusal/revocation and unknown read privacy; actual supported sensor samples; GPS/background/lockscreen; bench versus pause and delayed batches; route association/failure; finish nil,nil while locked and UUID after unlock; crash auto-recovery versus user force quit versus reboot; and terminal races/duplicate finish behavior. Force quit and reboot are not promised to restore an original session.

Status: source checkpoint compiled, waiting for NATIVE-011 verified synchronization, full terminal cross-layer regression, final automatic checks/reviews and relevant real-device acceptance. NATIVE-008 must remain on its temporary branch until NATIVE-010 gate passes. No release promotion, CloudKit complete save, production lock, transport E2E, upload, push or distribution is claimed.

## Persisted evidence

External directory: `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-008/`.

`source-inputs-6706092.json` retains source/base and SHA-256 hashes for 66 source/dependency inputs. `6706092-host-tests.log`, `6706092-ios17-build.log`, `6706092-watch10-build.log` are current checkpoint evidence. Earlier `football-record-NATIVE008-fcb4020-*-device.log`, core-regression log and `toolchain.txt` retain their separately versioned checks. `evidence-sha256.json` currently hashes 49 files. `football-record-NATIVE008-negative-sequence-red.log` reports four failures; the 6706092 commit body’s count of six is corrected here without rewriting history. Historical red/intermediate logs are explicitly investigation evidence, not final passing checks. Worktree builds and SQLite test data are outside the tree in task-specific temporary paths.
