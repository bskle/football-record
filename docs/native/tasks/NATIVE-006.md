# NATIVE-006 — Capture journal and unrouted outbox

Status: implementing; no integration or device claim.

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
- Commits/reviews/merge/archive: pending; author will not merge/push/archive.
