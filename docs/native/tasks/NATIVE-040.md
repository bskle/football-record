# NATIVE-040：Watch 登记类型化中继

状态：实现中，held 026；尚未新运行测试或 SDK 编译。

作者 `/root/m2_review`；非作者审阅 root + cloud。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，稳定026-1依赖普通 merge 后初始 `7007d7b68167659da6a44e759126a39cd6af0b58`。树 `/Users/liam/.codex/worktrees/m4-watch-registration-relay/20260830_足球记录`，branch `feat/m4-watch-registration-relay`，attachment `01a1563d-003f-7251-97cd-2a18776a3513`，createdAt1792448200。目标仅 held026当时 `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55`；不推进长期分支。

[实施计划](../../superpowers/plans/2026-10-20-m4-watch-registration-relay.md) 限定 source/new test/本卡/验证卡/计划五路径；只提供登记专用 typed transport 与原 AccountKit 代理，不改工程或公共模块。要求原 body/ID/action、Phone fresh PoP、关闭取消/join/迟到 fencing、原 pending 重开。来源于327输入完全一致的28/0基线；这是既有基线复用，不是040新测试。后续实际结果见[验证卡](../validation/NATIVE-040.md)。

默认 unavailable，无真实 WC/Apple/Keychain/账号/设备操作。开发软件候选和 SDK 编译不代表026整包或真实门槛完成；作者不 merge/push/archive。
