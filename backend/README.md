# Football Record reference authority

NATIVE-021 implements the automatic software boundary in [M4 section 5](../docs/superpowers/plans/2026-10-18-native-m4.md) and the [frozen control contract](../docs/native/contracts/m4-account-lock-cloud.md). Supported runtime: **Node v22.23.1**, built-in HTTP, crypto, worker_threads and node:sqlite; no npm dependencies. SQLite remains experimental and its warning is retained in validation output.

This is a file-backed, loopback reference service. Production Serverless storage, TLS, key custody/rotation, deployment, backup/restore, real Apple login/revocation and device acceptance remain NATIVE-024/026 work. NATIVE-027 adds an optional programmatic server revocation adapter under [M4 section 12](../docs/superpowers/plans/2026-10-18-native-m4.md). No native/App/Bootstrap file changes or production capability enablement are included.

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

`createAuthority({databasePath,accountHMACKey,tokenDerivationKey,receiptPrivateKey,clock,environment,receiptKeyID,appleRevoker})` returns the lock/status/query, Watch, peer, migration, deletion and metric operations. HMAC/token keys are Buffers of at least 32 bytes, receiptPrivateKey is an Ed25519 KeyObject or PKCS8 PEM, and clock supplies integer Unix `now()`. The reference environment defaults to development. `createDeviceAuth({authority,appleVerifier})` installs explicit Watch credential issuance. `createHTTPServer({authority,appleVerifier,deviceAuth,logger,rateLimit})` binds only the contract routes. Programmatic faults are dependency-injected test controls, never HTTP fields or CLI flags.

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

`createAppleVerifier` always reads `https://appleid.apple.com/auth/keys`, rejects token-provided key URLs, allows only RS256/RSA/sig and checks signature, issuer, audience, nonce, exp and iat. Cache lifetime is bounded to 3600 seconds; concurrent unknown-kid requests share one refresh. Fetch failure fails closed. `createDevelopmentAppleVerifier` is a separate factory for genuinely signed test RSA/JWKS inputs; its environment cannot authenticate a production authority. It does not accept unsigned fixture tokens. Production DeviceAuth requires the genuine production verifier factory brand at construction, then checks the independently branded production identity and its environment again after verification returns, before any session or account write. Copying a verifier or matching its environment string does not carry that brand. The frozen production verifier cannot have its verify method replaced. Explicit controlled development legacy verifiers remain supported only in the development path.

Challenge requests have a separate pre-account transport namespace. A stable challenge requestID binds the complete device/public-key intent; same ID/different body is 409. The random challengeID and fixed claims persist, while a domain-separated HMAC reconstructs the original 256-bit secret from tokenDerivationKey. Only its hash persists. Lost response/reopen returns the same secret and original expiry, never a fresh lifetime. Consumed/expired IDs return explicit terminal status without a secret. Device challenge proof signs `football-record.device.challenge.v1\n` plus the entire auth/Watch request minus deviceProof, with `challengeSHA256` added. The Apple JWT nonce is that challenge hash. Challenge lifetime is 300 seconds.

After auth COMMIT response loss, **do not replay the consumed challenge, JWT or code**. `POST /v1/auth/recover` has no bearer. Sign all its fields except deviceProof with `football-record.device.auth-recover.v1\n`; use the original authRequestID/device/key and a fresh nonce/time. The server reconstructs the original token/session, or reports `knownExpired`/`knownRevoked`. This does not reactivate the account. A known terminal session can be followed by a new challenge and full authentication.


NATIVE-032 extends that existing recovery body with optional `devicePublicKey`, the original strict raw32 Ed25519 public key. New clients always include it in the complete original auth-recover-domain signature; omitting it preserves legacy signing bytes. Existing authRequestID/deviceID rows take precedence, require the original key/fingerprint plus matching optional public key, and return only the original session/receipt or knownExpired/knownRevoked. They never become absence, and even missing-session terminal recovery consumes a durable nonce.

For a missing row, legacy wire stays unauthorized. A new body must prove the original key fingerprint, full device/key/authRequestID binding, signature, time within 60 seconds and fresh nonce. One BEGIN IMMEDIATE transaction persists a permanent opaque tuple fence and scoped nonce before returning `{status:"knownAbandoned"}`. This means current absence plus the exact original tuple cannot commit later; it does not assert history never committed, including after account deletion purged old auth records. Authenticate rechecks the same fence after its Apple await inside SQL before account/epoch/session/challenge changes. Another device/key can fence only its own tuple and cannot recover or cancel the original. Abandonment creates no session or epoch.

