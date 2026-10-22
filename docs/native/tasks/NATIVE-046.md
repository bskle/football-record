# NATIVE-046 — 完整采集枚举

状态：source `5c6098ac119e8373aef323256c536f904f74c336` 已 root + cloud 两位非作者 exact PASS，held026；本次仅任务卡/验证卡收尾，final同HEAD窄审待完成。未合并/推送/归档，不入dev。

- 原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；已接045 final `acd5ab1717fc5eb979c1f13cba083c36c06a8c55`，effective base `c75c0c7442f0145142d49cd90db5ec81ecd0496c`。登记 held026 target `5d6a12eae41781fe76539ce7cfe9537f63b51cec`，后续接收由root核验。
- 作者 `/root/m2_review`；非作者审阅 root、cloud；分支 `fix/m4-capture-inventory`。树 `/Users/liam/.codex/worktrees/m4-capture-inventory/20260830_足球记录`，attachment `01a15755-6603-7271-97c3-b5a0245d6205`，createdAt1792466576，初始及source clean含ignored已核。
- [计划](../../superpowers/plans/2026-10-20-m4-capture-inventory.md)限定七路径，实际六路径变动；SQLite.swift仅复用045布局 helper，原文件未改。[验证卡](../validation/NATIVE-046.md)保留全部实际层次。

已交 `MatchStore.captureInventoryV4()` 与 concrete `SQLiteSessionRepository` 原连接转发，返回最小 Sendable、非Codable、internal-init投影。原 Store 单一无await SQL事务复用045布局、逐场canonical/history、原command/outbox校验，补全全局rawUTF8父集合/历史/五种registry闭包。所有状态/历史/异常/非当前UI和空intent均包括；未知/孤儿/损坏/任何blocking diagnostic明确throw，失败不写diagnostic、不修复/擦除或重建事实。

真实Session linked→删matches父的旧枚举遗漏已运行红；raw原intent/associated command Unicode等价串接也先红。最终同source完整Core单轮 **286/0**（44 Core +178 Store[163原+15新]+47 Session+17 Sync），两fresh最低iOS17/watch10 Session simSDK均exit0，三个命令240runtime输入before/post及Git全等。源码双审后只改两卡，原产品/测试/计划与69证据保持，不复跑或拼历史042计数。

无generic protocol/schema/迁移/decoder/Package/工程或SDK修改。026负责成功排空全部原写入者、比较原041raw及Health source/provenance；晚到linked必须挡first erase，已擦后沿原mapping+045当前零恢复，空inventory不能重建空选择。此点时只读投影不证明永久零、跨Store归属、实际Health删除或026/M4整包完成；真实账号/SDK/设备门槛保留。
