# M4 Presentation checked boundaries implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Let026 assemble the existing facade/Session and update account/scope query projections through checked public boundaries.

**Architecture:** Keep AccountAppContext.init internal. Public factory validates the original facade and MatchSession; identity admission reads exact durable binding/generation and rejects stale local continuations. Lifecycle scope projection accepts only current binding or an exact persisted deletion originalScope, never authentication authority. Existing production unavailable and025 Debug behavior remain.

**Tech Stack:** Swift6.4, Foundation/Observation, SQLiteSessionRepository, MatchSession, AccountKit, CloudSync; iOS17/watchOS10 minimums unchanged.

## Registration and scope

Original base/target `e3e4b09d79c1f2556b8648c214f6c3c148ca8cd1`, branch `feat/m4-presentation-boundaries`, tree `/Users/liam/.codex/worktrees/m4-presentation-boundaries/20260830_足球记录`, attachment `01a1560b-0e05-7df1-b0fb-fa92514b2d46`, createdAt1792444927. Author checked clean initial HEAD/branch before writing. Blueprint already dual reviewed; root authorized nine exact paths and inline execution without further product decisions.

Only three MatchPresentation source files and their three existing test files plus this plan and038 task/validation cards may change. No Core/AccountKit/CloudSync/Apps/config/SDK implementation. Root+m2 review exact source/final; author never merge/push/archive/advance dev.

## Task 1: same facade/Session composition

Files: AppBootstrap.swift and BootstrapTests.swift under MatchPresentation existing source/test directories.

- [x] Add tests calling `try await AppBootstrap.accountContext(repository:session:recording:account:lifecycle:close:)`. Same objects must remain identical; alternate repository, alternate Session with same facade, and wrong account/lifecycle facade must reject with `AuthorityError.identityChanged`.
- [x] Run `xcrun swift test --package-path native/Modules/MatchPresentation --filter BootstrapTests`, preserving missing-API red separately from runtime assertions.
- [x] Add async throwing overload only; compare session/model repository sync identity, original RecordingModel.session as MatchSession identity, and both status repository actors. Do not create resources or call supplied close on rejected composition. Internal Context initializer remains unchanged.
- [x] Run focused tests and commit exact paths with actual validation/limitations.

## Task 2: checked identity projection

Files: AccountStatusModel.swift and AccountStatusTests.swift.

- [x] Test real persisted binding/generation admission; reject raw byte mismatches, role/environment/epoch changes, suspended or missing binding, stale generation, stop/pause/refresh/newer admission while awaiting. Keep requiresReload monotonic across re-admission, including stopped RecordingModel behavior.
- [x] Record API red and meaningful runtime red using the existing unchecked confirmation behavior before replacing it. Preserve actual logs and test counts.
- [x] Add `public func admitIdentity(_ binding: AccountBindingV4, expectedIdentityGeneration: Int64) async throws`. Fixed public read uses repository generation before/after durable binding; internal read overload permits controlled delay of the real SQLite result for deterministic continuation tests. Compare each identity string as Data(utf8), all scalar fields exactly; reject with identityChanged. Before returning from await recheck local generation/stopped. Public initializer has no verified bool; existing Debug bool initializer and confirmIdentity stay internal. `requireReload()` is public but only sets the monotonic block.
- [x] Run focused tests, then commit. This API checks presentation evidence against durable truth;026 still performs actual AccountService/WatchRegistrationService admission first.

## Task 3: checked lifecycle scope projection

Files: LifecycleStatusModel.swift and LifecycleStatusTests.swift.

- [ ] Test current binding scope, exact retained deletion scope after suspend, wrong raw account/space/epoch/zone, stale identity generation and old delayed result versus new scope/stop. Verify cloud proof clears and account admission stays closed.
- [ ] Run focused tests to establish red. Add `public func projectCloudScope(_ scope: CloudScope, expectedIdentityGeneration: Int64) async throws` plus internal delayed-read overload shared with public checks. Read current binding/deletion sagas between identity generation checks. Current binding contains account/space/epoch (no zone); retained saga requires exact originalScope including zone. No new authentication or permission result is created.
- [ ] Only the current local token can install scope. Clear old cloudSaved/backendStatus/cloudIssue proof; invalidate old read generation so prior refresh/action cannot overwrite current scope. Keep raw internal025 setCloudScope compatible.
- [ ] Run focused and complete MatchPresentation tests, commit source checkpoint, then fresh minimum iOS17/watch10 simulator product builds. All supported package/dependency source inputs get before/after hashes; no App/scheme/device execution.

## Final verification and handoff

- [ ] Preserve original02563 tests in the full single host run; report actual count, not forecast.
- [ ] Save six Git inputs, tool versions, exact source files/input hashes, original red/green/final logs and evidence manifest under external NATIVE-038. Source checkpoint freezes before root+m2 review.
- [ ] Only038 task and validation cards change in final docs commit; prove all compiled/test input hashes unchanged and final clean. This is pure query/composition validation; hardware not applicable, no real account or SDK execution.026 integration remains separate.
