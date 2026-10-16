# NATIVE-018 M3 设备整包

依据已批准M3§9。唯一作者 `/root/m3_ui`；branch `test/m3-device-integration`；worktree `/Users/liam/.codex/worktrees/m3-device-integration/20260830_足球记录`；attachment `01a14404-45b0-7cc0-b241-9050c15c9abc`；createdAt1792142493。初始base/目标dev `b0070c90d91bf9d7741b7a7ed24165f1ad27383d`，创建HEAD/clean已核。root先合016 final001f9a3为e0d2fb909f1c2c65566210ccef4fe33e36149b52，再合010 finalcdbafb7为be73b55e9c7d00cbdaefdebb518a4d30deee218a；五冲突只作保存性解冲突，暂态不算可运行/已通过。

- [x] 先写同facade、唯一events订阅、activation/wake/失效与停旧红测；复用Apps/iOS/Integration实际包。
- [x] 用公开AppComposition同repo/Session构建真实WorkoutGateway、DeviceSync/MatchSync与状态model。停旧model/observer/metrics并join，关闭旧repo、释放driver，不复用shutdown缓存model；安全门复用active facade。
- [x] Debug显式配置双方持久UUID、development account/pair/epoch。缺失/不符/失效provider unavailable，不从SDK或来包推导身份；失效锁存保留，不清文件/换epoch。production trust/permit仍unavailable。
- [x] 恢复同一RecoveryInbox/Session、metrics；先events再服务start，activated才connectionDidActivate，wake不重置ACK预算。同步失败不挡合法本机记录。
- [ ] 保留010 ad-hoc Simulator签名与017状态UI/过滤，完整各host模块、最低SDK、双sim/双genericdevice unsigned App和适用双端UI，保存准确SHA/输入/日志/截图/xcresult。
- [ ] 更新device-setup与自己的任务/验证；源/final双审后留分支等待物理验收，不合长期分支、不推送/归档。

只写正式派工Apps/工程/配置/UI/scripts/nativeREADME/device-setup及本任务三docs，不改Core/Presentation/WorkoutCapture/DeviceSync/AGENTS/母计划/合同。共享工程只此作者；helper仅只读。真机签名安装/授权/GPS/后台/锁屏/恢复/真实WC与真人VoiceOver/触觉均延期，不标通过。


检查点（最终整包尚未完成）：Integration 18 / DeviceSync 21 宿主独立通过；首次完整 verify 已过 Core 213、Presentation 39、8 项最低 SDK 与 2 个 Simulator App，继承的 WorkoutCapture 测试 FaultRepository 缺 16 个 SyncRepository 转发而编译失败（exit1）。已交 root 独立 NATIVE-019；018作者未修改禁写模块。最终完整矩阵须接收019后重跑，预计数不当通过。

UI 为分层实证：iOS 首轮13项12过/1重复查询失败，firstMatch修正后新增环境往返1项通过；Watch 首轮13项12过/1旧滚动helper失败，实际失败视频末帧证实停在长页顶端，限定Watch XCTest小幅有界drag后新增1项通过（UUID实际可见、模式往返、fresh model可用）。产品源自首次矩阵输入保持不变；测试源delta与两轮xcresult分别保留。真机与最低OS运行仍未验。
