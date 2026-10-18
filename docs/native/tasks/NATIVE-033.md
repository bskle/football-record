# NATIVE-033 单云台账本地传输清理

状态：实现与自动验证完成，候选待exact双审；仅单 ledger 文件内目标 stable zone 的传输 canonical 副本，不代表整个本地删除完成。

| 字段 | 登记 |
|---|---|
| 唯一作者 / 主代理 / 双审 | /root/m4_cloud / /root / root+m2 exact SHA |
| base_ref / 原始 base | dev / `ef10b33a10663ad94b0bb4a3e43106af108c38bb` |
| 当前target / 普通同步来源 | dev / `aa9977805dfb172cf1ece605d1f575cf7684df72` |
| 分支 | `feat/m4-local-transport-erasure` |
| worktree | `/Users/liam/.codex/worktrees/m4-local-transport-erasure/20260830_足球记录` |
| attachment / createdAt | `01a1502d-7e43-78e2-9f4e-0271040e9f06` / 1792346521 |
| 初始实际 HEAD / 状态 | `ef10b33a10663ad94b0bb4a3e43106af108c38bb` / clean，分支已核 |
| 唯一写入 | `native/Modules/CloudSync/**`、本卡、`docs/native/validation/NATIVE-033.md` |
| 禁止写入 | Core、AccountKit、Apps、backend、合同及其他任务卡/工作树 |

依据：[母计划](../../superpowers/plans/2026-10-15-native-development.md)、[Git治理](../../git-workflow.md)、主代理033派工与树外只读 preflight `c23c8f8d044d054fc653737a3b33425e51f809e2c6fef65ad7577886a90dabf4`。本卡承接已批准的窄任务执行步骤，不创建越界计划文档。

执行切片：先真实SQLite持久fence红测；再写可选 `CloudLocalTransportErasing`、最小request/receipt、原子严格枚举/删除/永久fence及schema迁移；最后覆盖两连接、回调两顺序、坏行回滚、重开与故障，完整原53+新增host和两fresh最低simulator SDK。原CloudLedger required funcs不变，不消费023未审源码。

目标精确 account/cloudSpace/zone 跨epoch，仅四表canonical；其他scope原bytes保持。未知/损坏/归属不了失败保留。旧文件fence永久且所有canonical写事务检查；新epoch不自动解除，026失效旧actors后选择新namespace恢复。026仍覆盖全部owned ledger catalog、024 stagingfiles、023 Store，并保护saga/capability/028 selection。默认unavailable，真实CloudKit/账号/设备不执行。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-033`。完成后精确路径暂存、Conventional Commit无scope、clean停写交双审；作者不推进长期分支/push/archive。

实际产品新增可选erasure协议、稳定request与最小receipt、cloud schema4永久fence/receipt控制表；原CloudLedger协议、CloudModels canonical/hash、Core与其他模块不改。按column_bytes严格UTF8/NUL解码TEXT，严格校验四表原bytes/scope/digest/ACK及新控制receipt/fence关系；单事务删除后再次枚举验证目标零，全部canonical写入事务持久复查。

原实现真实fence红2/9；NUL文本红1/14；receipt缺fence的控制一致性红1/4。最终完整单轮 **74/74**（原53+新增21）与fresh iOS17/watch10 simulator target编译exit0，无warning；详见 [验证卡](../validation/NATIVE-033.md)。真机不适用：隔离SQLite和受控driver，不调用真实CloudKit/账号/设备，不宣称整个本地删除、物理介质/备份擦除或023整体验收。

coherent产品提交后普通同步已验证032目标aa9977；其变更仅backend/合同/032两卡，Native零delta。同步组合完整host再跑74/74；42项package/source编译输入与本轮fresh双SDK逐hash相同，保留各原日志及实际输入层次。source=final/精确SHA与审阅状态留树外manifest，作者clean停写。
