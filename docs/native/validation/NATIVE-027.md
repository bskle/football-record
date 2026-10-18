# NATIVE-027 validation

Registered base/target: `03dbd35bd467a4a7334e2d1acf561af575935a86`. Initial clean/head/branch verified. Six Git inputs and runtime versions captured externally. Development RSA/P256 keys are generated only in test memory or private temporary files. No real Apple token/revoke/JWKS requests, accounts or private configuration are used.

No passing result claimed yet; red/green and exact-source evidence will be appended after execution. Physical devices not applicable to this isolated backend adapter; actual Apple account/config/network/revocation/deployment remains a separate 026 gate.

Slice 1: `node --test backend/test/apple-revoker.test.mjs` observed 25 missing-adapter failures before implementation; then 25/25 pass. A constructor/identity brand isolation check was added; its initial fixture interception ordering was corrected, preserving that failed output separately. `node --test backend/test/*.test.mjs` final slice round: 82/82 (old 56 + 26 adapter cases), Node v22.23.1 with SQLite ExperimentalWarning.

Actual loopback HTTP fixture generates RSA/P256 keys in memory, verifies genuine raw64 ES256 client JWT claims/forms, and returns genuine RS256 exchanged ID tokens. Wrong issuer/subject/audience/nonce/exp/iat/kid/signature/algorithm, missing id_token/refresh_token, access-only, nested/duplicate/oversized exchange responses never reach revoke. Exchange/revoke status/timeout/disconnect never blindly replay code; redirect not followed, optional original configured redirect exact, and 200 empty revoke succeeds. Production constructor/verified context rejects development/untagged bypass before any Apple network call. No real Apple API/JWKS request.
