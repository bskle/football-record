# Capture Store v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this approved child plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist non-health capture revisions and execution journals atomically with business facts and unrouted outbox, preserving every v1 canonical byte and retry.

**Architecture:** Keep v1 request/packet types unchanged. Add validated Core values and independent v2 Store values; migrate by adding tables within SQLite transactions. MatchStore remains the single synchronous SQL owner, with focused v2 persistence helpers in an extension. Completion proof filtering applies to both snapshot APIs.

**Tech Stack:** Swift 6, Foundation, CryptoKit, SQLite3, XCTest; iOS 17 / watchOS 10.

## Ownership and baseline

Author `/root/m2_capture_journal`; reviewers `/root/m2_review` and `/root`; integration by `/root` only. Base and target dev at creation: `391228dc556afc716dfc3100d6beb78b2ba6c0e0`. Branch `feat/capture-store-v2`; managed attachment `01a14241-49de-72b3-9f43-a68bd28d8da6`, createdAt `1792112937`; worktree `/Users/liam/.codex/worktrees/capture-store-v2/20260830_足球记录`; actual HEAD verified equal to base and clean before writing.

Allowed: `native/Packages/MatchCore/**`, necessary `scripts/native/verify.sh`, this plan, NATIVE-006 task and validation records. No Apps, Xcode, capabilities, HealthKit, transport, peers or shared contracts. See [frozen M2 contract](../../native/contracts/m2-session-capture.md), sections 1, 2, 4.

## Task 1: establish immutable v1 fixture and red tests

Files: `Tests/MatchStoreTests/{MigrationV2,CaptureTransaction,LegacyCompatibility}Tests.swift`, `Tests/MatchCoreTests/CaptureRevisionTests.swift`, optional test fixture resource directory registered in Package.swift.

- [ ] Capture a real v1 database plus canonical StoreCommit/MatchPacket bytes from base code into test resources; compare database blobs and hash/checksum columns before/after migration.
- [ ] Add a migration assertion `XCTAssertEqual(PRAGMA user_version, 2)` and run it against v1 implementation to record the expected red result.
- [ ] Add compile-ready contract tests in small cycles for constructor/decoder validation, revision chains, business coverage, operation transitions and proofs before their implementation.
- [ ] Record actual red command, failure and log outside the worktree.

## Task 2: validated values and atomic migration

Files: new `Sources/MatchCore/CaptureRevision.swift`, new `Sources/MatchStore/CaptureStoreModels.swift`; modify StoreModels.swift and SQLite.swift.

- [ ] Implement exact contract fields with public validated initializers and decoding; no new fields in legacy Codable types.
- [ ] Validate complete v1 schema before an additive v1→v2 transaction; v0 initializes then migrates. Add capture revisions, global identities, operations/state history, business outbox, v2 commands and proof tables.
- [ ] Extend migration failure injection at both schema/version boundaries, retaining rollback and unsupported/corrupt/partial schema behavior.
- [ ] Run migration and constructor tests, including frozen v1 fixture round trips.

## Task 3: v2 transaction and integrity journal

Files: modify MatchStore.swift; new `Sources/MatchStore/CapturePersistence.swift`; CaptureTransactionTests.swift.

- [ ] `commitV2`: lookup and validate original receipt before CAS; then atomically save descriptor/events, revision chain, immutable operation requests and validated updates, unrouted deltas, receipt. Add failure points after revisions/operations/receipt.
- [ ] Register revision/segment/gap/operation/outbox IDs in one immutable namespace. Duplicate identical canonical data is idempotent; conflicts, missing parent, fork or corruption preserve original row and quarantine submitted/raw bytes.
- [ ] Require every submitted event and revision to be covered by exact same-transaction business deltas with matching descriptor/source/binding. Never encode executable operations into deltas.
- [ ] Persist operation state history: pending→needsReconciliation; needsReconciliation→needsReconciliation/settled/failed; terminal records immutable. Validate observation binding/token and outcome/state correspondence. On command retry verify initial requests, all history transitions and receipt-referenced outbox/revisions/facts.
- [ ] Add `snapshotV2`, pending operations and pending business outbox with byte/digest/identity checks. Reopen from matchIDs only.
- [ ] Run faults, lost response, stale generation, collision, missing parent, branch, state CAS and tampering tests.

## Task 4: complete-save proof filtering and regressions

Files: CapturePersistence.swift, MatchStore.swift, LegacyCompatibilityTests.swift, CaptureTransactionTests.swift.

- [ ] Calculate a public canonical digest using an explicit v2 domain and sorted complete capture revision set.
- [ ] Save v2 proof only after generation, diagnostics, current event evidence and full capture digest checks. Neither commit nor ACK manufactures a proof.
- [ ] Filter stale proof in both snapshot APIs; reject legacy evidence save when any revision exists; preserve legacy evidence for matches without revisions.
- [ ] Test empty digest, revision addition invalidation, legacy bypass rejection, stale CAS/digest/event proof, and unchanged old command retry/packet checksum/ACK.

## Task 5: verify, persist evidence, hand off

- [ ] Run `NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE006 scripts/native/verify.sh`: all host tests, explicit iOS17/watch10 MatchStore SDK builds, both unsigned Apps.
- [ ] Copy logs and SHA256 input manifest to `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-006/`.
- [ ] Update task/validation records with actual counts, commands, source hash, red/green evidence and limits; inspect exact staged paths and diff.
- [ ] Commit logical implementation and compatibility work using Conventional Commits without scope. Stop writing at final head for two independent reviews; do not merge, push or archive.

Device validation is not applicable to this pure transaction layer. SDK builds are compile evidence only; real capture, transport, production locks and full-save adapters remain outside this task. Contract deviations require root review before implementation.
