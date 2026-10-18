# NATIVE-022 独立持久云台账

状态：开发中；仅无需用户协助的软件范围。

| 字段 | 登记 |
|---|---|
| 作者 | /root/m4_cloud，唯一写入作者 |
| 主代理 | /root |
| base_ref / base_sha | dev / `5e876cfd875585b315b57f91bcb8dc7160f8afa6` |
| 登记合并目标 | dev / `5e876cfd875585b315b57f91bcb8dc7160f8afa6` |
| 分支 | `feat/m4-cloud-ledger` |
| attachment | `01a14f8f-ff04-7203-97ef-8121e71ad4cb`，createdAt 1792336199 |
| 绝对路径 | `/Users/liam/.codex/worktrees/m4-cloud-ledger/20260830_足球记录` |
| 初始实际 HEAD / 状态 | `5e876cfd875585b315b57f91bcb8dc7160f8afa6` / clean，分支已核 |
| 唯一所有权 | `native/Modules/CloudSync/**`、本任务卡、`docs/native/validation/NATIVE-022.md` |
| 禁止写入 | MatchCore、App、工程配置、verify.sh、AGENTS、冻结合同、其他任务树 |
| 前置 | 020 exact 双审后 no-ff 合入上述 base，主代理已核验证和同步 |
| 审阅 | 待两位非作者 exact source/final 双审 |

执行依据为 [M4 计划第 6 节](../../superpowers/plans/2026-10-18-native-m4.md) 与 [冻结合同](../contracts/m4-account-lock-cloud.md)。按 022.1/2/3 分别先失败测试、实现、绿验证与 Conventional Commit；不推进长期分支、不 push/merge/archive。

证据：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-022`。六项 Git 输入、工具版本、红绿日志及 SHA manifest 在该树外目录保存。

真实 CloudKit / CKAsset、生产 VerifiedCloudSave、现有 MatchStore 同 facade 接入以及真实账号/设备测试留 023/024/026；本任务的独立 SQLite fixture 不能当作业务库已经导入。生产默认 sink 保持 awaitingBusinessImport。真机对本任务隔离台账和协议单元验证不适用，不替代后续真实层。
