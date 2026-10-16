# NATIVE-014 Durable Sync Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this approved plan task-by-task. Root owns the two independent reviews and merge.

**Goal:** Persist immutable complete device snapshots and exact durable receipts without changing legacy facts or command retries.

**Architecture:** MatchStore remains the only synchronous SQL actor. Add schema3 ledgers beside existing tables; route freezes full facts in its transaction, receive append-merges complete ancestry, and ACK only confirms an explicit route. Separate raw input and accepted descriptor projection.

**Tech Stack:** Swift 6, Foundation/CryptoKit, SQLite3, XCTest; iOS17/watchOS10 minimum unchanged.

## Files and execution

- [x] Create `Sources/MatchStore/SyncModels.swift` for validated DTOs/canonical v2 bytes, `SyncValidation.swift` for peer/complete fact/descriptor checks, `SyncPersistence.swift` for route/inbox/ACK/progress and immutable integrity checks. Add schema3 and failures in `SQLite.swift`/`StoreModels.swift`; expose only necessary package-internal capture helpers and explicit Store sync environment. Session behavior remains unchanged.
- [x] Create `Tests/MatchStoreTests/SyncRoutingTests.swift` with `testRoutingKeepsOriginalCommandRetryValid` and `testRouteResponseLostReturnsOriginalPacket`; create `MigrationV3Tests.swift` with `testMigrationV3RollsBackAtEachFault`. Run `swift test --package-path native/Packages/MatchCore --scratch-path /tmp/football-record-NATIVE014-build/Core --filter 'SyncRoutingTests|MigrationV3Tests'` and save actual missing-API/schema red output before production changes.
- [x] Implement additive migration and route. Assert original business_outbox rows/command receipts remain byte-identical, original committedCommandV2 works after route and ACK, snapshot captures all events/revision ancestors, and sequence is independent from local generation. Assert missing event parent does not allocate sequence.
- [x] Create and run failing `SyncReceiveV2Tests` for R2/R1/R2 prefixes, forks, missing parent, cross-match/global IDs, invalid authority, canonical/hash and ACK loss/reopen. Implement append-only receive with first input bytes/projection/receipt/ACK stored atomically; fixed receipt survives unrelated local generations. Test every corruption boundary by deleting or changing real SQLite rows.
- [x] Add ACK/state and `SyncCompatibilityTests`: unmapped outbox remains pending; foreign/V1 ACK rejected; completion/release/network claims never grant authority; local completion remains trusted after older held input; original v1 fixtures remain unchanged. Add v2 fixtures, failure-before/after-commit and gap convergence tests.
- [x] Run all Core tests then `NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE014-build/Full bash scripts/native/verify.sh`; capture 6 SDK products and 2 Apps. Use exact `git diff --check`, fixture hashes and path scope before logical source commits. Save full Git input and validation manifests/SHA256 outside the tree, then record actual results in task/validation docs and commit docs. Stop writing for root review.

## Fixed v1 evidence

At base `58ccd9d55fa693d333d6df95ff68442dd7ce2a3b`: packet.json SHA256 `bf7752440cca7de2cba988efa9535e971ed61249c17f444e90cbdf837c450695`, command.json `cfb028af3ce29f861c9753f66cfc51f62596a1a3bf90bfa09b5ed425dbb4f784`, legacy-v1.sqlite `1fb3b1a5b82ab64facf88ed4cd92221e5bad5b1de0fdcad62f11acb01db56573`. Full fixture manifest is saved with validation evidence.

## Actual result

Source commit `91e9ee84a5524e9c9e3272bcd53d7c70d85ee658`; full verification passed 197 host XCTests, six minimum SDK products and two unsigned simulator Apps. Final evidence and limits are recorded in [NATIVE-014 validation](../../native/validation/NATIVE-014.md). No author merge, push or archive.