SQLite schema 2 adds only HMAC fence IDs and separately domain-separated HMAC nonce hashes, keyed by persistent tokenDerivationKey; no new raw auth/device/account/public-key/Apple/token columns. Schema 1 upgrades atomically with the existing fingerprint check, preserving original result/receipt bytes; failed migration rolls back. These unlinked opaque controls survive account deletion to stop a late original attempt. They are permanent controls, not a token retry queue or an absolute anonymity claim.

The client persists its original attempt until recovery returns an authenticated terminal result. 401, timeout, SQL rollback or lost response remains unknown. After a recover COMMIT response loss, use the same original attempt and a fresh signed nonce; never replay a consumed nonce. Only explicit knownAbandoned/knownRevoked/knownExpired permits ending the old unknown attempt and starting a fresh challenge/auth ID. No automatic new-ID fallback is authorized. NATIVE-023 implements that client state transition after reviewed server integration.

A new same-key challenge and genuine Apple verification on a previously known phone issues a fresh single-use reauthenticationID, bound to account/device/key and the **Apple iat**, with expiry iat+300. Initial login is not reauthentication. It does not activate a waiting phone. The same UUID cannot change keys or accounts. A registered Watch cannot enter the phone auth path.

## Migration and deletion

Second-phone auth is waitingMigration, never replacement activation. Normal prepare requires the active old phone online through its authenticated request, an already verified waiting new phone, no lock and no pending deletion. The client additionally checks no endedPendingSync/cloud pending/conflict before preparing or asserting a final checkpoint; the service cannot inspect those private facts. Prepare freezes starts; final opaque checkpoint deactivates the old phone; the waiting phone must verify that same checkpoint in the stable account/cloudSpace zone before CAS activation. A failed download leaves it waiting. Physical cloudSpace identity remains stable; the new epoch fences writes only.

Lost migration retains original server requestedAt and eligibleAt=requestedAt+604800 across repeat IDs, restart and clock rollback. At/after eligibility it requires an unused fresh Apple iat at/after eligibleAt. With a held lock, only the waiting phone's short-lived exact lost-recovery grant can abnormal-release the original match/lock/recorder/epoch; it does not grant start/Workout authority. Force activation requires no held lock and a separate unused fresh proof. Old devices do not take over recording. Unsaved CloudKit data may be unavailable to recovery.

Activation revokes old sessions, returns a signed new-epoch receipt, and preserves the original business ID. If its response is lost, auth/recover confirms the old session knownRevoked; the same device/key performs a new challenge/full login, then GETs the **original activation requestID** with its new credential. Tests cover this over actual HTTP for normal and forced activation. A formerly active phone can later freshly authenticate with the same key as a valid current-epoch waiting phone. A prior Watch requires explicit current-phone challenge/possession re-registration at the new epoch; old sessions/grants remain invalid. No old client business pending data is silently retargeted.

Deletion and normal/lost migrations are durably mutually exclusive. The deletion saga persists requested -> lockReconciled -> appleRevocation -> backendDeleted. A held lock requires an explicit separate abnormal compare-release; pending deletion blocks starts. The revocation adapter is **Unavailable by default**. NATIVE-027 supplies explicit server factories described below; the CLI never enables them. Exchange/revoke network awaits occur outside SQL, followed by exact account/device/key/epoch/pending-request/digest/reauthentication CAS. Real Apple exchange/revoke remains unverified.

A revoke failure or process restart may lose that transient code. Fresh same-account/device/key authentication may refresh the authorization bound to the one original pending deletion. It neither changes the original delete body/digest nor advances its state; another device cannot refresh it. Cloud/local choices and HealthKit confirmation are entirely client-owned saga fields, never changed through backend reauthentication.

