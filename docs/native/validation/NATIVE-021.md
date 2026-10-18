# NATIVE-021 验证

输入base：`5e876cfd875585b315b57f91bcb8dc7160f8afa6`。正在开发，尚无通过结论。

原输出和六Git输入位于任务卡指定树外证据目录。真实Apple登录/撤销、部署及设备不属于本地参考后台自动验证证据，保持未验。未改native，设备构建不适用。

021.1：`node --test backend/test/locks.test.mjs` 红4失败（缺authority），绿4/4。两worker各建独立DatabaseSync，SharedArrayBuffer barrier后竞争同磁盘DB；一held一originalMatch，锁ID一致，重开仅一锁。覆盖beforeCommit rollback、afterCommitResponseLost、原bytes重开、同ID异payload、旧终结不碰新锁、时钟不解锁。SQLite ExperimentalWarning保留。fixture直调仅为本slice事务测试；HTTP及严格鉴权仍待021.2/4。

021.1初始化修复：真实两worker不同key首次启动；自然40轮未重现，test worker首次metadata持久化前延迟40ms后第2轮重现两配置均accepted。fingerprint比较/登记移入同初始化BEGIN IMMEDIATE后40轮仅一个accepted，5/5通过，独立提交d6de05d。

021.2：鉴权红16失败（缺verifier/device-auth/公开向量），补Apple签发时间红1失败后修复，最终 `node --test backend/test/auth.test.mjs backend/test/locks.test.mjs` 单轮25/25（20 auth + 5 locks）。覆盖严格RS256/JWKS/issuer/aud/nonce/exp/iat/kid/alg/kty/use/伪签/挑战重放、同UUID不同key、JWT换key、PoP nonce/time/GET篡改和重开nonce、auth COMMIT丢响应原key新PoP重构同session/token且DB不存明文token/Apple字段、fresh reauth原Apple iat/300秒。

固定跨语言development公开向量：`backend/test/fixtures/receipt-v1.json`，含完整business intent/canonical、canonical body UTF8 bytes base64、签名域和完整signing bytes base64、raw32公钥与raw64签名；私钥只在生成进程内，已丢弃，非真实secret。真实Apple/JWKS联网/撤销未验。

021.3: Initial lifecycle/privacy red: 7 failed. Challenge/delete CAS regression red: 3 failed. Delete isolation red: 1 failed. Migration re-registration red: 1 failed. Final `node --test backend/test/*.test.mjs`: 41/41 (21 auth + 13 lifecycle + 2 privacy + 5 locks). Logs retain each command output and SQLite ExperimentalWarning.

Normal migration: each transaction fails before COMMIT, loses response after COMMIT, closes/reopens and returns the first receipt. Seven-day server time persists across retries/reopen/clock rollback; 604799 rejects, 604800 requires fresh Apple-issued proof. Narrow lost grant releases only original recorder/lock as abnormal before a separate fresh reauthentication can force a global new epoch. Stable cloudSpace identity persists. Post-migration old phone fresh same-key login becomes waiting at current epoch, same-key Watch explicit re-registration can start, old Watch session is rejected, Watch cannot authenticate as a phone.

Delete: each stage fault/reopen, default revocation Unavailable, transient code loss/failure requires fresh same-account/device/key proof bound to original pending saga; original delete request/digest stays fixed. External await returns through exact epoch/pending request/digest/proof CAS. Pending delete blocks new starts. Associated identity/device/challenge/gift/session data are removed; capability-only recovery works after backend COMMIT response loss, expires after 30 days, and same-Apple re-registration gets a new global epoch. Cloud/local remain client-managed and HealthKit needs separate confirmation.

Analytics: strict allowlist, default disabled queue and backend, disable drops unsent optional metrics, no timer/heartbeat, stable request dedup, daily DAU/WAU/MAU. Forbidden/nested/oversized values do not persist. Real HTTP/log privacy is verified next in 021.4. Real Apple/revocation/deployment/devices remain unverified.

