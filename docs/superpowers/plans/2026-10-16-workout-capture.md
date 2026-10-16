# NATIVE-008 WorkoutCapture execution plan

Base: `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`. Author `/root/m2_workout_capture`; branch `feat/workout-capture`; target dev only after NATIVE-010 device gate. Ownership is `native/Modules/WorkoutCapture/**` and this task’s three documents. No Apps, shared project or core changes.

## Implementation sequence

- [x] Add reusable SwiftPM product depending on existing MatchCore/MatchSession; host protocol tests first, record red then green.
- [x] Implement bounded one-shot callbacks, in-memory metrics, privacy-preserving authorization states, route failure/paused filtering and original-token gateway reconciliation.
- [x] Implement watchOS10 local soccer/outdoor live session and associated builder; iOS17 manual builder plus Core Location, sharing safe query/metadata/route code. SDK branches explicitly built.
- [x] Test saved nil/nil, timeouts/duplicate callbacks, monotonically saved proof, wrong bindings/source, query unknown, paused samples, route fatal and recovery/terminal races.
- [x] Run local host suite and explicit iOS17/watch10 simulator SDK builds; retain exact source hashes/logs. Earlier unchanged core regression and device SDK evidence are versioned separately.
- [ ] After NATIVE-011 actual merged-tree verification, receive root ordinary merge of the verified dependency; test real AppleWorkoutGateway + SQLite terminal cancellation while authorization remains pending until cancellation, then rerun final host and simulator/device SDK checks.
- [ ] Obtain final source/document reviews from root and `/root/m2_review`; freeze final inputs/evidence.
- [ ] Record compiled/pending-device handoff; retain temporary branch. No merge, push, archive or capability changes by author.

## Permission and failure matrix

| Observation | Meaning / action |
|---|---|
| requestAuthorization success | Request flow completed; not evidence of read access |
| workout write denied | Fresh start notCreated(writeDenied); existing match preserved |
| empty read / locked / query error | unknown, no new workout, never infer readDenied |
| location denied / unsupported sensor | Missing optional live metric; workout may continue with failure annotation |
| invalid accuracy/speed | Unknown; real zero remains available |
| finish nil,nil | savedAwaitingLink; lookup original token/binding/source; no repeated finish |
| route insert failed | Permanently stop that route writer; preserve actual workout outcome |
| timeout / duplicate callback | Bounded return unknown; late callback retained, first callback only |
| recovered original watch session | Reattach original associated builder; no start/beginCollection |
| iOS manual builder lost after restart | No recover API; query original token. Unknown remains unresolved; proven saved UUID may close old segment with recoveryUnavailable |
| system crash / user force quit / reboot | Separate physical acceptance cases; latter two never guaranteed recovery |
| late start after finish request | Stop and save same token; no successor or fake backfill |

## Validation commands and evidence

Run package-local `Scripts/verify.sh` with `WORKOUT_BUILD_ROOT=/tmp/football-record-NATIVE008`; it invokes host XCTest plus explicit arm64 iOS17/watchOS10 simulator SDK builds. Capture immutable source hashes and logs under external `native-validation/NATIVE-008`. Host fake tests prove coordination only. No simulator or stub establishes HealthKit permissions, GPS/background, lockscreen save or genuine recovery. NATIVE-010 owns signed App wiring and these real-device cases.

Compiled source checkpoint: `670609200dcadc91c61a88f734c0701b01f05896`, 35 module XCTest and explicit iOS17/watch10 simulator SDK builds passed. NATIVE-011 merge `f26d60de81fb5afa90e2f16044a09675d71ee834` is reported by root but its actual merged-tree verification is still running; this task has not synchronized it or completed the terminal cross-layer closure. Earlier sourcefcb4020 has device SDK compilation evidence; unchanged base core regression has 131 tests, neither substitutes for the required post-sync verification. Independent final review and real-device acceptance remain pending. The 6706092 body’s six red assertions is corrected to four per the preserved log; history remains unchanged.
