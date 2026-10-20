# NATIVE-047 Cloud erasure reopen

状态：source已root+m2两位非作者审阅PASS，held026；本次仅任务/验证卡收尾，final仍待同HEAD窄审，未合并/推送。依 [计划](../../superpowers/plans/2026-10-20-m4-cloud-erasure-reopen.md) 与 [验证卡](../validation/NATIVE-047.md) 执行。

登记base `2cab4640ee3a375da39fdabf0f5a317600b0c263`、accepted044 final `60a1a7c37df3b49925534d0fcd5d6db6ea93c485`，root普通合入effectiveBase `4cd9cc376e84318061d5aab447b59b94ded26db3`。held026登记target `ae66e20581198ababe67cb87d73398ad49514d7b`；分支fix/m4-cloud-erasure-reopen，六路径独占。实际树/attachment见计划，初始与source HEAD/branch/clean含ignored已核。source固定 `bbf421b9783d04c1b099c0bbeff08fd821832f94`；final自SHA/后续治理进树外registry。

具体 `SQLiteCloudLedger(existingLocalErasureURL:fault:)` 先RO查原regular/no-symlink文件、exact当前v4/layout/canonical/control/WAL，再核原dev/inode并existingRW无CREATE重验，仅设connection synchronous FULL。没有CREATE、迁移或journal_mode赋值。private erasure-only mode在共同事务入口拒绝普通write；只允许专用first erase与expected原receipt replay。原normal init/migration保持。

`replayLocalTransportErasure(_:expectedReceipt:)`绑定原requestID UTF8、digest和stablezone；必须原内部receipt/fence存在且全inventory严格可归属、目标stablezone所有epoch当前零。缺proof、恢复target、malformed/unknown或错expected均保全并throw，绝不fresh erase/重造证明。026保留firstreceipt后必须选该replay-only路径；catalog ownership/全部ledger目录仍由026验收。

实际API编译红、旧行为委托10tests/26预期断言红→10/0，完整Cloud新source单轮97/0及四fresh最低iOS17/watch10 sim/device产品通过；240inputs逐命令before/post0。upstream026原2tests/6反证另存不计047通过。source双审/43原证据已核；final只两卡不重测。

只限单ledger本机控制软件；不改receipt/schema/digest或通用协议，不证明真实CloudKit/账号/设备、掉电或whole026全部owned删除，production默认Unavailable保持。
