# Football Record reference authority

NATIVE-021 implements the automatic software boundary in [M4 section 5](../docs/superpowers/plans/2026-10-18-native-m4.md) and the [frozen control contract](../docs/native/contracts/m4-account-lock-cloud.md). Supported runtime: **Node v22.23.1**, built-in HTTP, crypto, worker_threads and node:sqlite; no npm dependencies. SQLite remains experimental and its warning is retained in validation output.

This is a file-backed, loopback reference service. Production Serverless storage, TLS, key custody/rotation, deployment, backup/restore, real Apple login/revocation and device acceptance remain NATIVE-024/026 work. No native/App/Bootstrap file changes or production capability enablement are included.

## Run and persist configuration

Run tests from the repository root:

```sh
node --test backend/test/*.test.mjs
```

The CLI requires an explicit development namespace, absolute DB path, three persistent private configuration files and an Apple audience allowlist. It never generates replacement keys on startup. File keys must have no group/world permission bits. Keep all three keys across restarts; a fingerprint registered in the same initialization transaction rejects changed keys/environment for an existing DB. Missing keys fail before opening that DB. A global epoch allocator survives deleting individual accounts.

For an isolated local exercise, create keys once outside the checkout:

```sh
export FOOTBALL_PRIVATE_DIR="$(mktemp -d /private/tmp/football-authority.XXXXXX)"
node --input-type=module <<'JS'
import {writeFileSync} from 'node:fs';
import {randomBytes,generateKeyPairSync} from 'node:crypto';
const directory=process.env.FOOTBALL_PRIVATE_DIR;
writeFileSync(directory+'/account.key',randomBytes(32),{mode:0o600});
writeFileSync(directory+'/token.key',randomBytes(32),{mode:0o600});
writeFileSync(directory+'/receipt.pem',generateKeyPairSync('ed25519').privateKey.export({format:'pem',type:'pkcs8'}),{mode:0o600});
JS
export FOOTBALL_AUTH_ENV=development
export FOOTBALL_AUTH_DB="$FOOTBALL_PRIVATE_DIR/authority.sqlite"
export FOOTBALL_AUTH_ACCOUNT_KEY_FILE="$FOOTBALL_PRIVATE_DIR/account.key"
export FOOTBALL_AUTH_TOKEN_KEY_FILE="$FOOTBALL_PRIVATE_DIR/token.key"
export FOOTBALL_AUTH_RECEIPT_KEY_FILE="$FOOTBALL_PRIVATE_DIR/receipt.pem"
export FOOTBALL_AUTH_APPLE_AUDIENCES=your.app.bundle.id
export FOOTBALL_AUTH_PORT=8787
node backend/src/server.mjs
```

The default host is `127.0.0.1`; only literal `127.0.0.1` and `::1` bindings are allowed. Port `0` selects an OS-assigned port. The startup record reports host/port/environment; request logs contain only finite code, safe requestID, fixed operation and duration. The CLI uses the fixed Apple JWKS URL even in the development signing namespace; it has no fixture-token flag. A configured audience alone does not create a real Apple client or verify a deployment.

`FOOTBALL_AUTH_ANALYTICS=1` enables the optional server metric endpoint; it defaults disabled. Client consent is separate and also defaults disabled. No request timer emits activity.

## APIs and wire

`createAuthority({databasePath,accountHMACKey,tokenDerivationKey,receiptPrivateKey,clock,environment,receiptKeyID})` returns the lock/status/query, Watch, peer, migration, deletion and metric operations. HMAC/token keys are Buffers of at least 32 bytes, receiptPrivateKey is an Ed25519 KeyObject or PKCS8 PEM, and clock supplies integer Unix `now()`. The reference environment defaults to development. `createDeviceAuth({authority,appleVerifier})` installs explicit Watch credential issuance. `createHTTPServer({authority,appleVerifier,deviceAuth,logger,rateLimit})` binds only the contract routes. Programmatic faults are dependency-injected test controls, never HTTP fields or CLI flags.

The exact route/field allowlists are in `src/codec.mjs`; unknown/duplicate JSON keys, nested properties, non-objects, invalid UTF-8, unsafe/fractional numbers, invalid strict base64url, wrong versions and bodies over **16 KiB** are rejected. All control IDs use the frozen 1-128 ASCII grammar. Normal termination requires both opaque cloud fields; abnormal termination forbids them. Core authority entries validate the same typed DTOs as HTTP.

A session response contains `credential.token, sessionID, accountID, deviceID, keyID, activationEpoch, expiresAt`; only token hash and fixed reconstruction claims persist. The token is domain-separated HMAC derived from the stable session claims. No Apple subject/email/JWT/code or plaintext bearer token is stored. `context` repeats the public binding for the software harness; it is not an authorization bypass.

