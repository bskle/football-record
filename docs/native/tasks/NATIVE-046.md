# NATIVE-046 — 完整采集枚举

状态：计划与 API/算法已获 root 窄审通过，实施/自动验证/source与final双审待完成；仅 held026，不合 dev。

- 原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；已接045 final `acd5ab1717fc5eb979c1f13cba083c36c06a8c55`，effective base `c75c0c7442f0145142d49cd90db5ec81ecd0496c`。登记 held026 target `5d6a12eae41781fe76539ce7cfe9537f63b51cec`，后续接收由root核验。
- 作者 `/root/m2_review`；非作者审阅 root、cloud；分支 `fix/m4-capture-inventory`。树 `/Users/liam/.codex/worktrees/m4-capture-inventory/20260830_足球记录`，attachment `01a15755-6603-7271-97c3-b5a0245d6205`，createdAt1792466576，初始独立核HEAD/branch/clean含ignored。
- [计划](../../superpowers/plans/2026-10-20-m4-capture-inventory.md)限定七路径；[验证卡](../validation/NATIVE-046.md)按真实层次收集。

新增同原 Store 单事务只读 capture inventory，补全未知 orphan 与 registry/history 闭包校验；所有状态及历史比赛均包括，blocking diagnostics 显式拒绝。无 generic protocol/schema/业务写/SDK/工程修改。026负责停写与原 retained Health 选择比较；此叶接口不等于026整包或实际 Health 删除完成。