## Final coherent software input

Pre-source `node --test backend/test/*.test.mjs` in `pre-source-full-suite.log`: **56 tests, 56 pass, 0 fail**, 2026-10-19 Shanghai. Actual runtime `runtime-versions.log`: Node v22.23.1, SQLite 3.51.3. The source commit is followed by the same full command in `source-full-suite.log`; its exact SHA, all changed Git-file hashes and all raw evidence hashes are in external `source-manifest.json`. This card does not predeclare review/merge approval.

| Area | Evidence | Actual result |
|---|---|---|
| 021.1 lock transactions | 021.1-red.log / 021.1-green.log | Missing authority red; initial 4/4 green |
| First-use key race | key-race-red-reproduced.log / key-race-green.log | Two accepted configurations reproduced; transaction fix, 40 file-DB races and 5/5 tests green |
| 021.2 JWT/PoP/auth recovery | 021.2-red.log / 021.2-final-green.log | 16 initial failures, Apple iat regression red, then 25/25 auth+locks |
| 021.3 lifecycle/privacy | 021.3-red.log / 021.3-reregister-green.log | Initial 7 red; durable steps and same-key migration re-registration; then 41/41 full round |
| Challenge and delete await CAS | challenge-delete-red.log / 021.3-full-green.log | Three explicit red regressions, then 35/35 at that input |
| S21-pre1/pre2 | S21-pre1-pre2-red.log / S21-pre1-pre2-full-green.log | Four explicit red regressions; 52/52 after persistent mutual exclusion and requestID reservation |
| Actual HTTP boundary | 021.4-red.log / normal-recorder-green.log | Seven initial missing-HTTP failures; strict codec, role/status codes, real sockets and 10/10 HTTP/CLI final scope |
| Public peer / status roles | peer-status-red.log / peer-status-green.log | Stable grantID refresh and recorder-only live status, red then 9/9 at that input |
| Recorder normal release | normal-recorder-red.log / normal-recorder-green.log | Phone's own PoP improperly accepted Watch normal release red; original-recorder enforcement, 10/10 HTTP green |
| CLI manual smoke | cli-smoke.log | node backend/src/server.mjs actually starts at 127.0.0.1:49387, same keys/DB reopen at :49389, 404 smoke and clean shutdown twice |
| Fixture contract | fixture-http-red.log / fixture-http-final-green.log | baseURL missing red, then real HTTP/PoP client plus full 54/54 at that input |
| Metric aggregates | analytics-summary-red.log / analytics-summary-green.log | Missing aggregates red; 3/3 privacy/analytics green |
| Two worker identifiers | worker-metadata-red.log / pre-source-full-suite.log | Capturing exited thread -1 red; creation-time IDs [1,2], one held/one originalMatch on identical file |

Totals above belong to their exact input layers, not cumulative test runs. Final 56 = 21 auth + 10 HTTP/CLI + 17 lifecycle + 5 locks/config + 3 privacy/analytics. Replayed receipts remain byte-identical; new status proofs have independent nonce/time/domain. Normal/forced activation disconnect tests recover with original IDs, knownRevoked old auth, genuine new same-key challenge/login and GET; no SQL-filled context is used for that wire evidence.

All HTTP forbidden/duplicate/nested/oversized payloads produce bounded public errors, and captured logs/DB contain no supplied business/health/Apple sentinel. Tokens/JWT/code/capability secrets never enter committed fixtures. The public interoperability vector includes exact canonical intent/body/signing UTF-8 bytes and raw Ed25519 public key/signature.

True Apple login/revocation, private CloudKit read/save, production deployment/TLS/storage/backup, accounts and devices remain **not tested**. Development RSA/JWKS/revoker fixtures and two local workers do not establish those outcomes. Device verification is not applicable to this backend-only source delta; future 024/026 physical gates remain. Formal review, merge and lifecycle statuses are recorded by the main agent externally after they actually occur.
