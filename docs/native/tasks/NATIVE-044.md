# NATIVE-044 云擦除重放 current-zero

状态：source `961c95d0232fa515b9b3120de25d275e0757b36d` 已 root+m2 两位非作者 exact PASS_SOURCE_HELD_026_ONLY；final 仅两卡收尾，clean 停写后交同 HEAD 窄审。候选供026，作者不 merge / push / archive。

- 原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；登记 held026 target `3a2a26360a822ed58b886c502acf038b028dfba9`。实际接收 target 由 root 核验。
- 分支 `fix/m4-cloud-erasure-replay`；树 `/Users/liam/.codex/worktrees/m4-cloud-erasure-replay/20260830_足球记录`；attachment `01a15725-5eb1-7500-856e-9cf5bdb70f24`。初始 HEAD / branch / clean 含 ignored 已核。
- 作者 cloud；非作者 root、m2。仅登记五路径；source 产品、测试与[计划](../../superpowers/plans/2026-10-20-m4-cloud-erasure-replay.md)在 final 保持原 bytes。

原 receipt/fence 只证明历史操作。重放须在同一事务先核原 v4 精确布局，再严格验证全部 canonical 库存及目标 stable zone 所有 epoch 当前为零。恢复目标行、坏/未知归属及新表/列/view/trigger/index 都保全阻断；未来版本为 unsupportedSchema。已知布局下同 ID 异意图仍 identityConflict；匹配重放不重删、不改 first receipt、不解 fence，其他合法账号/空间/zone 原 bytes 保留。不改 schema、通用协议、DTO/canonical/hash域、SDK、Package 或026检查器。

实际 TDD：最初6项/17失败 →四行 current-zero 修复6/0；随后 live-layout 详细 probe 1项/4失败 →全部定向7/0。最终 source 同一完整 Cloud 命令 **87/0**（原80+新7），四项 fresh 最低 iOS17/watch10 sim/device CloudSync 产品全 exit0；每五命令239输入 before/post0。旧67a的86/0+四SDK及原20证据不覆写，详见[验证卡](../validation/NATIVE-044.md)。

新 source manifest 位于树外 `native-validation/NATIVE-044/S44-layout/source-aggregate-manifest.json`，SHA256 `e6ad4f69ad4f1b08287c1d25ab9f3db48f0143d8793b2ff74261fdde7ca58c13`。final 仍待独立窄审，不预填合并/验收。此为单 Cloud ledger 本机查询修复；没有真实 CloudKit、账号、设备动作，不证明026全部 owned / staging / Store / fullseal / native 完成或M4发布。
