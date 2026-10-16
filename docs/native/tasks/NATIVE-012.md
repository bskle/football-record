# NATIVE-012 — Recovery read-only state

Status: registered; plan committed before source implementation; automatic verification and two non-author reviews pending.

- Author `/root/m2_recovery_state`; non-author reviewers `/root` and root-designated specification reviewer; merger `/root` only.
- Original base / target `dev` full SHA `7ae65db8f662c4afcdd053f63da6462bbed57262` (product baseline `2e1f9c42f4398a50b66765a0f37f90ced95a7554`; intervening docs only).
- Branch `fix/recovery-read-only-state`; attachment `01a142f0-f5a5-72f0-bd7a-cdfd8937cadc`, createdAt `1792124450`.
- Worktree `/Users/liam/.codex/worktrees/recovery-read-only-state/20260830_足球记录`; initial actual HEAD equals base, clean checked before write.
- Ownership: only `native/Modules/MatchPresentation/**` recovery readOnly / issue logic and necessary regression tests, [plan](../../superpowers/plans/2026-10-16-recovery-read-only-state.md), this card and NATIVE-012 validation. No Core / WorkoutCapture / Apps / Xcode / scripts / shared engineering configuration changes. Other authors use independent trees; no edits overwritten or reverted.
- Scope: unlock only after complete successful `load()` validation; retain fail-closed recovery errors, original uncertain request, valid unpermitted-intent issue and terminal held state. No public API change.
- Planned validation: controlled read/recover faults over real temporary SQLite; Presentation host suite, all Core / Store / Session host tests, six minimum SDK builds and two unsigned App builds using `NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE012 scripts/native/verify.sh`.
- Device not applicable: pure presentation state correction without new HealthKit, GPS, background, signing or peer capability. Those device gates remain with NATIVE-008 / 010.
- Persistent evidence `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-012/`.
- Source / final docs commits, red-green results, source hashes and independent reviews will be recorded after actual execution; author must not advance long-term branches, push, merge, archive or delete worktrees.