For every authenticated request, send:

```text
Authorization: Bearer <opaque token>
X-Device-PoP: <strict base64url of canonical JSON {keyID,nonce,issuedAt,signature}>
```

The Ed25519 signed bytes are UTF-8 `football-record.device.pop.v1\n` followed by sorted-key JSON of **all** `method,path,requestID,bodySHA256,sessionID,activationEpoch,keyID,nonce,issuedAt`. `bodySHA256` hashes the exact transmitted bytes. GET uses the empty-byte SHA256, its complete path, and the original ID in that path. A new nonce/time requires a new signature. Time skew is at most 60 seconds. Nonces are consumed durably after signature verification; retries use a fresh transport proof and the same business request ID/body.

An account-wide request ID permanently binds operation and complete canonical business digest. The first result bytes persist in the same BEGIN IMMEDIATE transaction as the state change. A pending deletion reserves that namespace too: conflicting operations fail 409; GET of its not-yet-final result returns retryable 503. After backend deletion, only capability recovery is available. SQL busy is retryable 503 and never a successful losing acquire.

The first lock winner returns `held`; a competing distinct request returns `originalMatch` with the original lock identity. Neither clock movement nor grant/session expiry releases a lock. After release, old acquire bytes still describe only the original outcome. A fresh `POST /v1/locks/status` has its own random body nonce and signed domain `football-record.authority.live-lock.v1`, full query digest, `held|terminal|mismatch`, observedAt and 60-second expiry. Only the recorder or active phone may query that lock. Only fresh `held` authorizes a software start.

Normal release requires the **original recorder's** session and device PoP; an iPhone network proxy preserves the Watch credential/signature. An active iPhone using only its own PoP can perform abnormal termination, not claim a Watch's normal completion. Exact account/match/lock/recorder/epoch compare-release prevents an old termination from freeing a later match. Cloud confirmation and commitment are authenticated client assertions: the service cannot independently verify a private CloudKit save and does not sign such a claim.

Receipts use UTF-8 `football-record.authority.receipt.v1\n` plus sorted-key canonical body. Raw public keys are exactly 32 bytes base64url, signatures exactly 64 bytes; SPKI DER is not the wire public key. Pin keyID/public key and environment outside the response. `test/fixtures/receipt-v1.json` is a fixed **development public-only** interoperability vector: full intent and its canonical bytes, complete body UTF-8 bytes, full signing input bytes, raw key/signature and domain/keyID. Its generating private key was discarded. Swift must compare the provided bytes and full intent digest, not merely reserialize its own model.

## Apple and recovery details

`createAppleVerifier` always reads `https://appleid.apple.com/auth/keys`, rejects token-provided key URLs, allows only RS256/RSA/sig and checks signature, issuer, audience, nonce, exp and iat. Cache lifetime is bounded to 3600 seconds; concurrent unknown-kid requests share one refresh. Fetch failure fails closed. `createDevelopmentAppleVerifier` is a separate factory for genuinely signed test RSA/JWKS inputs; its environment cannot authenticate a production authority. It does not accept unsigned fixture tokens.

Challenge requests have a separate pre-account transport namespace. A stable challenge requestID binds the complete device/public-key intent; same ID/different body is 409. The random challengeID and fixed claims persist, while a domain-separated HMAC reconstructs the original 256-bit secret from tokenDerivationKey. Only its hash persists. Lost response/reopen returns the same secret and original expiry, never a fresh lifetime. Consumed/expired IDs return explicit terminal status without a secret. Device challenge proof signs `football-record.device.challenge.v1\n` plus the entire auth/Watch request minus deviceProof, with `challengeSHA256` added. The Apple JWT nonce is that challenge hash. Challenge lifetime is 300 seconds.

After auth COMMIT response loss, **do not replay the consumed challenge, JWT or code**. `POST /v1/auth/recover` has no bearer. Sign all its fields except deviceProof with `football-record.device.auth-recover.v1\n`; use the original authRequestID/device/key and a fresh nonce/time. The server reconstructs the original token/session, or reports `knownExpired`/`knownRevoked`. This does not reactivate the account. A known terminal session can be followed by a new challenge and full authentication.

A new same-key challenge and genuine Apple verification on a previously known phone issues a fresh single-use reauthenticationID, bound to account/device/key and the **Apple iat**, with expiry iat+300. Initial login is not reauthentication. It does not activate a waiting phone. The same UUID cannot change keys or accounts. A registered Watch cannot enter the phone auth path.

## Migration and deletion

