# NATIVE-053：原当前认证证据只读快照

状态：具体计划已准备，等待 root 与 NATIVE-026 消费者两位非作者预审；未开始产品/测试实现。

- 唯一作者 `/root/m4_auth_evidence`，审阅 `/root`、`/root/m4_integration_resume`。
- base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；分支 `feat/m4-current-auth-evidence`；工作树 `/Users/liam/.codex/worktrees/m4-current-auth-evidence/20260830_足球记录`；attachment `01a1613d-2c64-7f30-a713-87f2f531ad4e`，初始 HEAD/base/branch/clean 已核。
- 目标仅 held NATIVE-026，登记目标 `885f226adf87866854c987fb6ffb4b2e818bb9a4`，实际 merge target 由 root 后续核对。
- 六个独占新路径及 API/事务/证明边界见[具体计划](../../superpowers/plans/2026-10-22-m4-current-auth-evidence.md)。原 facade 在 MatchSession 模块，root 已登记第六路径 extension-only forwarding；不改旧业务 gate、required protocol、schema、工程、052 路径或认证写入。

通过同原 SQLite 只读快照复验 current binding、有效 generation、auth-current、原 attempt/admission 与固定 trust signed receipt，返回不可公开构造的证据值。它不刷新凭据、不放开录制，不用历史 auth receipt 补造后来 suspended/Watch/migration 状态。device/key/cloud 与原本地 accepted attempt 关联，不声称原 receipt 有其不存在的独立 signed claims。

[验证记录](../validation/NATIVE-053.md)当前仅 plan-only 检查；未运行产品、SDK/App/UI 或真实服务。源码及最终双审前不被 026 消费，不推进任何永久分支。root 负责最终合并/复验与安全清理，活跃依赖存在时保留树。
