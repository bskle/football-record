# NATIVE-031 空账号迁移云控制检查点

状态：窄修复与自动验证完成，候选待 root+m2 exact SHA 双审；普通 match checkpoint 仍要求非空引用。

| 字段 | 登记 |
|---|---|
| 唯一作者 / 主代理 | /root/m4_cloud / /root |
| base_ref / 原始完整 base | dev / `d59768f5f5d7872b9c520fd746d20f99f236acdc` |
| 当前 target / 普通同步来源 | dev / `36daa5526aac447cedab8c0b636c2db80b09cfa6` |
| 分支 | `fix/m4-empty-cloud-checkpoint` |
| worktree | `/Users/liam/.codex/worktrees/m4-empty-cloud-checkpoint/20260830_足球记录` |
| attachment | `01a15018-11f6-7b32-abc0-4801d9774030` |
| 初始实际 HEAD / 状态 | `d59768f5f5d7872b9c520fd746d20f99f236acdc` / clean，分支已核 |
| 唯一所有权 | `native/Modules/CloudSync/**`、本卡、`docs/native/validation/NATIVE-031.md` |
| 禁止写入 | 030合同、Core、AccountKit、App、工程/配置、其他任务树 |
| 审阅 / 治理 | root+m2 exact SHA 双审；作者不推进长期分支、merge/push/archive |

依据：用户既有 M4 授权、[原生母计划](../../superpowers/plans/2026-10-15-native-development.md)、[Git治理](../../git-workflow.md)及主代理031窄修复派工；不读取023未审源码。030作者独占合同，本任务不改合同。

固定设计：`matchID = account-checkpoint:<scope.stableZoneKey>` 仅作 checkpoint 控制锚，不创建 Match/events/permit 或 scratch facts。account checkpointID 是调用方持久的稳定控制 UUID；recordIDs 是调用方提供的当前完整已确认 facts 记录集合，可为空。锚在 CloudRecord/导入解码边界精确绑定稳定 scope。普通 match checkpoint 非空语义、既有 canonical/recordID/digest 与 CloudUpload.checkpointID asset manifest 含义保持。

先真实 ledger/受控 driver/save/reopen 红，再最小实现与完整 Cloud host、两最低 simulator SDK 验证。证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-031`，含六 Git 输入、原红绿/SDK日志及 source/input/evidence hash manifest。真实 CloudKit、账号/设备不执行。

根因：CloudCheckpoint 原构造器无条件要求非空 recordIDs，真实空历史账号无法构造迁移最终 checkpoint。产品仅增加账号控制 factory / 统一锚规则、账号空集合例外及 CloudRecord 边界的 stable scope 校验；没有 schema、canonical 字段、hash 域或其他模块变更。

新增六项回归以真实文件 SQLiteCloudLedger 与受控 driver 验证：空账号保存只留下控制记录、非空账号引用真实已确认 facts 且不改其原 bytes、错 hash / 跨 account-space-zone 拒绝及同 stable zone 新 epoch 兼容、raw/Codable record 与 batch 导入拒绝异 scope、普通空集合/重复引用/非法控制 UUID 拒绝、既有普通 checkpoint 的精确 canonical bytes / recordID / digest 与重复 enqueue/reopen 保持。运行时红为6项中10处失败（含1 unexpected invalidPayload），修复后完整单轮 **53/53**，两项 fresh iOS17/watchOS10 simulator target 编译 exit0，详见 [验证卡](../validation/NATIVE-031.md)。

迁移提交采用控制 CloudRecord.recordID 与 canonical CloudRecord.digest；CloudCheckpoint.checkpointID 为稳定控制 UUID，CloudUpload.checkpointID 继续表示 asset manifest ID。recordIDs 的当前完整业务集合由后续同 facade bridge 核验，本模块不伪造已接入业务库。真机不适用：仅隔离 typed checkpoint 值与边界校验，不启用生产 App 或改变 SDK 调用；真实 CloudKit / 账号 / 设备及023桥整体验收不在本任务结论内。

031 coherent fix 提交后，dev 已集成030的 backend/合同/两卡变更；按治理普通同步当前 target，41项 Native编译输入 hash 均未改变。同步组合再跑完整53/53，双SDK保留本轮 fresh 原日志及相同输入 hash。最终 source/final SHA、源码与日志 hash、两审/合并状态留在树外 manifest / 主代理 registry。作者提交后 clean 停写，不自行合入长期分支、push/archive 或推进长期分支。
