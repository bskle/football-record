# NATIVE-011 — Proven absent capture cleanup

Author `/root/m2_match_session`; sole writer in `/Users/liam/.codex/worktrees/absent-capture-cleanup/20260830_足球记录`, branch `fix/absent-capture-cleanup`. Base/target dev `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`; managed attachment `01a142b4-6565-7023-946c-3ce846ce8bfc`, createdAt `1792120481`. Actual pre-write branch/HEAD and clean inventory verified. NATIVE-007 is already integrated; its archived tree is not reused.

- [ ] Real SQLite red tests for the finish needsReconciliation cleanup exception and gated authorization still pending after outer start timeout.
- [ ] Add persistent absence proof: canonical original start/history, same binding/token, failed.notCreated, no positive observation anywhere in token history, no actual window, no recover request and no contradictory segment/revision evidence.
- [ ] Permit needsReconciliation→cancelled(nil) only for finish with that proof; recheck through mutation, read/snapshot/pending and complete request receipt/lookup paths. Quarantine contradictory incoming raw bytes; ordinary transitions remain unchanged.
- [ ] Session re-evaluates needsReconciliation finish after the original start negative observation commits; reports notRecorded and unchanged endedPendingSync/held lock. Unknown after reopen is never enough. Late positive observations are not silently dropped.
- [ ] Fault/reopen/receipt, arrival ordering, positive-history/actual-window/segment/binding/token/action counterexamples; full host and existing verify.sh four SDK/two unsigned App builds.
- [ ] Deliver immutable source for root + `/root/m2_review`; fix findings in new commits, then submit exact source/log/hash validation records. Root alone integrates, pushes and archives.

Ownership: `native/Packages/MatchCore/**`, approved narrow `docs/native/contracts/m2-session-capture.md`, this plan, NATIVE-011 task and validation. Apps/scripts/Xcode/other modules, 008 and 009 read-only. Pure Core/Store/Session change, no HealthKit/device implementation; gated fake is not device proof. Same-binding real segments cannot safely be attributed to another token because CaptureSegment has no token field, so this exception conservatively rejects them rather than guessing ID prefixes.
