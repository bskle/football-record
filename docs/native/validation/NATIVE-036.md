# NATIVE-036 validation

Base and current target: `75c3b0e833ea71c0e69c3c3b40e8c3c766074969`. Source/final is the coherent commit containing this card; its exact SHA, clean status, Git blobs and hash manifest are maintained outside the tree to avoid a self-referential commit. Exact nonauthor review/merge are pending.

External evidence: `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-036`.

| Evidence | Actual result |
|---|---|
| Initial status/head/base/target/diff/worktrees inputs + versions | Captured before product writes; Node22.23.1, SQLite3.51.3 |
| `036-red.log` | 14 failing runtime tests before implementation; actual GET404 and expired original POST401 |
| `036-delete-boundary-red.log` | 16 failing tests before product implementation |
| `036-request-fence-delete-red.log` | requests-only closure15pass/1fail: old live proof incorrectly registered200 after delete/new epoch |
| `036-green.log` | Final targeted16/16, exit0 |
| `036-full-green.log` | Initial full single round161/161, exit0; SQLite ExperimentalWarning retained |
| `036-boundary-green.log` | Strengthened delete/reopen/opaque-row targeted16/16, exit0 |
| `036-final-full-green.log` and `036-final-test-inputs.json` | Final full single round161/161, exit0; runtime input hashes checked against committed blobs |
| Source/evidence manifest | Captured externally after commit; no assumed review PASS |

Commands use `/Users/liam/.local/bin/node --test backend/test/watch-registration-recovery.test.mjs` and `/Users/liam/.local/bin/node --test backend/test/*.test.mjs`. Tests use real loopback HTTP, real RSA auth and Ed25519 signatures, disk SQLite, a precise SQL-trigger rollback, socket loss after business COMMIT, close/reopen and independently connected workers synchronized by Atomics. Registered original receipt/session/credential and closed original bytes are compared exactly. Worker outcomes allow either serialized winner but never both a new session and closed result.

The missing-row fence and requests closure commit atomically. A live-TTL close/delete/same-anonymous-account new epoch regression proves the opaque bit persists and both old register/recover return401. Another account's closure neither consumes the original Watch challenge nor fences the original account. No raw identity/token/code is added to a schema column. Existing schema2/table layout, nonowned sources, fixed receipt vector, old PoP/receipt domains and native/v2 files remain unchanged; no new schema migration is necessary.

KnownAbandoned is a signed closure of the original current-domain attempt, not historical never-committed evidence. GET404,401,timeout and failed/lost responses remain unknown until a verified closed or original registered result arrives. NATIVE-023 owns explicit first-submit/recover relay and durable closed-CAS; it must wait for reviewed integration before consuming this wire.

No real Apple/JWKS/revoke/account, WC, device, Swift TLS or deployment was exercised. Production bootstrap/default-unavailable gates remain unchanged. Physical acceptance is not applicable to this backend-only software change and remains a separate026 gate.
