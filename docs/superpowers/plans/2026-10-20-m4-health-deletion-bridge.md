# NATIVE-039 Health deletion bridge

> 执行依据：[M4](2026-10-18-native-m4.md)、[Git 治理](../../git-workflow.md)。root 已批准下面的具体 API 与边界，无新增产品审批。

## 登记

- 唯一作者 `/root/m4_cloud`；非作者审阅 root + m2。
- 原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；branch `feat/m4-health-deletion-bridge`；held 026 target `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55`，不入 dev/release/main。
- 受管树 `/Users/liam/.codex/worktrees/m4-health-deletion-bridge/20260830_足球记录`，attachment `01a1562d-61b6-73e0-82eb-4d6e8749cfa1`，createdAt `1792447177`。
- 普通合入已审 026-1 `40417c61058d7653737ceb23b821f11ba75e53c8` 后初始 HEAD `de68f7f777b373c14363173a15fe9bcd6dddee5c`，branch/clean 已实际核对。该输入含 018/037/024/028 和显式 Package 依赖；不消费后续 catalog WIP。
- 仅写 M4HealthDeletionBridge.swift、同名 Tests、039 task/validation 与本 plan 五路径。不改 Package、Core、SDK、catalog、App/工程或其他测试；不撤销他人成果。

## API 与持久顺序

1. `M4HealthRawReservation` 冻结原 parentID、raw scope、全部选择、独立 Health 确认、固定秒级时间、完整 capture revisions/operations 与显式逐安装 source evidence。由真实 linked observation + segment 与原 `operation.externalToken` join；不剥 segment ID。相同 UUID/原 tuple 去重，冲突、未知覆盖、来源缺失、跨 source、空选择或超过 256 均 typed blocked，不截断或虚构目标。
2. `M4HealthMappingStore` 提供 reserve/readReservation、putPrepared/readPrepared 和 readFullSeal；桥每次写后逐字读回。生产默认 unavailable。026 的原子 retained catalog 负责首次不可变写、冲突、控制区保留、全 seal 与恢复；本任务不新增生产 file journal。test-only file-backed SQLite mapping 仅验证契约，不证明 026 已接入。
3. `prepare(parentID:)` 从注入的原 `LifecycleStateRepository` 读持久 saga，允许 backend 尚未删除，校验原 scope/选择和实际 intent digest。先持久 prepared mapping/readback，再复用 028 submit、confirm、entry 全 canonical 读回。创建 selection 后永不重算 UUID、时间或 digest。026 必须完成全 seal/readback 才能调用任何 resume。
4. UUID 固定为 SHA256 前 16 bytes，byte6 = (byte6 & 0x0f) | 0x80（version 8），byte8 = (byte8 & 0x3f) | 0x80（RFC variant）。输入为 UTF8 domain + NUL，再逐字段 UInt64 big-endian byte length + 原 bytes。request domain `football-record.m4.health-request-uuid.v1`，字段 parentID、actual parentDigest、reservationDigest；confirmation domain `football-record.m4.health-confirmation-uuid.v1`，字段同上，再 request UUID 小写串、028 selectionDigest。无 Unicode normalization。
5. `M4HealthDeletionBridge: AppWorkoutDeletionDriver` 的旧参数 `confirmationID` 实际是原 parentID。回调读 retained reservation/prepared/full seal 和实际 saga，要求 backendDeleted、health.delete/独立确认、raw scope/全部选择/实际 digest 完全匹配，并核真实 028 entry。只有同 request/digest 的 succeededLocally receipt 返回成功。失败不替代其他组或所有设备完成。
6. wrapper 比 028 叶层更保守：executing/awaitingOutcome/interrupted 或 outcomeUnknown 不自动重派；已知失败可沿同原 request 明确重试。close 后旧回调/重开未知不成为新 attempt；028 仍持有原 first receipt。source evidence 区分 controlled fixture 与平台已证来源，默认不可用，Phone 不推测 Watch 来源；本任务不执行 Health SDK。

## 三个 TDD slice

- 原始 facts reservation：先测试真实 Core token、恢复/重启 token、Unicode raw binding、source/覆盖/冲突/超限，再最小实现。
- 实际 parent → durable prepared → 028：真实 SQLite 028 + test-only durable mapping，覆盖重开、写前失败/提交丢响应、原 bytes、first confirmation、同 ID 异意图拒绝。
- sealed callback：原 parentID、backend/选择/全 seal 门禁、first receipt、timeout/迟到/关闭重开 unknown，不绕 028。

每个 slice 先红后绿并保存原日志。最终完整 AppIntegration host 单轮与四项最低 iOS17/watch10 simulator/device 产品编译；精确输入/日志 hashes 外置，source/final 双审后停写。真实账号、HealthStore、授权/设备/全 catalog/全本地擦除不在本任务验收。
