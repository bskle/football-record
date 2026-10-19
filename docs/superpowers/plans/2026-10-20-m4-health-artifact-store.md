# M4 retained Health artifact store implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline. Root prohibits auxiliary agents for this task; each slice is TDD and a coherent commit.

**Goal:** Retain the original039 raw reservation and derived prepared mapping through local erasure and restart, without manufacturing the026 full seal.

**Architecture:** An internal actor implements the five039 mapping functions. Four synchronous SQLite operations run under an exclusive original-owner lifetime lease; readFullSeal delegates an injected read-only provider outside file/SQL locks. Original parent UTF-8 is a BLOB key, canonical bytes and SHA256 are immutable. No other business database or Session is opened.

**Tech Stack:** Swift6, Foundation/Darwin, SQLite3, existing039 typed artifacts; iOS17/watchOS10/macOS14.

## Ownership and input

Only new `native/Apps/iOS/Integration/Sources/AppIntegration/M4RetainedHealthArtifactStore.swift`, matching `Tests/AppIntegrationTests/M4RetainedHealthArtifactStoreTests.swift`, this plan, and NATIVE-041 task/validation cards. No Package/project/039/040/catalog/Core/SDK edits. Original base `2cab4640ee3a375da39fdabf0f5a317600b0c263`; accepted039final `7547c048b8f8f640e920d17ffc1e09b6c4f335a3` ordinary merge gives `dadb60ee7fc366c5b7d8c754855b126384093e7a`. Root created `/Users/liam/.codex/worktrees/m4-health-artifact-store/20260830_足球记录`, branch `feat/m4-health-artifact-store`, attachment `01a15653-597c-7211-92d9-23196ca76f55`, created1792449665. Initial HEAD/branch/clean verified before writing. Held026 target at registration `27e83a50dcb0c08f7c5b3688e6fb86d5c9045b60`; child never merges/pushes/archives.

## Fixed contract and budgets

- `M4HealthArtifactOwner(installationID:namespace:scope:)` preserves original installation, namespace and all raw scope fields. It is checked against canonical owner and SQLite metadata on every operation; epoch never resets an old store. No generated replacement owner when original owner/DB is absent.
- `M4RetainedHealthArtifactStore(directory:owner:removableRoots:limits:fullSealProvider:boundaryHook:)` owns one retained directory outside every removable business/transport root. Compare original dev/inode against both ancestor chains, including case aliases. Reject symlink chains and unknown files; keep root, owner, DB and parents. Lifetime nonblocking flock on original owner prevents a second handle/process.
- Raw/prepared each <=16MiB, combined parent <=32MiB, <=64 parents, <=128 artifact rows and <=256MiB aggregate canonical payload. Owner <=64KiB. Test limits may only tighten. `BEGIN IMMEDIATE` checks existing rows, SHA/canonical/owner/derived mapping and all counts/sums before any INSERT; duplicates are idempotent and do not consume quota twice. No truncation/replacement.
- Complete private candidate directory contains original DB schema1 and owner with immutable DB/root/parent inode anchors; fsync files/candidate then atomic RENAME_EXCL and fsync parent. A leftover unpublished candidate is preserved and blocks reinitialization. Existing root with missing owner/DB, unknown inventory, incompatible schema/header/meta or invalid rows fails closed unchanged. No schema migration is needed for a new schema1; future schema is preserved.
- Validated reopen and every operation verify owner/root/ancestors, stabilize retained and parent directories, then revalidate before returning or mutating. This explicitly closes the026 S3 observation-before-dir-fsync ordering gap. WAL/SHM are SQLite-managed sidecars, not immutable owner identities; classify regular single-link files, reject unsupported journal/unknown/symlink. Never unlink them manually. Validation uses read-only SQLite before writable open; the immutable owner does not contain mutable DB contents.
- `reserve/readReservation/putPrepared/readPrepared` validate complete canonical bytes. Prepared is recomputed from the stored original raw + actual parentDigest; missing raw or different first bytes rejects. `readFullSeal` only calls the026 provider, default throws mappingUnavailable. It does not create, cache or bless a seal. Provider await holds no SQL/file mutation lock; close generation is rechecked on return.

## Slice1: immutable real SQLite artifacts

- [ ] Write tests using real typed capture facts and two raw-Unicode parent keys; absent API compile-red then minimum unavailable scaffolding produces executable red.
- [ ] Implement owner, bounded immutable BLOB rows, raw/prepared binding, duplicate/conflict, close/reopen, default seal-unavailable.
- [ ] Run `swift test --package-path native/Apps/iOS/Integration --scratch-path /private/tmp/football-NATIVE041-host --filter M4RetainedHealthArtifactStoreTests`, retain red/green logs outside tree. Commit explicit five paths with actual validation and limitations.

## Slice2: preservation and crash/transaction bounds

- [ ] Add runtime-red fault/reopen, tighter-budget exact boundaries, missing/replaced owner/DB, future/bad schema/row, sidecar/unknown file, exclusive second handle and real inode/casealias overlap tests.
- [ ] Implement complete-candidate EXCL initialization, bounded owner preflight, validated reopen barriers, strict known inventory and owner lease. beforeCommit rollback keeps rows; afterCommitLost reopens original first bytes. No automatic recovery of unknown artifacts.
- [ ] Run focused tests and retain exact subprocess _exit and red/green evidence; commit coherent storage hardening.

## Slice3: bridge integration and final verification

- [ ] Add provider async/close admission and real039+028 SQLite restart tests: original request/confirmation survives reopen, unknown outcome never auto-dispatches, absent seal blocks execution.
- [ ] Run full AppIntegration host once, fresh minimum target AppIntegration builds for arm64-apple-ios17.0-simulator, arm64-apple-ios17.0, arm64-apple-watchos10.0-simulator, arm64-apple-watchos10.0 with each xcrun SDK path. Freeze input hashes before/after; no account/HealthStore/WC action.
- [ ] Freeze source with exact manifests, obtain root+m2 source review; only then finish two cards and final manifest. Retain every historical raw log; held026 only. Product software tests do not prove physical power-loss durability, real Health sources/authorization, full catalog seal or all-owned deletion.
