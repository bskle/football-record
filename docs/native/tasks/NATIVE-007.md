# NATIVE-007 — Shared MatchSession

Status: source implementation delivered and full verification passed; both independent source reviews PASS; final document review and root integration pending.

- Author `/root/m2_match_session`; reviewers `/root`, `/root/m2_review`; integration by `/root` only.
- Base ref/target `dev`, base and initial target `7680ef6c45eab75105b244dd08f98f785adaa918`; dependency NATIVE-006 actually merged/verified.
- Branch `feat/match-session`; managed attachment `01a14265-7568-74a1-897d-59cd3f3ce2b0`, createdAt `1792115307`.
- Tree `/Users/liam/.codex/worktrees/match-session/20260830_足球记录`; HEAD checked equal base, clean before write.
- Sole ownership: `native/Packages/MatchCore/**`, `scripts/native/verify.sh`, [child plan](../../superpowers/plans/2026-10-16-match-session.md), this card and NATIVE-007 validation. Contract edits only after root approval. All other paths read-only.
- Acceptance: stable durable requests/lookup, global start admission and per-match serialization, committed-only feedback, isolated permit/identity, capture ledger reconciliation/end races and unique local recovery.
- Verification executed: real temporary SQLite host tests, explicit iOS17/watch10 MatchSession and MatchStore builds, both unsigned Apps, task-isolated `/tmp/football-record-NATIVE007`.
- Device not applicable: pure local orchestration and protocol/fake; no HealthKit implementation/capability change, no real lock or E2E claim.
- Evidence directory `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-007/`.
- Commits: plan `467a32c`; strict cancellation `4da4243`; service `5e46661`; error-wakeup fix `e372c85`; namespace isolation `a42147d`; recovery/paused controls `098baab`; final source `dd89f9f6592b6556d02dd7bea520f9ab7195184c`. Final documentation is committed separately after source.
- Actual final result: verify.sh exit 0, 131 host tests (44 Core + 55 Store + 32 Session), four explicit SDK target builds and both unsigned Apps passed. [Validation record](../validation/NATIVE-007.md) binds exact source and logs; no device acceptance claimed.
- Review: `/root` quality PASS and `/root/m2_review` specification PASS for exact final source `dd89f9f6592b6556d02dd7bea520f9ab7195184c`; final document review remains pending. Initial review P1/P2 findings were reproduced with actual SQLite/gated dependencies, then fixed in new commits. Author self-check does not substitute for dual review.
- Latest verification logs `/tmp/football-record-NATIVE007/logs/20261016T022957Z`; source hashes and complete evidence copied outside the worktree. No ignored source-tree artifacts found.
- Merge/archive/branch cleanup: not performed by author; root retains governance. No push.
