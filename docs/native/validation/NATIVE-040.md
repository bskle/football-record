# NATIVE-040 验证

状态：TDD准备，暂无040新通过声明。

基线为 `7007d7b68167659da6a44e759126a39cd6af0b58`，与039初始 `de68f7f777b373c14363173a15fe9bcd6dddee5c` 全tree及327输入一致；复用原 AppIntegration28/0，不重复记为040运行。树外证据 `native-validation/NATIVE-040/baseline-check.json`。

将分别保留 typed API 编译红、实际行为红绿、完整 AppIntegration 单轮及 arm64 iOS17/watch10 sim/device 四项 SDK 日志、精确输入与 before/post 校验。用受控通道验证close/cancel/join；用真实本地 Node HTTP + SQLite 验证原 request、凭据隔离、未知响应和重开恢复。无实际 WC、Apple、HealthStore、Keychain 或账号调用；这些仍由026后验。

首轮 typed API 编译失败与最小 unavailable 外壳之后，4项实际运行6失败（1 unexpected）→4/0；生命周期8项实际12失败→8/0；独立 endpoint cancel迟到结果1项/1失败→最终同轮9/0。两次早期生命周期红灯的测试辅助器未结算迟到/关闭后错误复用，已仅终止本任务xctest并保留日志；可计数完整红为040-2-final-runtime-red.log，不将挂起当通过。原脚本曾使用zsh只读status变量，测试结果日志保留，后续改task专用run_code。

真实本地Node HTTP与双SQLite组合当前定向同轮14/0，含原body/submit/recover、Phone fresh PoP、Watch credential不进业务文件或Phone vault、已commit回复丢失后新relay沿原pending重开、404/401/timeout未知、TTL后可信knownAbandoned、真实identity fence晚到不安装凭据。该层是登记桥组合验收，完整相关host/四SDK仍待新运行。Node SQLite ExperimentalWarning据实保留，不称零诊断。
