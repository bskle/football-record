# NATIVE-018 M3 设备整包

状态：本机可审整包完成，待真机；不合入 dev / release / main。沿用已批准 [M3§9](2026-10-16-native-m3.md)，未重新产品发现。

唯一作者 `/root/m3_ui`；branch `test/m3-device-integration`；worktree `/Users/liam/.codex/worktrees/m3-device-integration/20260830_足球记录`；attachment `01a14404-45b0-7cc0-b241-9050c15c9abc`；createdAt `1792142493`。初始 base / 审阅目标 dev `b0070c90d91bf9d7741b7a7ed24165f1ad27383d`，创建 HEAD / clean 已核。

依赖与冻结边界：

- root 普通合016 final `001f9a3bff46856fa7845c4243603f131f26f5bf`，actual `e0d2fb909f1c2c65566210ccef4fe33e36149b52`。
- root 普通合010 final `cdbafb7822ca2371a3d1eaa6da8b95e54da78f2f`，actual `be73b55e9c7d00cbdaefdebb518a4d30deee218a`。五冲突只作保存性处理，暂态未当可运行候选。
- 018 docs 检查点 `b1eeba736653c50707cb71638a7580b46f983b79`，产品/测试检查点 `7215bf5d2207395e21cda9eff621ba45515e5ae7`；首次全量被继承的 WorkoutCapture 测试替身协议缺失阻断，作者未越权改模块。
- root 普通合独立019 final `6ddb28fc7234edc5478fe422c20d574ce372a970`，actual / 最终源码 `72846583e503349d117dac84e42fde746d384fee`。只增加16行测试转发和019三docs，App/runtime输入不变。root质量与m2规格双审 PASS，绑定此源码与上述dev目标。

- [x] 同facade/具体Session、唯一events订阅与start/retry并发门闩红绿；实际包继续位于 Apps/iOS/Integration。
- [x] 公开AppComposition装配真实WorkoutGateway、DeviceSync/MatchSync与状态model；先events后start，真实激活与普通wake分离，失效先撤权再stop/join；传输初始化故障不阻断本机恢复/合法提交。
- [x] 停旧model/指标/observer并关闭facade、释放context，再创建新环境；不缓存shutdown模型，gate复用active facade，离线扫描短开短关。
- [x] Debug双方持久UUID与显式account/pair/epoch配置；每次复验本机原身份/配置与持久失效记录，不从SDK/来包猜身份，不删数据/换epoch绕过。生产trust/permit仍unavailable。
- [x] 保留RecoveryInbox/metrics、017状态UI、010 ad-hoc Simulator签名和非空测试过滤；actual728一次全量331/0、14最低SDK、2sim App，另2genericdevice unsigned App与双端分层UI；[验证记录](../../native/validation/NATIVE-018.md)含精确输入和限制。
- [x] device-setup、README及018三docs与树外Gitblob/hash/log/xcresult/截图证据。
- [ ] 签名安装、授权、GPS、后台/锁屏/系统恢复、真实双端WC、真人VoiceOver/触觉与最低OS运行，待本人设备方便时另验。
- [ ] 物理门槛完成后重新双审/实际merge复验，root才决定长期分支接收。008/010/016/018树与分支保持；019已由root实际安全归档并以branch -d删除。

共享工程配置仅此作者串行持有；未手改Core/Presentation/WorkoutCapture/DeviceSync/AGENTS/母计划/合同。测试-only依赖019由独立作者/树/双审接收。没有发布、推送018或正式后台E2E通过声明。