Second-phone auth is waitingMigration, never replacement activation. Normal prepare requires the active old phone online through its authenticated request, an already verified waiting new phone, no lock and no pending deletion. The client additionally checks no endedPendingSync/cloud pending/conflict before preparing or asserting a final checkpoint; the service cannot inspect those private facts. Prepare freezes starts; final opaque checkpoint deactivates the old phone; the waiting phone must verify that same checkpoint in the stable account/cloudSpace zone before CAS activation. A failed download leaves it waiting. Physical cloudSpace identity remains stable; the new epoch fences writes only.

Lost migration retains original server requestedAt and eligibleAt=requestedAt+604800 across repeat IDs, restart and clock rollback. At/after eligibility it requires an unused fresh Apple iat at/after eligibleAt. With a held lock, only the waiting phone's short-lived exact lost-recovery grant can abnormal-release the original match/lock/recorder/epoch; it does not grant start/Workout authority. Force activation requires no held lock and a separate unused fresh proof. Old devices do not take over recording. Unsaved CloudKit data may be unavailable to recovery.

Activation revokes old sessions, returns a signed new-epoch receipt, and preserves the original business ID. If its response is lost, auth/recover confirms the old session knownRevoked; the same device/key performs a new challenge/full login, then GETs the **original activation requestID** with its new credential. Tests cover this over actual HTTP for normal and forced activation. A formerly active phone can later freshly authenticate with the same key as a valid current-epoch waiting phone. A prior Watch requires explicit current-phone challenge/possession re-registration at the new epoch; old sessions/grants remain invalid. No old client business pending data is silently retargeted.

Deletion and normal/lost migrations are durably mutually exclusive. The deletion saga persists requested -> lockReconciled -> appleRevocation -> backendDeleted. A held lock requires an explicit separate abnormal compare-release; pending deletion blocks starts. The revocation adapter is **Unavailable by default**. Tests explicitly inject a controlled development revoker. It receives a fresh authorization code only in memory; exchange/revoke network awaits occur outside SQL, followed by exact account/epoch/pending-request/digest/proof CAS. Real Apple exchange/revoke remains unverified.

A revoke failure or process restart may lose that transient code. Fresh same-account/device/key authentication may refresh the authorization bound to the one original pending deletion. It neither changes the original delete body/digest nor advances its state; another device cannot refresh it. Cloud/local choices and HealthKit confirmation are entirely client-owned saga fields, never changed through backend reauthentication.

Before sending delete, persist a random 256-bit capability locally. The signed delete intent carries only its SHA256. COMMIT removes identity binding, devices, keys/sessions/challenges, gifted qualification and restrictions while retaining a minimal pseudonymous signed receipt plus capability hash for 30 days. Capability is supplied **only in the body** of unauthenticated delete-status, compared in constant time, and can only query that original result. It cannot make a session or account. Missing/expired receipts return receiptExpired; a wrong capability for a retained receipt is unauthorized. Client control/capability survives until cloud/local/HealthKit choices finish or are explicitly retained. BackendDeleted is never presented as all four deletion choices succeeding. Purchase restoration remains Apple's responsibility; no StoreKit purchase implementation is claimed.

## Optional anonymous metrics

Only the frozen nine metric names and finite count/version/OS/qualification fields are accepted. Unknown business/health/location/identity fields are rejected before persistence/logging. Metrics use stable request IDs, daily anonymous account buckets, match counts, DAU/WAU/MAU, last active day, version/device/qualification buckets, and integer success/total pairs. The backend feature and `createAnalyticsQueue` default off; turning the queue off or logging out discards unsent optional entries. It has no heartbeat. The small Node queue is a software reference, not the future Swift durable client ledger. Deletion removes per-account metric rows; de-identified aggregate counts can remain.

## Test handoff

`startFixtureAuthority({databasePath,clock,faults})` in test/support.mjs starts real loopback HTTP on port 0 and returns `baseURL,client,close,restart,raceWorkers`. Keys and signed RSA identities are isolated development fixtures. Its client uses real session tokens and device signatures; there is no production token bypass switch. `client.liveStatus(receiptBody)` builds the exact narrow status request with a fresh nonce. The lock test starts two independent workers/DatabaseSync connections to the same disk file, synchronizes with an Atomics barrier and records distinct thread IDs. Startup-key contention separately widens scheduling in test workers and rejects a second key configuration.

`openHTTPFixture` adds real HTTP Apple challenge/auth, arbitrary signed control calls and captured safe logs for cross-account, role, malformed-body, 401/403/409/422/429/503 and disconnect/reopen assertions. Faults cover rollback before COMMIT, response loss after COMMIT, lifecycle steps and precise HTTP response disconnect after a selected operation. GET returns exact stored receipt bytes. Fixture success does not establish actual Apple/iCloud/Watch/production-service acceptance. Final exact-SHA inputs, raw red/green outputs and file hashes are listed in the task validation card and its external evidence manifest.
