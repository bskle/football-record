# NATIVE-007 — MatchSession executable plan

Approved scope: M2 plan §5 and [session contract](../../native/contracts/m2-session-capture.md) §3/4. Author `/root/m2_match_session`, sole writer in managed tree `/Users/liam/.codex/worktrees/match-session/20260830_足球记录`, branch `feat/match-session`. Base/target dev at start: `7680ef6c45eab75105b244dd08f98f785adaa918`; attachment `01a14265-7568-74a1-897d-59cd3f3ce2b0`, createdAt `1792115307`. Pre-write HEAD matches base and clean.

- [x] Add real MatchSession target/product and real temporary SQLite test harness; run missing-feature red tests for durable start/ordinary retry.
- [x] Implement validated Sendable session values, repository adapter, persistent identity, production unavailable permit, isolated development fixture and pure gateway protocol.
- [x] Implement canonical durable start, lookup-before-guard, global start admission, per-match transaction queue/inFlight, staged business commands and committed streams.
- [x] Red/green capture and recovery races: durable pending→needsReconciliation→gateway→observation/revision, uncertain DB results, end priority, original token reconciliation, unique recovery and retained warnings.
- [x] Extend verify.sh with both MatchSession SDK targets; run full host, iOS17/watch10 MatchStore+Session SDK and unsigned Apps. Copy logs and input hashes outside tree.
- [x] Deliver immutable source head for root and `/root/m2_review` dual review, resolve findings in new commits, then update final evidence docs. Root alone merges/pushes/archives.

Start canonical IDs: command equals intent ID; `/intent` and `/start` store commands; `/event/start`, `/capture/start`, `/outbox/start` facts. Original requestedAt is the business start time per frozen contract; permit latency is not silently substituted. Ordinary request payload remains unchanged on retry. Gateway waits never occupy business queue. Capture failures remain orthogonal to lifecycle.

Ownership: `native/Packages/MatchCore/**`, `scripts/native/verify.sh`, this plan, NATIVE-007 task/validation. Shared contract corrections require root review. Apps/Xcode/configuration and other modules/tasks read-only. No HealthKit/transport/real lock or device capability changes; device acceptance not applicable.

Execution: final source `dd89f9f6592b6556d02dd7bea520f9ab7195184c`; 131 host tests and all four SDK/two unsigned App builds passed. Root quality review and `/root/m2_review` specification review both PASS for this exact source; final document review remains pending. Concrete storage, wakeup, recovery and token-proof findings were reproduced red and fixed in new commits; details in NATIVE-007 validation. No merge/push/archive by author.
