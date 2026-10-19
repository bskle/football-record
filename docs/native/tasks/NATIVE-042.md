# NATIVE-042 — 会话与展示退役

- 状态：实施中；未合入长期分支。
- 基线：`2cab4640ee3a375da39fdabf0f5a317600b0c263`；目标：026 本地候选，非 dev 发布。
- 作者：`/root/m2_review`；审阅：root、cloud。
- 分支：`fix/m4-session-retirement`。
- 范围与步骤：[实施计划](../../superpowers/plans/2026-10-20-m4-session-retirement.md)。
- 交付：Model 同步停入口与异步排空清理、concrete Session 业务退役并保留原采集事实与 Saga 仓库；不新增通用默认 noop。
- 验证：[验证卡](../validation/NATIVE-042.md)。尚未声明本任务新测试或 SDK 通过；既有 74 Presentation / 257 Core 仅基线层。
