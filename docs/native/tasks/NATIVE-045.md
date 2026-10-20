# NATIVE-045 — Store 当前零验证

状态：实施中，未合入长期分支。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；held026 target由root实际接收时核验。

作者 `/root/m2_review`；非作者审阅 root、cloud；分支 `fix/m4-store-erasure-validation`。树 `/Users/liam/.codex/worktrees/m4-store-erasure-validation/20260830_足球记录`，attachment `01a15726-2a59-7720-a2f7-4be66bb39fc4`，createdAt1792463481。

按[计划](../../superpowers/plans/2026-10-20-m4-store-erasure-validation.md)新增原Store同事务只读 current-zero witness，原 Saga/receipt/capability不变，不重新擦除，不增 generic protocol。所有权仅登记七路径；[验证卡](../validation/NATIVE-045.md)保留实际红绿和 SDK 限制。