Before sending delete, persist a random 256-bit capability locally. The signed delete intent carries only its SHA256. COMMIT removes identity binding, devices, keys/sessions/challenges, gifted qualification and restrictions while retaining a minimal pseudonymous signed receipt plus capability hash for 30 days. Capability is supplied **only in the body** of unauthenticated delete-status, compared in constant time, and can only query that original result. It cannot make a session or account. Missing/expired receipts return receiptExpired; a wrong capability for a retained receipt is unauthorized. Client control/capability survives until cloud/local/HealthKit choices finish or are explicitly retained. BackendDeleted is never presented as all four deletion choices succeeding. Purchase restoration remains Apple's responsibility; no StoreKit purchase implementation is claimed.

## Peer grant role proof

`POST /v1/peers/grants` keeps its existing request fields and device PoP. New `body.peerGrant` results add mandatory signed `localRole`, `remoteRole` and `activePhoneID`, alongside existing pair/grant IDs, endpoint IDs/public keys and expiry. The active phone is the authenticated caller. Both endpoints must be registered under that account at the current activation epoch; exactly one is the current active phone and one a Watch, in either endpoint order. Database roles and the account active phone determine the fields. Request-supplied roles/activePhoneID are rejected as unknown fields. Watch-Watch, Phone-Phone, waiting, unknown-role, wrong-account/epoch, wrong caller/key and nonactive phone endpoints cannot obtain a new grant.

A client production verifier must require all three signed fields, the phone/Watch combination and phone deviceID equal to activePhoneID, plus the current account/epoch, exact source/target/public-key bindings, signature and expiry. WC, envelope fields or endpoint naming do not establish role. The grant remains preproduction V1 under the existing receipt domain; request DTO, schema, PoP and original v2 packet/ACK bytes are unchanged. Production trust/bootstrap remains unavailable until its separate acceptance gates.

Original request replay/GET returns the exact stored bytes, including old missing-role or historical Watch-Watch receipts. The server never backfills, re-signs or extends them. A valid old signature alone without required role proof cannot authorize a new production context. A legitimate pair explicitly renews with a new control requestID and the same pairingID and ordered endpoints; it keeps grantID, receives current role/active-phone proof and a new expiry, and leaves every original request result intact. Changing ordered endpoints under the same pair conflicts. An old invalid pair cannot renew into a new proof. Expired receipt replay remains historical output, not current authorization.

## Optional server Apple revocation adapter

`createAppleRevoker` in `src/apple-revoker.mjs` accepts explicit `{teamID,keyID,clientIDs,privateKey,appleVerifier,clock?,redirectURIs?}` and returns a frozen callable with immutable `environment: "production"`. `privateKey` is a server P256 PKCS8 PEM/Buffer or private KeyObject; TeamID and KeyID are 10 alphanumeric characters. Keep all configuration exclusively in server memory/key custody. No server credential, `.p8`, client_secret, token or authorization code belongs in an App, source control, SQLite or logs. The CLI has no adapter/key flags and still defaults to Unavailable.

Pass that callable as `createAuthority({...,environment:"production",appleRevoker})`. A production authority rejects development or unbranded callables both at construction and immediately before use. `createDevelopmentAppleRevoker` is a distinct factory with additional `baseURL` and optional `timeoutMs`; it accepts only an `http://127.0.0.1` or `http://[::1]` root URL and a genuine development verifier. Legacy controlled callables remain available only to development software fixtures. Development success is not Apple account acceptance.

The internal hook is `appleRevoker({authorizationCode,expectedApple,reauthenticationID}) -> Promise<{revoked:true}>`. `expectedApple` is the frozen, WeakMap-branded result of actual RS256 verification: issuer, subject, audience, nonce, issuedAt and environment. The authority stores it only in a bounded memory bundle with code and original account/device/key/epoch/reauthentication binding. Taking that bundle recomputes the account HMAC from the verified issuer/subject, checks its exact binding, and consumes it once. Rollback drops orphan material; a committed lost auth response can recover its original live reauthentication. Expired or orphaned entries are pruned on auth/deletion/material access, and all entries are disposed on authority close. Capacity is 256; eviction requires fresh authentication. Disposing drops references to strings and identity data; JavaScript does not promise erasure of every runtime string copy.

Production transport fixes HTTPS destinations to `https://appleid.apple.com/auth/token` and `/auth/revoke`; production verifier JWKS remains fixed to `/auth/keys`. Factories provide no endpoint/transport injection, follow no redirects, and use a five-second request deadline. Each invocation generates one 300-second ES256 client JWT with configured kid, iss=TeamID, sub=clientID and aud=`https://appleid.apple.com`. Its signature is raw 64-byte P1363 R||S. The same JWT is sent in URL-encoded exchange/revoke forms.

