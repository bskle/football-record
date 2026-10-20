# NATIVE-043 Debug 协议客户端工厂

状态：source已root+m2两位非作者审阅PASS，held026；本次仅任务/验证卡收尾，final尚待精确窄审，未合并/推送。依据 [计划](../../superpowers/plans/2026-10-20-m4-debug-protocol-clients.md) 与 [验证卡](../validation/NATIVE-043.md)。

base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；登记held026 target `12cb0cfabc0619ddb07784603f313623c26aa080`；分支 `feat/m4-debug-protocol-clients`；attachment `01a1572e-7a79-74a1-b62d-77ed2d80922f`。作者cloud、非作者root+m2。初始及source HEAD/branch/clean含ignored已核。source固定 `83508a49e912dc1395b1f84a251b6e509e2c6227`；final自SHA/后续治理只记树外registry。

public DEBUG `protocolClients` 复用原 Apple/HTTP/Cloud/Watch 协议实现与邮箱，不创建 Runtime/AccountAppContext/Session/DB/identity/signer/vault/SDK。原make/fromPrivateFile/runtime去除新增段后逐bytes等base；Release和production默认Unavailable保持。

`drainState()`只读核本实例owned调用为空、原published root/四children dev/inode完整且当前库存为空；missing/replaced/symlink/unknown/pending保全返回undrained。026先gate业务入口再fresh检查，仍保留同clients/HTTP供原Saga恢复。final `close()`永久fence，只cancel/join本实例调用，拒迟到typed结果；不关闭别的客户端或清除共享内容，重复调用仍查当前库存。

新source完整Presentation单轮88/0（原74+新增14）、四fresh最低iOS17/watch10 Debug/Release模拟器产品、两Debug public consumer成功与两Release仅缺DEBUG类型预期负编译均已核。source v2 manifest与100证据、239runtime/9commands前后0差，原39e/87与红绿/辅助诊断分层保留；不把历史层相加。无真实账号/设备/SDK业务执行或026全部owned完成声明。
