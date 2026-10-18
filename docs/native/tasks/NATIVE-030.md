# NATIVE-030 Peer grant role proof

Status: automatic implementation complete; source/final exact review and both non-author approvals pending.

| Field | Registration |
|---|---|
| Sole author | /root/m4_authority |
| Coordinator / reviewers | /root / root + m2 non-authors |
| base_ref / full base | dev / `d59768f5f5d7872b9c520fd746d20f99f236acdc` |
| Merge target / registered target | dev / `d59768f5f5d7872b9c520fd746d20f99f236acdc` |
| Branch | `fix/m4-peer-grant-roles` |
| Attachment / createdAt | `01a15011-01e7-7e71-bc90-aacb03cc33c6` / `1792344654` |
| Worktree | `/Users/liam/.codex/worktrees/m4-peer-grant-roles/20260830_足球记录` |
| Actual initial HEAD / status | `d59768f5f5d7872b9c520fd746d20f99f236acdc` / clean, branch verified |
| Ownership | focused `backend/**`, contract section 6, this card and `docs/native/validation/NATIVE-030.md` |
| Read-only | Core / AccountKit / CloudSync / Apps / project / AGENTS / other plans and docs |
| Dependency | 027 actual merge verified; 023 waits for reviewed 030 integration before consuming role proof |
| External evidence | `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-030` |

Approved narrow repair: backend-signed peerGrant adds mandatory localRole, remoteRole, activePhoneID from same-account/current-epoch database facts. Only active phone + registered Watch may form a new grant, in either endpoint order; the active phone remains caller. No request field/PoP/domain/v2 byte/schema changes. Existing receipts replay original bytes, including missing-role or invalid historical pairs; explicit new control request may renew only a valid pair under the same pair/grant ID. No App/bootstrap enablement.

Tests precede implementation: actual loopback HTTP challenge/auth/Watch registration, genuine receipt signatures/tampering, role/caller/account/epoch/key rejection, old database receipt replay/renewal and exact original bytes after reopen. Complete backend regression and source/evidence manifest follow. Author does not advance dev, merge/push/archive/cleanup. No real Apple/WC/CloudKit/device request or service deployment is performed.

Runtime-first result: `030-red.log` records 14 tests, five pass/nine fail before implementation. Minimal peerGrant transaction fix and nested three fields pass 14/14 in `030-green.log`. Complete single backend round is 114/114 (100 inherited + 14 new), exit 0, zero skipped/cancelled; SQLite ExperimentalWarning retained.

Coverage uses actual challenge/auth/Watch HTTP registration, both pair directions with genuine Ed25519 receipt signature and tamper rejection, unknown request fields, invalid role/caller/account/epoch/key combinations, rollback/COMMIT disconnect, reopen, immutable original request bytes and explicit same-grant renewal. Genuine old missing-role and Watch-Watch receipts are seeded as old database snapshots; old receipts stay byte-for-byte signed history and invalid historical pairs cannot renew. Core production-context rejection is specified by the contract and remains 023 ownership; this task does not claim its implementation or physical behavior.

Final exact commit inputs and source/evidence manifest are captured externally after freeze; card does not predeclare root/m2 review PASS or actual merge/push/archive. Author stops clean, without advancing long-lived branches. No Apple/WC/CloudKit/device/network deployment gate is claimed.
