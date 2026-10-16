# NATIVE-017 同步状态 UI 与工程装配

状态：作者本机交付完成、源双审 PASS；最终文档审阅与实际合并复验由主代理执行。

- 唯一作者 `/root/m3_ui`；临时分支 `feat/native-sync-status`。
- base / 登记目标 dev：`a5d70759b1ff7c67b92f2082244fd189c119418d`；创建后实际 HEAD 相同且干净。
- worktree `/Users/liam/.codex/worktrees/native-sync-status/20260830_足球记录`；attachment `01a143d6-081f-73b2-90e3-b3b70c3d1380`；createdAt `1792139462`。
- 源提交 `1790722ac99c9346f6279715161349103cde69af`，17 路径。主代理质量审阅与 `/root/m2_review` 规格审阅均绑定该源 / 上述目标并 PASS；作者自验不替代双审。
- 独占范围为 Presentation、双端 Apps、Xcode/配置/UI tests、native scripts/README 及自己的三篇文档；未修改 Core、DeviceSync、WorkoutCapture、AGENTS、母计划或主合同。

实现同 facade 的公开 `AppBootstrap.composition`、真实 MatchSync product 工程装配、typed state/unavailable 状态 UI、可取消的独立同步启动及订阅。生产信任/许可维持 unavailable。Debug 协议演练使用两个隔离 SQLite 和稳定 identity，持续标示开发模拟锁/开发配对；旧 `other-device` 仍只算同库只读场景。

[小计划](../../superpowers/plans/2026-10-16-native-sync-status.md)与[验证记录](../validation/NATIVE-017.md)列出真实分层证据：完整 251/8 SDK/2 App；最后取消守卫增量 39 Presentation/2 SDK/2 App；iOS9、Watch9、375pt dark/max1 各有源范围。不能将其写为一次最终252或一次最终19项UI。

无新设备能力，无本人协助要求。签名/安装、真实 WatchConnectivity、最低系统运行、真人 VoiceOver 与触觉延期保留。普通结束仍 endedPendingSync，ACK 不完成比赛、不释放后台锁；云/后台尚未接通。

作者未合并、推送、归档或删除分支；最后文档提交后停写，Apps/工程配置唯一作者交接给018。root按既有治理完成 `--no-ff`、实际 merge 复验、授权推送和安全归档；main/release 不晋级。