Exchange sends `client_id`, `client_secret`, `code` and `grant_type=authorization_code`. The current native AuthenticationServices auth path never supplies a redirect URI. Only the verifier's optional internal third argument `{authorizationRedirectURI}` can establish an original URI; it must exactly match that audience's explicit HTTPS allowlist in both verifier and revoker. Configuration alone never adds it to a form. This adds no HTTP field or browser login flow.

The exchange must return bounded UTF-8 strict JSON with no duplicate keys or unknown token-response fields, a genuine independently verified RS256 id_token matching the original issuer/subject/audience/nonce/environment, and a nonempty refresh_token. Missing either fails before revoke. Revoke sends only `client_id`, `client_secret`, `token=refresh_token`, `token_type_hint=refresh_token`; there is no access-token fallback. HTTP 200 with empty body succeeds without JSON parsing. Status/body/timeout/disconnect/identity errors become finite `reauthenticationRequired` responses without upstream content. No automatic retry replays an unknown exchange or revoke, and bounded in-memory reauth/code-hash attempt guards reject reuse.

Code, exchanged tokens and client_secret stay in the current process. No durable token queue is created. An unknown result, process restart, expired/evicted material or revoke-success/SQL-failure requires a fresh same-account/device/key Apple authentication while retaining the original delete requestID/body/digest and capability. SQL cannot advance until the returned success still matches the exact pending saga/epoch/reauthentication. The adapter's RSA/P256 loopback tests verify forms and signatures; actual TeamID/KeyID/private-key setup, real Apple exchange/revocation, token lifecycle and deployed transport remain unverified NATIVE-026 acceptance.

## Optional anonymous metrics

Only the frozen nine metric names and finite count/version/OS/qualification fields are accepted. Unknown business/health/location/identity fields are rejected before persistence/logging. Metrics use stable request IDs, daily anonymous account buckets, match counts, DAU/WAU/MAU, last active day, version/device/qualification buckets, and integer success/total pairs. The backend feature and `createAnalyticsQueue` default off; turning the queue off or logging out discards unsent optional entries. It has no heartbeat. The small Node queue is a software reference, not the future Swift durable client ledger. Deletion removes per-account metric rows; de-identified aggregate counts can remain.

## Test handoff

`startFixtureAuthority({databasePath,clock,faults})` in test/support.mjs starts real loopback HTTP on port 0 and returns `baseURL,client,close,restart,raceWorkers`. Keys and signed RSA identities are isolated development fixtures. Its client uses real session tokens and device signatures; there is no production token bypass switch. `client.liveStatus(receiptBody)` builds the exact narrow status request with a fresh nonce. The lock test starts two independent workers/DatabaseSync connections to the same disk file, synchronizes with an Atomics barrier and records distinct thread IDs. Startup-key contention separately widens scheduling in test workers and rejects a second key configuration.

`openHTTPFixture` adds real HTTP Apple challenge/auth, arbitrary signed control calls and captured safe logs for cross-account, role, malformed-body, 401/403/409/422/429/503 and disconnect/reopen assertions. Faults cover rollback before COMMIT, response loss after COMMIT, lifecycle steps and precise HTTP response disconnect after a selected operation. GET returns exact stored receipt bytes. Fixture success does not establish actual Apple/iCloud/Watch/production-service acceptance. Final exact-SHA inputs, raw red/green outputs and file hashes are listed in the task validation card and its external evidence manifest.

## Local operations readiness

[NATIVE-034 operations](ops/README.md) adds private no-secret-output config/fingerprint preflight, consistent online SQLite/WAL plus matching-key backup/restore, and runnable isolated restore/TLS drills. Destinations are new private directories, completion publishes last, and restore rejects corrupted, mismatched or interrupted bundles. The smoke verifies local certificate/host/no-redirect and three contract error boundaries through a loopback TLS front. This is local Node readiness; server CLI stays development-only, revoker Unavailable by default, and actual deployment/Swift TLS/Apple/device acceptance remains deferred.

Restore drills prove only backup-point state. Post-backup published locks/requests/global epochs may be lost or roll back; restoring files never starts a service. Continuous provider durability/RPO, invalidation and epoch high-water recovery remain real026 requirements before any external service resumes.
