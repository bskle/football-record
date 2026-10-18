# NATIVE-025：账号与生命周期装配 / UI

状态：本机软件源码双审 PASS，作者交付并停写；最终文档审阅、实际合并与复验由主代理完成。真实服务及设备验收仍待026。

- 作者 `/root/m3_ui`；非作者审阅 `/root`（质量）、`/root/m2_review`（规格）。
- 分支 `feat/m4-account-ui`；独占工作树 `/Users/liam/.codex/worktrees/m4-account-ui/20260830_足球记录`；attachment `01a150ae-0403-7f50-8f43-34c357b44a8d`，createdAt `1792354944`，创建时 clean。
- 初始 base `17f2e39adcdbc633682992d5e5e2f348dbc940e6`；已审023 final `f7f7a3bceb3000fd6d655d4724089601870eeb4d` 的普通依赖 merge `ba01e83c861f2daa7d0733258097da13390243c6`。后续普通同步已验证 dev，最终目标 `fcf530ada01a7cbf87bbfde598f611d8a35705b2`。
- 冻结 source `4ec78e879cd8a7cef981540bdeebac39e5e82b95`；产品 / 宿主输入在 `68cc384d74caa75dac1105969427ed8e214c9c01` 后未变，仅 UITest helper / 查询分层修正。

按[实施计划](../../superpowers/plans/2026-10-19-m4-account-lifecycle-ui.md)交付同一 SQLite facade / 原 MatchSession 的账号、迁移、删除四组与默认关闭统计 UI。Debug 通过 Mac 监督原 Node HTTP fixture、私有 typed mailbox 和已登记文件云台账演练；身份、原 key / pin、未知请求和持久重开均保持失败关闭。普通结束须云完整 proof 与后台正常释放同时满足；peer ACK 不释放后台锁。身份变化后旧 RecordingModel 保持不可录制，必须使用已有重新载入入口先关闭旧 context。

正式所有权为39精确路径；实际 source 相对目标改29路径，最终只另改本 task、validation 与实施 plan。唯一工程作者未写预留 entitlements，未改 SDK / Core / backend / verify.sh，未合入024候选。配置责任见[交接清单](../../../native/Configuration/M4-capability-handoff.md)。

615 宿主、12最低 SDK 产品、4个模拟器 App、2个设备 SDK 无签名 App及各轮 UI均已实际通过，输入层次与限制见[验证记录](../validation/NATIVE-025.md)，不合称最终 source 同一轮全包。root 与 m2 对 exact source / 目标正式 PASS；最终3docs增量另审。

作者提交后 clean 停写，移交共享工程与模拟器操作权，不再启动测试 / fixture。主代理负责 no-ff 合并、实际 merge 当前账号 UI 复验、同步与后续归档 / 安全删支；作者未推进永久分支、推送或清理。生产 providers 仍 unavailable，签名、真实 Apple / CloudKit / WatchConnectivity / Health、本人设备、真人 VoiceOver / 触觉及最低系统 runtime 均保持026门槛。
