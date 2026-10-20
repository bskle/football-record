# NATIVE-047 Cloud erasure reopen

状态：实施中，未验收。作者cloud；非作者root/m2。依 [计划](../../superpowers/plans/2026-10-20-m4-cloud-erasure-reopen.md) 与 [验证卡](../validation/NATIVE-047.md) 执行。

base2cab、accepted044 final60a、effectiveBase `4cd9cc376e84318061d5aab447b59b94ded26db3` 与完整登记均见计划；分支fix/m4-cloud-erasure-reopen，held026而不合dev。六路径独占，无共享写入。HEAD/branch/clean含ignored已核，root已批准RO→existingRW及explicit expected-receipt replay-only API。

目标为已存v4无CREATE/迁移的erasure-only重开；原内部receipt/fence缺失时保全原target并拒绝，不能因外catalog deterministic firstbytes而重删。ordinary init/migration不变。真实RED/实现/完整Cloud和四最低SDK尚待实际执行，不以upstream026两tests反证当本任务通过。source/final SHA与review状态进树外registry，不回写自SHA。

无真实CloudKit/账号/设备，无whole026删除完成声明，不改receipt/schema/通用协议。
