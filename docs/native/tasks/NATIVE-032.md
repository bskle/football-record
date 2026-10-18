# NATIVE-032 First-auth absence recovery

Status: automatic implementation complete; exact source/final non-author reviews pending.

| Field | Registration |
|---|---|
| Sole author / coordinator | /root/m4_authority / root |
| Reviews | root + m2 exact source/final, both pending |
| base_ref / original full base | dev / `36daa5526aac447cedab8c0b636c2db80b09cfa6` |
| Latest verified merge target | dev / `ef10b33a10663ad94b0bb4a3e43106af108c38bb` |
| Branch | `fix/m4-auth-absence-recovery` |
| Attachment / createdAt | `01a1501d-cebc-7530-a422-99f71e5dea33` / `1792345493` |
| Worktree | `/Users/liam/.codex/worktrees/m4-auth-absence-recovery/20260830_足球记录` |
| Initial actual HEAD / state | `36daa5526aac447cedab8c0b636c2db80b09cfa6` / clean, branch verified |
| Startup synchronization | ordinary merge of verified target before task writes; original base preserved |
| Ownership | auth-recovery focused `backend/**`, M4 contract, this card and 032 validation card |
| Read-only | native/Core/AccountKit/Cloud/App/project/config and all other docs/plans |
| External evidence | `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-032` |

Approved wire: existing auth/recover accepts optional devicePublicKey, included in the original full-request signature domain. Known original row always returns original credential or knownRevoked/knownExpired; legacy wire remains compatible. Missing row with valid original key/device/request proof may atomically persist opaque permanent absence fence and return knownAbandoned. That status asserts present absence plus future original tuple cannot commit, never historical never-committed. Missing-row old wire stays unauthorized. Authenticate checks the same fence after Apple await inside SQL before mutations. New schema stores only domain-separated HMAC tuple/nonce values; no added raw account/device/Apple/token association.

Runtime tests precede implementation; actual HTTP/file SQLite covers not-sent/rollback/reopen/COMMIT loss, proof rejection, both await race orders, independent database workers, migration rollback and deletion/privacy. New client behavior is handed to 023 only after root-reviewed actual merge. No real Apple/WC/device/deployment request. Author does not advance long-lived branches, push, archive or clean up.

Implementation complete for automatic software; source/final and exact root+m2 review pending. Schema2 adds only opaque HMAC tuple/nonce control tables; permanent fence survives account deletion without raw tuple/account linkage. Authentication checks it inside the post-Apple-await SQL transaction before mutation. Existing original rows remain first and optional-field old-wire compatibility is preserved; only the requested optional signed public key and knownAbandoned status extend HTTP.

Observed runtime-first complete red: 14/14 failures before implementation (032-red-complete.log). Initial red barrier cleanup and one malformed fractional request fixture in first 13/14 green output are retained separately; complete corrected new set is 14/14. Single complete backend round is 128/128 (114 inherited + 14 new), zero failures/skips/cancellations. The inherited privacy test changes only its expected schema version 1 to 2. Real independent workers use separate DatabaseSync connections to the same file and Atomics barrier; actual HTTP tests force both Apple-await race orders. Migration trigger failure rolls back version/table changes and preserves prior result bytes; code/JWT/subject/token sentinel scans cover DB/WAL/SHM and safe logs.

Client handoff frozen in contract/README: send original devicePublicKey in full signRecover body, retain old attempt on unknown/401, accept only knownAbandoned as present-absence plus permanent-fence terminal, preserve existing knownRevoked/knownExpired/original-session behavior. No historical never-committed claim. 023 must wait for reviewed actual merge before consuming.

Final exact post-commit round, six Git inputs and all original-base/latest-target source/evidence hashes are external; cards do not predeclare review PASS or root merge/push/archive. Author stops clean. Real Apple/WC/devices/deployment and production enablement remain unverified.
