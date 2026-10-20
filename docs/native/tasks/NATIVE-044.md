# NATIVE-044 云擦除重放 current-zero

状态：已登记独立树，按 [实施计划](../../superpowers/plans/2026-10-20-m4-cloud-erasure-replay.md) 开始 TDD。

作者 cloud；非作者 root、m2。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；held 026 target `3a2a26360a822ed58b886c502acf038b028dfba9`。分支 `fix/m4-cloud-erasure-replay`；attachment `01a15725-5eb1-7500-856e-9cf5bdb70f24`；实际初始 HEAD / branch / clean 含 ignored 已核。

仅在原 receipt + fence 重放前验证完整库存及目标跨 epoch 当前零。保留原 receipt、永久 fence、foreign 数据与坏行，不重新擦除。验证记录见 [验证卡](../validation/NATIVE-044.md)。不执行真实 SDK / 账号 / 设备，不宣称整个本地删除或 026 验收。
