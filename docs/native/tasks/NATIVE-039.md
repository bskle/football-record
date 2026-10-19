# NATIVE-039：保留原事实的 Health 删除桥

状态：本机软件实现和 source 双审完成，作者停写候选；final 两卡待同 HEAD 双审。仅 held NATIVE-026，不晋级 dev/release/main，不代表真实 Health 删除或026整包验收。

作者 `/root/m4_cloud`，非作者审阅 root + m2。原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，普通合入稳定026-1 `40417c61058d7653737ceb23b821f11ba75e53c8` 得到初始 `de68f7f777b373c14363173a15fe9bcd6dddee5c`。树 `/Users/liam/.codex/worktrees/m4-health-deletion-bridge/20260830_足球记录`，branch `feat/m4-health-deletion-bridge`，attachment `01a1562d-61b6-73e0-82eb-4d6e8749cfa1`，createdAt `1792447177`。登记目标为 held026 `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55`；未消费其后 catalog WIP。作者不 merge/push/archive。

三个实现提交为 `55da49122ac44c04df0b3b97b9d742ec2740b86b`、`5a74d88162bb9df0c988bcd7f378424c6510aad7`、source `9b6de569d53ff6ebcf0292a2c1041e6fec29e68a`。root 与 m2 的 exact source 审均 PASS，限独立本机桥。final 仅本卡与验证卡，产品、测试与[具体计划](../../superpowers/plans/2026-10-20-m4-health-deletion-bridge.md)保持 source 原 bytes。

已交付 `M4HealthRawReservation`、`M4HealthPreparedMapping`、`M4HealthFullSeal`、`M4HealthMappingStore` 和实现既有 AccountKit callback 的 actor。原始完整 capture facts、来源证据、选择和时间先 reserve；真实 retained saga 的实际 digest 绑定稳定 version8 UUID，prepared 持久读回后复用028 submit/confirm/entry。prepare 不等待全 seal。执行 callback 的旧参数 confirmationID 必须传原 parentID；它核 backendDeleted/receipt、原 scope/choices、mapping/full seal 和真实028原 entry，仅匹配成功 receipt 返回。

原 token 来自 CaptureOperation.externalToken 与 linked observation/segment 的真实 join，不剥 segment ID，不推测 Phone/Watch source。合法 Core recover/restart gap 与旧 sibling 保留；来源缺失、映射冲突、未覆盖 unknown、空选择、跨 source 或超过256明确失败，不截断。wrapper 保守阻止 executing/awaitingOutcome/interrupted 或 outcomeUnknown 自动重派；已知权限/driver终态可沿原 request 明确重试。count0仅表示该本地精确范围无匹配，不替其他删除组完成。

完整 AppIntegration 实际单轮 **53/0**（同轮原28+新25），四项最低 iOS17/watch10 sim/device 产品编译通过，输入前后零差异；详见[验证卡](../validation/NATIVE-039.md)。源码与最终 SHA、原始日志、工具/输入/evidence hashes 和审阅均树外记录于 `native-validation/NATIVE-039`。

默认 mapping 与 driver 均 unavailable；source origin 的 fixture/平台模式明确。test-only file-backed SQLite mapping 仅证明桥的保留/重开契约，不是生产026 catalog。026仍须实现真实 retained mapping/full seal适配，冻结全部原事实并读回完整 seal 后才允许任何 resume，保留 parent saga/capability/028 selection，并聚合全 owned local catalog。真实来源/权限/HealthStore/账号/设备及全设备删除未执行，M4未完成。
