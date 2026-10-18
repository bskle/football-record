# NATIVE-034 Local authority operations

Status: automatic local operations complete; exact source/final non-author review pending. No deployment or real credentials/accounts/devices.

| Field | Registration |
|---|---|
| Sole author / coordinator | /root/m4_authority / root |
| Non-author reviews | exact root + m2 pending |
| base_ref / full base / target | dev / `225851d9c00feda5e1d4579293c881bdf89bb090` / same |
| Branch | `feat/m4-authority-local-operations` |
| Attachment / createdAt | `01a15055-6b36-7670-a37c-8984d4ab6b38` / `1792349137` |
| Worktree | `/Users/liam/.codex/worktrees/m4-authority-local-operations/20260830_足球记录` |
| Actual initial HEAD / state | `225851d9c00feda5e1d4579293c881bdf89bb090` / clean, branch verified |
| Ownership | `backend/ops/**`, `backend/test/operational-*.test.mjs`, `backend/test/support/operational-*.mjs`, backend README and 034 cards |
| Read-only | backend/src API/schema/authority/config, native/project/all other docs |
| Input | M4 plan section10 / 026; external preflight SHA256 `f701bdfea4977c5efad9cd8447e7beb6d8db217b8951d60604430678921a32aa` |
| External evidence | `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-034` |

Three TDD slices: no-secret-output private config/key/fingerprint preflight; consistent SQLite/WAL plus matching-key backup/restore and runnable isolated drill; local TLS/host/redirect/contract smoke. No existing user DB/keys, source business changes, production provider/deployment or App enablement. Author does not advance permanent branches, push or archive.

Slice1: actual red3 -> green3, private permission/owner/symlink/key/config checks reuse unchanged authorityConfig and read-only SQLite fingerprint/integrity. Slice2: red4 -> green4; actual child SIGKILL before manifest publication and drill-import regression then red -> fixed. Combined preflight/backup9/9. Online snapshot includes active WAL, matching keys, fsync/manifest-last publication and exclusive restore; actual HTTP six-control drill verifies old receipt bytes, one lock, next epoch, permanent032 fence,027 delete capability receipt and unavailable restored revoker.

Slice3: TLS missing-module red5; first green4/5 rejected wrong Host already at TLS identity, so the HTTP Host-specific test now sends valid local SNI while retaining certificate verification. Standalone TLS runner red1 then implemented; all15 operations cases pass. Full current backend round and exact post-commit input/result are external, with actual count only. Wrong CA/URL hostname/nonlocal URL/Host/version, redirects and timeout fail closed; local configured version tag is not a deployment attestation.

Ordinary root-authorized integration of verified GIT006 target71251f9afbb299e97344ff082c1d83bf17a110df preserved registered base225851d9. Its six governance files are inherited byte-for-byte target inputs, not author edits. No backend/src, native, engineering or other owned-scope changes. CLI/drill usage, private-key bundle custody and interruption limits are in backend/ops/README.md. Final author stops clean for root+m2 exact review; no permanent branch advance/push/archive.

Unverified: deployed storage/provider/certificate/host and key custody/rotation; real Apple/account/revocation/CloudKit/WC/Swift TLS and physical devices. Temporary development DB/keys/certificates are isolated, generated only by explicit test/drill fixtures. Physical devices do not apply to this local operations-only task.

Current final-combined round `034-final-combined-green.log` is a single143/143 (128 inherited +15 operations), exit0, zero failure/skip/cancel. Exact post-commit rerun and standalone finite restore/TLS output logs are separately captured after source/final freeze; no prior142 count is reused as current.
