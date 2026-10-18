# Local authority operations

NATIVE-034 is local readiness for the Node v22.23.1 reference authority, using built-in SQLite/crypto/HTTP/HTTPS. It does not deploy a service, provision production keys, call Apple, change App/Swift TLS, choose a provider, or enable production trust. The existing server CLI remains development-only and revocation remains Unavailable by default. All rehearsals below create isolated throwaway development data; do not point them at user databases or credentials.

## Preflight

Supply an existing absolute private configuration file with exactly these fields (optional receiptKeyID uses the existing authority default):

```json
{
  "databasePath": "/private/isolated-authority/authority.sqlite",
  "environment": "development",
  "accountHMACKeyFile": "/private/isolated-authority/account.key",
  "tokenDerivationKeyFile": "/private/isolated-authority/token.key",
  "receiptPrivateKeyFile": "/private/isolated-authority/receipt.pem"
}
```

The parent directories must belong to the current POSIX user with no group/world permissions (normally0700), and files must be owned private regular files (normally0600). Final symlinks are rejected. Existing SQLite/WAL/SHM permissions are checked. Keys are read with no-follow and inode checks, validated by unchanged authorityConfig, and compared to the DB's registered fingerprint. SQLite schema2 and integrity must pass read-only checks. Missing keys/database, weak permissions, changed keys, corrupt DB or production environment fail closed. The tool creates neither source DB/schema nor replacement keys and performs no rotation.

```sh
node backend/ops/cli.mjs preflight /private/isolated-authority/ops.json
```

Output is finite JSON: ready or unavailable, without paths, keys, input/errors or token data. SQLite ExperimentalWarning remains on stderr. Internal configuration helpers return in-memory secret material to other ops functions and must not be logged or serialized.

## Consistent backup and restore

```sh
node backend/ops/cli.mjs backup /private/isolated-authority/ops.json /private/isolated-authority/new-backup
node backend/ops/cli.mjs restore /private/isolated-authority/new-backup /private/isolated-authority/new-restored
node backend/ops/cli.mjs preflight /private/isolated-authority/new-restored/config.json
```

Both destination directories must be new absolute paths under an owned private parent. Existing paths, including the source directory/database and previous restore targets, are never overwritten. A bundle contains a standalone consistent authority.sqlite snapshot, matching account.key/token.key/receipt.pem and manifest.json. The [Node SQLite online backup API](https://nodejs.org/download/release/v22.23.1/docs/api/sqlite.html#sqlitebackupsource-db-destination-options) reads committed SQLite/WAL state through an independent connection; copying only the active main file is not used. The destination switches to standalone DELETE journaling, closes, verifies integrity/fingerprint, and syncs private files before publishing its completion manifest last. Bundle directory is0700 and files0600.

The manifest records fixed filenames, hashes, sizes, environment and receipt key ID. Restore verifies every file and matching-key fingerprint/integrity before creating a new private target, copies with exclusive creation, checks again and writes config.json plus restore-complete.json last. The bundle can be moved as one directory; it has no stored absolute source-key references. It contains plaintext private keys and control data and must stay in trusted private local custody. Checksums detect corruption, not a malicious owner replacing all backup content. This is not encryption, a secret-manager binding, off-host backup or a rotation policy.

A failed/interrupted operation returns unavailable and can leave a private incomplete directory. No partial output is automatically deleted or retried into the same path. A missing/invalid completion manifest cannot restore; a target without restore-complete.json is not complete. Choose a fresh explicit target after diagnosis. Matching original keys must remain available; there is no replacement-key recovery shortcut.

Run the fully isolated restore rehearsal without supplying user paths:

```sh
node backend/ops/drill.mjs
```

It generates throwaway development fixtures only when explicitly executed (imports have no side effects), snapshots an active WAL authority, restores to a new path and verifies over real HTTP: exact original signed receipt bytes, one active lock, the next global epoch, permanent auth-abandonment fence, original delete-capability receipt, and default Unavailable revoker. Controlled fixture revocation is not actual Apple revocation. Output is only restoreDrillComplete/checks6. Temporary rehearsal data remains private; the tool performs no broad cleanup.

## Isolated TLS and contract smoke

```sh
node backend/ops/tls-drill.mjs
node backend/ops/cli.mjs smoke https://localhost:PORT /private/local-tls/cert.pem FULL_40_HEX_SOURCE_SHA
```

The standalone drill uses the installed openssl command solely to generate an ephemeral local RSA certificate/CA, creates an isolated HTTP fixture and HTTPS front, runs the smoke, closes listeners and prints only localTLSSmokeComplete/checks3. No install/upgrade, real DNS/Apple/credential use or global TLS bypass is performed. It requires this Git checkout; the configured version tag is the current checked-out SHA.

createLocalTLSProxy accepts explicit private key/certificate files, a fixed literal-loopback HTTP root upstream and configured sourceVersion. It binds only literal loopback, requires Host localhost:actualPort, bounds bodies/timeouts, and forwards unchanged method/path/body plus credential/PoP headers to the existing HTTP factory. It does not change that factory or create a production TLS listener. runContractSmoke accepts only HTTPS localhost/127.0.0.1 root URLs, an explicit private fixture CA and expected version. Certificate chain and hostname verification remain on; redirects are never followed, and bad CA/name/Host/version, nonlocal URLs and timeouts fail closed. Each smoke probe has an absolute deadline (default1s, maximum5s), and the local front has a1s absolute upstream deadline, including continuously dripping response bytes.

Three probes check strict duplicate-key422, unauthenticated original-request401 and unknown-route404 through TLS. The front's x-football-reference-version is a configured local harness tag checked for equality, not authenticated deployment-version evidence. These probes are a narrow smoke, not the whole contract suite or Swift URLSession/ATS acceptance. The full backend regression remains:

```sh
node --test backend/test/*.test.mjs
```

Actual provider/storage atomicity, deployed URL/certificate/key custody/rotation, real Apple accounts/revocation, Swift TLS and physical device acceptance remain NATIVE-026 gates.

Snapshot boundary: restore replays only the selected backup point. This drill verifies receipts, lock, fence, capability and next epoch present in that snapshot; it cannot guarantee preservation or monotonicity of locks, requests or global epochs published after that point. Restore only writes a new offline development target and never opens production acquire or starts a service. NATIVE-026 must establish continuous provider durability, an explicit RPO, invalidation/recovery procedure and epoch high-water handling under real acceptance before serving externally after recovery. Reverting to an old snapshot is not declared safe production failover.
