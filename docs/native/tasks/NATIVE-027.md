# NATIVE-027 Server Apple revocation adapter

Status: registered and started; no real Apple requests or configuration acceptance.

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

Slices: actual loopback forms/signatures/identity validation; actual reference HTTP/file SQLite lifecycle faults; privacy and complete old/new regression. Tests first, observed red before implementation, explicit-path Conventional Commits. No long-branch advance/merge/push/archive by author.

Slice 1 completed: strict callable revoker/client-secret factories and in-memory verified Apple context extensions; full automatic round 82/82. Lifecycle material hook/recovery and final privacy evidence remain next; no completed production claim.
