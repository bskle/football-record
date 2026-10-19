# HealthKitDeletion

Independent local deletion control for explicitly selected App-created Workouts. SwiftPM supports iOS 17, watchOS 10 and macOS 14; its product target has no AccountKit, MatchCore, WorkoutCapture or external package dependency. The tests alone depend on the local reviewed MatchCore/MatchSession package to exercise actual start/recover/restart token generation; no unreviewed 023 interfaces are used.

## Execution gate and ownership

The default `HealthDeletionService` uses `UnavailableHealthDeletionDriver`. `HealthKitDeletionDriver` also defaults `executionEnabled` to false; constructing it has no HealthStore side effect. SDK execution is restricted to the separately accepted NATIVE-026 integration. This candidate does not wire an App, entitlement, permission prompt, query or real deletion. Host tests exclusively use controlled drivers and pure tuple data. Four SDK builds compile the actual HealthKit code without running it.

NATIVE-026 maps reviewed capture-registry identities into the selection and maps the per-scope receipt to `healthProgress`; NATIVE-025 supplies the runtime explicit Health confirmation UI. This module cannot advance account, CloudKit or ordinary local deletion. Candidate source, signing, permissions and actual target deletion require separate device acceptance. Phone and Watch source identities are not assumed equal.

## Frozen request and confirmation

A `WorkoutDeletionRequestV1` binds a stable UUID requestID, integer createdAt and 1...256 explicit targets. Each target binds a Workout UUID, matchID, recordingDeviceID, segmentToken and expectedSourceBundleID. Duplicate UUIDs, empty metadata, NUL bytes, metadata over 4096 UTF-8 bytes, invalid source bundle identifiers, out-of-range time and oversized scopes are rejected. The three metadata values are opaque existing local values: slashes, spaces and Unicode are retained without trimming, escaping, or normalization. They do not use the HTTP identifier grammar. Missing registry/metadata mapping must remain a failed selection; it must not widen to all Workouts.

Canonical bytes contain the full request with fixed sorted JSON keys and canonical UUID strings; targets are UUID-sorted, while metadata/source strings retain their exact values. SHA-256 is domain-separated by `football-record.health-workout-delete.v1\n`. Same ID with different canonical selection is an identity conflict. These local control fields are never uploaded and contain no health samples.

`WorkoutDeletionConfirmationV1` requires explicitHealthDeletion=true, its own confirmationID/time and the same requestID/selectionDigest. Confirmation is persisted independently and cannot be inferred from deleting an account or local/cloud data. `confirm(_:now:)` takes the integration's clock; future, pre-request or malformed confirmations are rejected. Repeating the same confirmation preserves its first result; another confirmation cannot replace it.

## Durable local state

Open `SQLiteHealthDeletionLedger(url:businessDataDirectory:)` with a dedicated control URL outside the ordinary business erase directory. Path/symlink checks reject a control file inside that directory. The module never erases the business directory. It holds a nonblocking exclusive owner lock until close, uses file SQLite with WAL/FULL synchronization and validates schema, canonical bytes, confirmation, receipt and phase/issue relationships before recovery writes. Corrupt, future or inconsistent stores fail closed without replacing/resetting the original database.

Submit the request, persist the explicit confirmation, then call `HealthDeletionService.resume`. Before issuing the callback driver, the ledger commits executing plus the exact digest/attemptID. No SDK await occurs inside a SQL transaction. A second resume or another service sharing that ledger cannot issue a second active attempt.

A wait timeout records awaitingOutcome; it does not cancel the SDK operation or allow a concurrent retry. A late callback still belongs to the same attempt. Callback request/digest/attempt must match, and first terminal results are immutable. Call close before opening another owner. After reopen, unresolved attempts become interrupted/outcomeUnknown; only the original request/confirmation/scope may retry with a new attemptID. Old owner callbacks are ignored. A callback success followed by a failed database COMMIT can be retried after reopening, but a later count of zero does not reconstruct how many objects an earlier unknown attempt deleted.

SDK success is recorded as succeededLocally with deletedObjectCount. Count zero means noMatchingObjectsInScope for that particular local operation. It does not prove global absence, read authorization, cross-device synchronization, or completion of the other three deletion choices. Negative/excess counts fail as invalidResponse. Finite permission/unavailability errors preserve a recoverable Health-only state. Neither raw NSError descriptions nor health objects enter the ledger.

## Actual SDK predicate

The SDK verifies every expectedSourceBundleID against `HKSource.default().bundleIdentifier` before creating the HealthStore. Its predicate is:

`current App source AND OR(each target UUID AND matchID AND recordingDeviceID AND segmentToken)`

The three fixed metadata keys are `app.football-record.match-id`, `app.football-record.recording-device-id` and `app.football-record.segment-token`, matching the reviewed NATIVE-008 metadata. Each UUID stays attached to its own three original values. The pure controlled tuple matcher compares their UTF-8 bytes, so Unicode canonical equivalence cannot broaden a selection. The adapter uses only `HKObjectType.workoutType()` and SDK predicate constructors; it accepts no caller predicate, arbitrary metadata dictionary, alternative object type or broad fallback. An empty or source-mismatched selection cannot become a successful no-op by filtering targets away.

No read query is needed. `authorizationStatus(for:)` describes sharing/write authorization only. The module does not call requestAuthorization; denied or undetermined sharing permission produces a typed failure. HealthKit permits deleting only objects the calling App saved. Visible query emptiness, pairing and common Team membership cannot prove ownership or all-device absence.

Official references: [deleteObjects](https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects(of:predicate:withcompletion:)), [HKSource](https://developer.apple.com/documentation/healthkit/hksource), [UUID predicates](https://developer.apple.com/documentation/healthkit/hkquery/predicateforobject(with:)), [metadata predicates](https://developer.apple.com/documentation/healthkit/hkquery/predicateforobjects(withmetadatakey:allowedvalues:)), [authorizationStatus](https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:)).

## Verification

Run host tests with `swift test --package-path native/Modules/HealthKitDeletion --scratch-path /private/tmp/football-m4-028-host`. Build target HealthKitDeletion with minimum triples `arm64-apple-ios17.0-simulator`, `arm64-apple-ios17.0`, `arm64-apple-watchos10.0-simulator`, `arm64-apple-watchos10.0`, using iphonesimulator/iphoneos/watchsimulator/watchos SDKs and separate tree-external scratch paths. Exact commands, input hashes and raw results are bound in the NATIVE-028 validation card and external evidence manifest. Compilation is not device execution or real deletion acceptance.
