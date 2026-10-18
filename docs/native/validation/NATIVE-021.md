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
