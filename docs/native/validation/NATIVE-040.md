# NATIVE-040 验证

状态：TDD准备，暂无040新通过声明。

基线为 `7007d7b68167659da6a44e759126a39cd6af0b58`，与039初始 `de68f7f777b373c14363173a15fe9bcd6dddee5c` 全tree及327输入一致；复用原 AppIntegration28/0，不重复记为040运行。树外证据 `native-validation/NATIVE-040/baseline-check.json`。

将分别保留 typed API 编译红、实际行为红绿、完整 AppIntegration 单轮及 arm64 iOS17/watch10 sim/device 四项 SDK 日志、精确输入与 before/post 校验。用受控通道验证close/cancel/join；用真实本地 Node HTTP + SQLite 验证原 request、凭据隔离、未知响应和重开恢复。无实际 WC、Apple、HealthStore、Keychain 或账号调用；这些仍由026后验。
