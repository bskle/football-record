# NATIVE-036 Watch registration recovery

Status: implemented and author-validated; coherent final source awaits exact root+m2 review. Review/integration state is maintained in the external registry, never preclaimed here.

| Field | Registration |
|---|---|
| Sole author / coordinator | /root/m4_authority / root |
| Reviews | exact root+m2 pending |
| base_ref / full base / current target | dev / `75c3b0e833ea71c0e69c3c3b40e8c3c766074969` / same |
| Branch | `fix/m4-watch-registration-recovery` |
| Attachment / createdAt | `01a1507a-6c68-7910-ba13-27fbde44a28c` / `1792351562` |
| Worktree | `/Users/liam/.codex/worktrees/m4-watch-registration-recovery/20260830_足球记录` |
| Actual initial HEAD / status | `75c3b0e833ea71c0e69c3c3b40e8c3c766074969` / clean, branch verified |
| Write ownership | device-auth.mjs / codec.mjs; new watch-registration-recovery test and approved support; backend README, additive Watch wire contract and036 cards |
| Additive database permission | Not used: database.mjs and schema2 remain unchanged |
| Approved support path | `backend/test/support/watch-registration-recovery-worker.mjs` |
| Read-only | 023 tree/Core/AccountKit/native/engineering/long-lived branches and all other backend sources |
| External evidence | `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-036` |

An unsent first registration has no stored result. After its300-second challenge expires, GET404 and same-body POST401 establish no terminal state, leaving both client attempts unknown. The explicit authenticated recovery action keeps the original complete body/Watch proof and adds fresh Phone path PoP. Stored registration wins unchanged; validated missing-row recovery atomically signs/persists a closed result. First submit and recovery remain distinct typed actions through the relay;023 owns that client state transition.

The initial minimal requests-only closure failed a live-TTL deletion regression: deleting the account removed the request but not its unregistered Watch challenge, so a fresh same-anonymous-account activation could register the old body. The final implementation atomically pairs the request result with a permanent opaque Watch-domain HMAC bit in the existing schema2 fence table, without epoch in the tuple. It neither consumes a global challenge nor affects another account's request. Erased original result plus retained bit returns401, with no new-epoch signature. Root+m2 narrow design approvals are retained externally; they are not final code approvals.

Actual runtime evidence:14 initial failing HTTP tests,16 failing tests including deletion boundaries, then requests-only15pass/1fail reproducing the live-TTL deletion hole; final targeted16/16 and a full single backend round161/161 passed. Tests cover expired first submit, signed closure/tamper checks, original committed result/session, beforeCOMMIT rollback, COMMIT response loss, reopen, account/key/role/PoP/digest rejection, both race orders, independent same-file workers, schema/bytes preservation, deletion/new-epoch replay and cross-account challenge isolation.

No Apple/account/deployment/device request was made. This backend-only local software repair does not establish production service or physical-device acceptance. Root decides exact dual review, actual merge, synchronization and archival; the author does not advance permanent branches.
