# NATIVE-021 验证

输入base：`5e876cfd875585b315b57f91bcb8dc7160f8afa6`。正在开发，尚无通过结论。

原输出和六Git输入位于任务卡指定树外证据目录。真实Apple登录/撤销、部署及设备不属于本地参考后台自动验证证据，保持未验。未改native，设备构建不适用。

021.1：`node --test backend/test/locks.test.mjs` 红4失败（缺authority），绿4/4。两worker各建独立DatabaseSync，SharedArrayBuffer barrier后竞争同磁盘DB；一held一originalMatch，锁ID一致，重开仅一锁。覆盖beforeCommit rollback、afterCommitResponseLost、原bytes重开、同ID异payload、旧终结不碰新锁、时钟不解锁。SQLite ExperimentalWarning保留。fixture直调仅为本slice事务测试；HTTP及严格鉴权仍待021.2/4。
