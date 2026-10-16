# NATIVE-006 — Capture journal and unrouted outbox

Status: author delivery complete; source dual review PASS; final evidence/document review and integration pending.

- Author: `/root/m2_capture_journal`; non-author reviewers: `/root/m2_review`, `/root`; merger `/root`.
- Base ref / target: `dev`; base SHA and target SHA at creation: `391228dc556afc716dfc3100d6beb78b2ba6c0e0`.
- Branch: `feat/capture-store-v2`.
- Managed attachment: `01a14241-49de-72b3-9f43-a68bd28d8da6`; createdAt `1792112937`.
- Worktree: `/Users/liam/.codex/worktrees/capture-store-v2/20260830_足球记录`; pre-write HEAD equals base, clean.
- Ownership: `native/Packages/MatchCore/**`, necessary `scripts/native/verify.sh`, this task, [child plan](../../superpowers/plans/2026-10-16-capture-store-v2.md), [validation](../validation/NATIVE-006.md). Approved addition: narrow lookup/failure revision of `docs/native/contracts/m2-session-capture.md`, dual-reviewed by root and m2_review. Others read-only; no shared worktree writes.
- Dependency: NATIVE-005 dual-reviewed and integrated as base above. Contract: [M2](../contracts/m2-session-capture.md) §1/2/4.
- Acceptance: additive atomic v2 migration; unchanged v1 bytes/retries/ACK; immutable global capture IDs and chain; durable operation state journal; atomic business coverage and unrouted outbox; capture-aware proof invalidation through both old/new snapshots; fault and reopen tests.
- Verification: actual host XCTest + explicit iOS17/watch10 MatchStore compile + two unsigned Apps via task-isolated `/tmp/football-record-NATIVE006`.
- Device: not applicable, only pure model/SQLite code; no HealthKit/capability/transport/UI changes.
- Persistent evidence: `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-006/`.
- Commits: plan `5060ed6`; initial source `fd316991370db6c305663d87e4059adb60c01b7b`; reviewed fixes `11f6cfacdec4bb311efc3f719610275e4455dcb6`; final source `a69cefd788c47fac9c0ad742d5fb1565c0b22899`. Final documentation commit follows these immutable source heads.
- Reviews: final source `a69cefd788c47fac9c0ad742d5fb1565c0b22899` received non-author PASS from `/root` (quality) and `/root/m2_review` (specification); initial P1 findings and symmetric diagnostic paths were reproduced and fixed in new commits. Final docs/evidence review remains with root.
- Actual verification: final verify.sh exit 0, 96 tests (52 Store + 44 Core), explicit iOS17/watch10 MatchStore SDK builds and both unsigned Apps passed. Detailed red/green facts and input hashes in validation record.
- Approved correctness clarifications: linked requires real segment; action-aware settled states; saved/uncertain save facts monotonic; immutable legacy/v2 confirmation history; registry-backed reverse recovery scans. No extra product scope.
- Source fixture hash: `1fb3b1a5b82ab64facf88ed4cd92221e5bad5b1de0fdcad62f11acb01db56573`; known empty-WAL inspection sidecars preserved externally and removed exactly from source resources.
- Merge/archive/branch cleanup: not performed by author; worktree and branch remain for root governance. No push.
