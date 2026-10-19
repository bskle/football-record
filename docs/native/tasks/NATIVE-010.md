# NATIVE-010 M2设备集成候选

- 状态：本地候选源与可用自动检查完成；不依赖真机的候选交付与最终受影响验证完成，源码双审PASS；最终文档增量审阅待决，真实设备gate全部pending。
- 唯一作者：`/root/m2_recording_ui`；根质量审`/root`，规格审`/root/m2_review`。
- 创建base/目标dev：`2e1f9c42f4398a50b66765a0f37f90ced95a7554`。
- 已审008依赖：`6e86e8f1ac647b02b8f1ef407226a10398c5d998`；主代理普通合并后初始HEAD：`3a9d567362f4415146352acb706e586704c6f00c`。
- branch：`test/m2-device-integration`；tree：`/Users/liam/.codex/worktrees/m2-device-integration/20260830_足球记录`。
- attachment：`01a142e2-4bae-7c03-a534-17c404f82674`，createdAt `1792123489`；创建HEAD2e1及合依赖后HEAD3a9/clean已核。
- 所有权：Apps、FootballRecord.xcodeproj、Configuration、UITests、scripts/native、nativeREADME、本计划/卡/验证010、device-setup；不改Presentation/WorkoutCapture/Core/AGENTS/母计划/Git治理。
- [可执行子计划](../../superpowers/plans/2026-10-16-m2-device-integration.md)。
- 每App同一真实channel/factory/gateway；真实验收固定dataset及显式环境偏好，恢复只扫DB；纯UI模拟仍Unavailable，任何真实未决记录不能绕过切环境。
- 现有三个任务自有Simulator串行接手并保留，不改用户既有pair。
- 源码与文档分提交。用户暂不能连接真机；本地候选不得合入/push长期分支或归档。最终验收、真实能力门禁与集成由主代理负责。

## 先前来源（下节为最终同步）

- 计划e5120e1；源`4a90bc52e9d222ed351319681c6129a90f6c1cbe`；Phone说明窄修f3facc3、Simulator脚本窄修`93e17b8a9b6783cace81aec8a2e6f7a24bd24450`。
- 4a90实际204宿主、十SDK、双sim/双generic实际设备App无签名构建通过；Watch3项UI绿。Phone2项UI绿、真实模式unsigned环境崩溃；同源正常Xcode ad-hoc定点绿，详见[验证记录](../validation/NATIVE-010.md)。
- 最新目标dev `7ae65db8f662c4afcdd053f63da6462bbed57262`是纯治理更新，不改写创建base或产品接口；最终由主代理普通同步。
- [设备准备指南](../device-setup.md)明确真实模式会写健康、模拟锁及ended-held限制。源码P2回读修复由独立NATIVE012负责，010不改Presentation。

## 最终同步来源

- 主代理普通同步已验证dev `505449279d6461436a051b5e6bc43324d805e3e0`，最终冻结source `834cac56522d88f7b11adf2c1cb98be1e3a5fca6`；两名非作者对此source均PASS。创建base2e1、初始组合3a9保留，GIT003仅治理，不伪称接口升级。
- 本轮只复验Presentation22+Integration6、两sim/两device App及每端新增3UI；未变化Core/Store/Session144、Workout40沿用4a90，累计212并非单轮全跑。最终数据/路径见[验证记录](../validation/NATIVE-010.md)。
- 设备指南及本地候选保留；真实写入/授权/签名/安装/后台/锁屏/恢复/朗读/触觉全部pending，不入长期分支。

最终834受影响28宿主、两sim/两generic device Apps、Watch3及iPhone3实际UI全部exit0。105冻结输入执行前后无变；本地源码/证据/指南交主代理，最终docs审阅不预写成功，作者停止写入及Simulator操作。
