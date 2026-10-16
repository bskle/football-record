# NATIVE-011 validation

Source candidate `d4b7b6a56566ba119d41b644acbcee12dbcf74e6`; base/target dev `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`. Author `/root/m2_match_session`; independent quality review by `/root` and specification review by `/root/m2_review` both PASS on this exact source. Final document review, root integration and managed archival remain pending.

## Executed verification

`NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE011 bash scripts/native/verify.sh` completed exit 0 against the source candidate. Actual stage logs: `/tmp/football-record-NATIVE011/logs/20261016T034349Z`.

| Check | Actual result |
|---|---|
| Host XCTest with real temporary SQLite | 144 passed, zero failures: Core 44, Store 64, Session 36 |
| MatchStore explicit iOS17 / watchOS10 simulator SDK | both passed |
| MatchSession explicit iOS17 / watchOS10 simulator SDK | both passed |
| FootballRecord-iOS / FootballRecord-Watch unsigned generic simulator builds | both BUILD SUCCEEDED |
| Whitespace and ownership | checked; no scripts, Apps, Xcode, other modules or other authors’ edits |

Toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4. Build outputs use task-specific `/tmp/football-record-NATIVE011`. Apps remain the existing preview shells in this base; these builds establish regression compatibility, not NATIVE-009 UI acceptance.

## Red-to-green evidence

| Controlled regression | Actual red | Final verified behavior |
|---|---|---|
| Start outer timeout while fresh authorization still pending; end/finish already uncertain; later original start proves notCreated | `initial-red` rejects cancellation and leaves needsReconciliation | Original negative COMMIT wakes cleanup; uncertain finish cancels with zero fake external creates; phase notRecorded, business endedPendingSync and held backend lock |
| Canonical original start/history proof, both negative-first and finish-first arrival orders | `initial-red` rejects the narrow transition | Complete canonical request/receipt/facts/history validation precedes the exception; all other action/state cases remain rejected |
| Historical actual window omitted by the current record; all read/retry paths | `boundaries-red` shows legacy pendingPackets and legacy receipt retry bypassing proof | v1/v2 snapshots, capture/business/legacy pending, v2 lookup/receipt retry, legacy retry and new write reject invalid proof with retained diagnostics |
| Late positive evidence before/after cancellation | `contradiction-red`, 17 failed assertions | Exact observation bytes retained as blocking diagnostics; all lifecycle positive outcomes and unknown with actual window prevent later cancellation or successful cancelled readback/receipt retry |
| Late finish.running with nil failure before/after cancellation | `raw-observation-red` fails exact gateway-bytes assertion | Verify original operation identity and bypass semantic normalization only for the contradiction quarantine branch; exact original bytes retained, absence cancellation remains blocked |
| Existing same-binding segment while finish remains uncertain | `segment-gate-red` throws invalidOperationTransition | Session keeps original finish in reconciliation and avoids issuing an unsupported cancel; Store independently rejects that exception |

Fault regressions use real SQLite before-COMMIT failure and after-COMMIT response loss, close/reopen and full identical-request retry. They preserve the truthful operation state and first receipt. Additional coverage checks no negative proof after restart, wrong binding/token, non-finish actions, recover requests, canonical command tampering, existing real segment, and Session forwarding late positive evidence after start was finalized. The first intermediate implementation run exposed two legacy error-code assertions; the final implementation preserves invalidOperationTransition for negative-after-positive while quarantining the raw bytes. Earlier logs are investigation evidence, not passing final verification.

## Proof and limits

The only new transition is finish needsReconciliation→cancelled(nil), with the same binding/token original start durably failed.notCreated. Store checks every token history record for running/paused/stopped/savedAwaitingLink/linked, actual start/end windows or routeFailed; rejects a recover request; checks all capture revisions for real segments/nonempty gap windows; and fully verifies the original start’s canonical commands and referenced facts. The proof is also checked on readback and receipt retry. A late contradictory physical observation is retained separately in a blocking diagnostic and remains known evidence; cancellation cannot erase or ignore it.

CaptureSegment does not carry a trustworthy token field. Any real segment under the binding conservatively blocks this exception, including a potentially unrelated older segment. A replacement token in that situation continues reconciliation; this task does not claim to close every recovery cleanup case. Session’s visible candidate filtering avoids unsupported cancellation attempts, while Store remains the atomic authority over full persisted history.

The service fake gates when the original start negative observation becomes available: original start unknown, finish already needsReconciliation, then original start explicitly notCreated with zero fake external creates. Its authorizationFinished field is controlled test state; it does not suspend an actual SDK authorization future or prove platform absence. The AppleGateway + SQLite chain with real adapter authorization still suspended until cancellation belongs to NATIVE-008 after it synchronizes this repair. NATIVE-008 separately owns the only permitted fresh in-instance negative proof: terminal already locked, makeDriver never called, no recovery or positive/actual-window evidence, and late authorization cannot create. Restart, a construction attempt, general reconcile or unknown side effects do not prove absence. No API expansion is required by NATIVE-009.

## Retained evidence

Directory: `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-011/`.

- `source-inputs.json`: exact source head, full base, branch/worktree, native inputs, script and shared contract paths with SHA-256 and Git blob IDs.
- `d4b7b6a-*.log`: final host, four explicit SDK and two App stage logs; `football-record-NATIVE011-verify-d4b7b6a.log` is the complete final entrypoint output. The earlier `7d54b43-*.log` and initial verify output retain the prior passing candidate, superseded by the exact-byte fix.
- `football-record-NATIVE011-*-red.log` and intermediate host logs: actual failing and subsequent passing investigation runs.
- `toolchain.txt`, `source-diff-stat.txt`, `source-status.txt`, `final-inventory-before-docs.txt`, `evidence-sha256.json`: toolchain, immutable scope/inventory and evidence hashes.

Pure Core/SQLite/orchestration change: true-device acceptance is not applicable here. No HealthKit authorization, GPS, lifecycle capture, trusted permit, real network lock, transport or release acceptance is claimed. Author has performed no merge, push, archive or branch deletion. Final source inputs are unchanged; the pre-document-commit inventory contains only the three author-owned final documentation files and no ignored recovery material. Logs/builds/temporary SQLite data live outside this managed worktree.
