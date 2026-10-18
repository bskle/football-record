# NATIVE-027 Server Apple revocation adapter

Status: automatic software implementation complete, source/final pending exact-SHA non-author review. No real Apple requests or configuration acceptance.

| Field | Registration |
|---|---|
| Sole author | /root/m4_authority |
| Main / reviewers | /root; two exact-SHA non-authors pending |
| base_ref / complete base | dev / `03dbd35bd467a4a7334e2d1acf561af575935a86` |
| Target / registered target SHA | dev / `03dbd35bd467a4a7334e2d1acf561af575935a86` |
| Branch | `feat/m4-apple-revoker` |
| Attachment / createdAt | `01a14ff1-9fa0-7573-be4a-24149b9b9c37` / `1792342597` |
| Worktree | `/Users/liam/.codex/worktrees/m4-apple-revoker/20260830_足球记录` |
| Actual initial HEAD / status | `03dbd35bd467a4a7334e2d1acf561af575935a86` / clean, branch verified |
| Ownership | `backend/**`, this card, `docs/native/validation/NATIVE-027.md` |
| Read-only | Core / AccountKit / CloudSync / Apps / project / all other docs |
| Dependencies | 021 and GIT-005 reviewed/merged into registered base; 023 independent |
| External evidence | `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-027` |

Follow frozen [M4 plan section 12](../../superpowers/plans/2026-10-18-native-m4.md) and [contract 7.1](../contracts/m4-account-lock-cloud.md). Callable hook stays `appleRevoker({authorizationCode, expectedApple, reauthenticationID}) -> Promise<{revoked:true}>`. Only refresh_token revocation, no access fallback. HTTP DTO/SQLite schema remain unchanged. Default unavailable, no App enablement.

Slices: actual loopback forms/signatures/identity validation; actual reference HTTP/file SQLite lifecycle faults; privacy and complete old/new regression. Tests first, observed red before implementation, explicit-path Conventional Commits. No long-branch advance/merge/push/archive by author. Ordinary integration of root-authorized latest verified dev into this task branch preserves the original registration.

Slice 1 completed: strict callable revoker/client-secret factories and in-memory verified Apple context extensions; full automatic round 82/82. Lifecycle material hook/recovery and final privacy evidence remain next; no completed production claim.

Slice 2 completed: transient verified material binding/disposal and original-saga HTTP/SQLite recovery. Full round 92/92; original base is unchanged and latest verified dev will be ordinarily merged before final input freeze. Privacy sentinel scans and final evidence remain next.

Slice 3 completed: actual auth rollback/committed-response-loss recovery and DB/WAL/log/error/receipt privacy scans. Invalid NBSP exchange JSON was observed red and strict JSON whitespace fixed; complete backend round 95/95 (56 inherited + 27 adapter + 12 recovery), no skipped/cancelled cases. SQLite schema and HTTP DTO remain unchanged.

Root-authorized latest validated dev `204ea7a8c2b0d6f514fc6d4653aec9b6379a2a15` was ordinarily merged after slice 3. Its four CloudSync/029 files are inherited upstream changes; this author wrote only the registered backend and 027 cards. Original base remains `03dbd35bd467a4a7334e2d1acf561af575935a86`. Final source commit, six exact Git inputs, full new round and all source/evidence hashes are external to avoid a self-referential commit. Author stops clean for root + m2 review and does not advance dev, push, archive or clean up.

Remaining acceptance: actual Apple account/client/server-key configuration, Apple token/JWKS/revocation network, deployment/key custody/rotation, real CloudKit and physical devices are unverified. No App/production enablement is included. Future NATIVE-030 grant role signing is a separately assigned task and is not implemented here.
