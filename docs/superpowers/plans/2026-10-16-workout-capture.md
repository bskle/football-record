# NATIVE-008 WorkoutCapture execution plan

Base: `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`. Author `/root/m2_workout_capture`; branch `feat/workout-capture`; target dev only after NATIVE-010 device gate. Ownership is `native/Modules/WorkoutCapture/**` and this task’s three documents. No Apps, shared project or core changes.

## Implementation sequence

- [x] Add reusable SwiftPM product depending on existing MatchCore/MatchSession; host protocol tests first, record red then green.
- [x] Implement bounded one-shot callbacks, in-memory metrics, privacy-preserving authorization states, route failure/paused filtering and original-token gateway reconciliation.
- [x] Implement watchOS10 local soccer/outdoor live session and associated builder; iOS17 manual builder plus Core Location, sharing safe query/metadata/route code. SDK branches explicitly built.
- [x] Test saved nil/nil, timeouts/duplicate callbacks, monotonically saved proof, wrong bindings/source, query unknown, paused samples, route fatal and recovery/terminal races.
- [x] Run local host suite and explicit iOS17/watch10 simulator SDK builds; retain exact source hashes/logs. Earlier unchanged core regression and device SDK evidence are versioned separately.
- [x] Receive root ordinary task merge85c2cd7 of verified NATIVE-011 f26d60d; test real AppleWorkoutGateway + SQLite terminal cancellation with authorization held until cancellation, and run final module40/core144 tests plus both simulator/device SDK checks.
- [x] Obtain source754b28b PASS from root quality and `/root/m2_review` specification reviews; freeze 69 input and 63 evidence hashes.
- [ ] Final document-head handoff review; physical acceptance remains NATIVE-010.
- [x] Record compiled/pending-device handoff; retain temporary branch. No merge, push, archive or capability changes by author.

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

Final automatic source candidate: `754b28b18f44261b0bcd7869b098380a50a8100b`. Original base `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`; verified dependency `f26d60de81fb5afa90e2f16044a09675d71ee834`, ordinary sync merge `85c2cd72e2810b82a354a0a63237712cd50a28fc`. Latest source passed 40 module tests, 144 core tests and explicit iOS17/watch10 simulator plus actual device SDK builds. The SQLite terminal closure observes cancelled finish before authorization is released, including fault/reopen cases; restarted gateways without evidence remain unknown. Source754b28b passed root quality and m2_review specification reviews. Final document-head handoff review and real-device acceptance remain pending. The 6706092 body’s six red assertions is corrected to four by the preserved log; history remains unchanged.
