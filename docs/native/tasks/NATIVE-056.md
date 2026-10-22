# NATIVE-056：账号最终投影检查

状态：计划待 root 与第二位非作者 exact 双审；产品与测试未改，尚未执行新增产品验证。

- 唯一作者 `/root/m4_presentation_publish`；审阅 `/root`、`/root/m4_recovery_audit`。
- original/effective base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；branch `fix/m4-account-final-publish`。
- tree `/Users/liam/.codex/worktrees/m4-account-final-publish/20260830_足球记录`；attachment `01a16197-99bc-71f0-9989-31f43c8d06d6`；operation `da2132a5-a435-4986-86f8-7e11836caea2`。创建后实际 HEAD 与 clean（含 ignored）已核。
- target held026 `test/m4-e2e-integration`，登记 SHA `d155eaaeee02384187966f835d85ce94f079c983`，root 集成前重核；不提前推进 dev/release/main。
- 所有权为 [计划](../../superpowers/plans/2026-10-22-m4-account-final-publish.md) 列明的五路径：原 AccountStatusModel、原 AccountStatusTests、本卡、[验证卡](../validation/NATIVE-056.md)、计划。其他树与工程/Package/脚本不写。

原异步 admitIdentity 完成持久投影检查后，在 ready 赋值前增加 nonescaping 同步 MainActor throwing veto，之后同步重核原 token/stopped。原公开 API 与既有 read seam 保持兼容；无 authority、SQL/vault/network 或生产 provider 扩张。调用者未通过既有 admission 时不能用此接口认证。

026 的 credential/full tuple/资源封口检查由026独立实现；本接缝 source/final 双审并由 root 实际集成相关复验前，不消费提案 API。设备与账号配置不阻塞该查询投影任务；签名、真实 Apple/iCloud/Cloud/Watch/Health/WC 与整包验收仍后补。

计划提交 SHA、审阅、实际验证和后续 source/final 仅按完成事实补入树外 checkpoint，当前不预填通过数。
