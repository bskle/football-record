# NATIVE-008 — WorkoutCapture

- Author: `/root/m2_workout_capture`; reviewers `/root` and `/root/m2_review`.
- Base: `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`; integration target `dev` after NATIVE-010 device gate.
- Branch: `feat/workout-capture`; tree: `/Users/liam/.codex/worktrees/workout-capture/20260830_足球记录`.
- Attachment: `01a14293-82af-73c2-a9a6-0f98404f6eee`; createdAt `1792118325`; initial HEAD verified equal base, clean.
- Sole writable scope: `native/Modules/WorkoutCapture/**`, [child plan](../../superpowers/plans/2026-10-16-workout-capture.md), this card and [validation](../validation/NATIVE-008.md).
- Depends on completed and verified NATIVE-007. NATIVE-009 is an independent concurrent writer; no engineering files touched here.
- Compiled source checkpoint: `670609200dcadc91c61a88f734c0701b01f05896`; plan `f061aca`; adapter `28d6839`; callback/route/stop fixes `ffb6b30`; awaiting-link cache fix `fcb4020`; fresh-start proof `6fba458`, cached response retention `d021a2c`, actual session ordering `6706092`.
- State: source checkpoint compiled, waiting for NATIVE-011 verified synchronization and full terminal cross-layer validation. On source6706092, 35 module XCTest and explicit iOS17/watch10 simulator SDK builds passed. Unchanged base core regression previously passed 131 XCTest. Device SDK builds belong to earlier sourcefcb4020 and must be repeated after synchronization; no current-device acceptance is asserted.
- NATIVE-011 handoff: root reports merge `f26d60de81fb5afa90e2f16044a09675d71ee834`, with actual merged-tree verification still running at this checkpoint. It is not yet a verified dependency and has not been merged into this task. Root will perform the ordinary merge after verification, then dispatch full real-gateway/SQLite terminal cancellation tests with authorization held until cancellation, plus final automatic checks/reviews/evidence.
- Historical correction: the `6706092` commit body says six red assertions; the preserved negative-sequence red log actually reports four. This checkpoint corrects the count without rewriting history.
- Lifecycle: retain this branch for reviewed NATIVE-010 temporary integration. Root later verifies all targets and archives before safe `git branch -d`; author never moves permanent branches.
