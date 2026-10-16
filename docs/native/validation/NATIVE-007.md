# NATIVE-007 validation

Source candidate: `dd89f9f6592b6556d02dd7bea520f9ab7195184c`; original base / target `7680ef6c45eab75105b244dd08f98f785adaa918`. Author `/root/m2_match_session`; quality review by `/root` PASS on this exact source; specification review by `/root/m2_review` pending final confirmation. This record does not assert integration or device acceptance.

## Executed verification

`NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE007 scripts/native/verify.sh` completed exit 0 against source candidate above. Actual logs: `/tmp/football-record-NATIVE007/logs/20261016T022957Z`.

| Check | Actual result |
|---|---|
| Host XCTest, real temporary SQLite | 131 passed, zero failures: MatchCore 44, MatchStore 55, MatchSession 32 |
| MatchStore explicit iOS17 simulator SDK | passed |
| MatchStore explicit watchOS10 simulator SDK | passed |
| MatchSession explicit iOS17 simulator SDK | passed |
| MatchSession explicit watchOS10 simulator SDK | passed |
| FootballRecord-iOS unsigned generic simulator build | BUILD SUCCEEDED |
| FootballRecord-Watch unsigned generic simulator build | BUILD SUCCEEDED |
| Diff whitespace / owned paths | checked; no App/Xcode/Configuration/other Module edits |

Xcode 27.0 / Swift 6.4 toolchain details and immutable source input hashes are retained externally. Build outputs use `/tmp`, avoiding Desktop FinderInfo. Apps remain the existing preview shells; building them is regression evidence, not an implemented recording UI or simulator interaction acceptance.

## Red-to-green evidence

All logs below are retained in the external evidence directory. Initial suite compilation failed because the new MatchSession target had no source; cancelled tests separately failed for the missing enum member. First runnable host had two business-test staleGeneration errors while background capture advanced generation; those tests now wait for their independent business setup, with a dedicated controlled stale-request race retaining the required CAS failure.

| Regression | Observed red | Final behavior |
|---|---|---|
| Previously persisted intent bypassed newly discovered second candidate | `specific-red` | final command lookup precedes state guard; new/old uncommitted intents both enforce global admission |
| Confirmed failed finish left original live token permanently unhandled | `finish-recovery-red` | terminal recovery can retry finish once per token per driver run; uncertain effects reconcile existing operation |
| Recovery failure committed without its replacement intent | `atomic-red` | observation, genuine gap and new pending start share one SQLite transaction |
| New control COMMIT during stale empty driver scan lost wakeup | `wakeup-red` | scheduled work is consumed before driver retirement |
| End COMMIT during failed driver's suspended final projection lost wakeup | `error-wakeup-red` | error retirement hands newly scheduled work to another driver |
| Mixed-case/Unicode namespace could alias production storage | `namespace-red` | path factory and async environment boundary enforce canonical lowercase ASCII; production facts remain unchanged |
| Linked recovery failure retained UUID but omitted continuation | `linked-paused-red` | real old UUID, gap and new unique token commit together |
| Paused recovery started a new running Workout | `linked-paused-red` | pending start remains unperformed until real business resume COMMIT |
| Old pending pause/resume replayed after late initial start | `controls-red` | never-dispatched obsolete/redundant controls cancel; needsReconciliation never cancels |
| A queued old-token pause ran after recovery returned a saved UUID and replacement token | `token-proof-red` | saved/replaced-token pending controls cancel before gateway |
| A late UUID on an earlier-created operation was hidden by an old running sibling | `token-proof-red` | per-token linked proof is monotonic; cleanup performs no extra finish and phase is finished |

Final full entrypoint reran all host suites plus four explicit SDK targets and both unsigned Apps after these fixes. Earlier partial/aborted diagnostic runs are historical investigation evidence, not final passing results.

## Verified boundaries and downstream handoff

- `prepareStart` allocates only a request; confirmation executes an intent COMMIT before permit. commandID equals intentID; fixed `/intent`, `/start`, `/event/start`, `/capture/start`, `/outbox/start` IDs and original requestedAt survive restart. `SessionRequest.start(intent:starter:)` reconstructs the canonical request from the saved descriptor.
- Execute looks up immutable full StoreCommitV2 before current-state guards. Original requests retry after sequence/generation growth or terminal facts and return the first receipt plus current committed snapshot. Changed action/time/IDs/expected generation conflict. Stale generation produces no business facts or feedback; only a confirmed uncommitted stale request may be prepared again with a new command. Uncertain responses retain the original request.
- One MatchSession coordinator owns a database. Global start admission is registered before await; per-match business queue and command inFlight prevent actor reentry. Local endedPendingSync/incomplete with an unreleased backend lock remains a start blocker.
- Capture executes only after durable pending→needsReconciliation. Gateway await holds neither SQLite nor business queue; end facts can commit first. Reopen reconciles original operation/token. Unknown, savedAwaitingLink and unproven stopped saves remain unresolved; real UUID is required for a segment. Permission failure preserves the business match.
- Source does not import HealthKit or SwiftUI. WorkoutGateway is a pure protocol, UnavailableWorkoutGateway does not claim previously uncertain work never existed, and fake observations contain no health samples. Route failure remains visible after unrelated successful observations. Token lifecycle aggregates all persisted operations: linked save proof has priority, then savedAwaitingLink, then observedAt; operation creation order does not determine the physical state.
- SQLiteSessionRepository binds namespace to the actual database path. Production namespace is `production`; development uses a different canonical lowercase ASCII namespace. Persistent identity creates once only for an empty repository; missing/corrupt identity with old matches fails closed.
- Production StartPermitProvider remains unavailable in M4's absence. DevelopmentStartPermitProvider requires an isolated actual namespace; production rejects developmentSimulation. UI must not construct trusted permits. Session namespace validation occurs at each public asynchronous entry before effects because the injected repository namespace API is asynchronous; the concrete SQLite path factory validates synchronously.
- `updates` only yields committed snapshots. It is not another score/clock/current-match database. iOS/watchOS UI assembly and actual HealthKit integration remain NATIVE-009 / 008 / 010 work.

## Evidence location and limits

Persistent directory: `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-007/`.

- `source-inputs-dd89f9f.json`: source head, base, paths and SHA-256 inputs.
- `toolchain.txt`: actual Xcode/Swift versions.
- `dd89f9f-swift-test.log` and the `dd89f9f-` stage logs (also copied as `final-swift-test.log`, `final-store-{ios,watch}-build.log`, `final-session-{ios,watch}-build.log`, `final-{ios,watch}-build.log`): final passing entrypoint stages.
- `football-record-NATIVE007-*-red.log` and named intermediate logs: exact investigation evidence; `evidence-sha256.json` hashes retained files.

True-device acceptance: not applicable to this pure orchestration/protocol/SQLite task. No HealthKit authorization, GPS, background/lockscreen capture, real network lock, trusted transport, CloudKit complete-save, release promotion, upload or distribution is claimed. No merge, push, archive or branch deletion performed by author.

Tracked/untracked/ignored inventory after final verification contained only this author-owned validation draft as untracked; no ignored files required recovery or removal. Builds and SQLite test data live outside the worktree under task-specific temporary paths.
