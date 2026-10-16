# NATIVE-005：M2 可执行技术拆分与会话采集合约

状态：作者定稿及文档自验；待两位非作者绑定最终head和目标审阅，再由主代理集成。没有实现M2代码，没有声明真实Workout/恢复/锁验收完成。

| 字段 | 实际值 |
|---|---|
| 主代理 / 唯一写入负责人 | `/root` / `/root/m2_plan` |
| 两位非作者审阅者 | `/root/m2_review`规格、`/root`质量；审阅结果由主代理实际登记 |
| base_ref / 原始base_sha | `dev` / `07bd1701b4d9ac42bc5cae933d611963659a2deb` |
| 合并目标 / 创建时目标SHA | `dev` / `07bd1701b4d9ac42bc5cae933d611963659a2deb` |
| 临时分支 | `docs/m2-execution-plan` |
| 受管worktree identityKey / 绝对路径 | `/Users/liam/.codex/worktrees/native-m2-plan/20260830_足球记录` |
| attachment / 创建时间 | `01a14231-d674-72d1-a9a5-e3c13487b327` / `2026-10-16T00:52:04Z`（工具createdAt `1792111924`） |
| 开写前实际HEAD / 状态 | `07bd1701b4d9ac42bc5cae933d611963659a2deb` / clean；已核对分支与目录 |
| 独占六路径 | `docs/superpowers/plans/2026-10-16-native-m2.md`、本卡、`docs/native/contracts/m2-session-capture.md`、`AGENTS.md`、`docs/development-readiness.md`、`docs/superpowers/plans/2026-10-15-native-development.md` |
| 禁止写入 | 所有源码/测试/脚本/工程/原型、旧任务卡/验证历史、其他代理树；后三份入口文档仅同步阶段/依赖事实 |
| 依赖 | M1 001至004已双审集成；功能组合`f94c915f5d2486ba1ff54471de9de98bc7fdc4d0`有70测试/四构建证据，GIT-002文档已集成为本任务base |
| 提交与集成 | 单一Conventional文档提交；作者不merge/push/归档；实际提交SHA由Git和主代理登记，本文不自引最终SHA |

[实施计划](../../superpowers/plans/2026-10-16-native-m2.md)固定006仓储→007会话→008真实适配与009UI/工程并行→010设备集成。共享工程唯一所有者在009，010串行接手。设备实现先编译双审形成包，待真机门禁后才能入dev；无设备不阻止无设备影响任务。生产锁留M4，Debug fixture隔离且不算E2E。

[会话采集合约](../contracts/m2-session-capture.md)固定v1兼容、v2事务、append-only采集revision、持久操作对账、未路由业务outbox、完成凭据失效、同场并发/恢复/终结规则与协议签名。Apple API可用性使用主代理转交的官方/SDK预研结论；没有重新宣称项目采集构建或设备行为通过。

作者自验范围：`git diff --check`、六路径范围、Markdown本地链接存在性、占位词/类型一致性及母计划M2逐项覆盖。纯文档未重跑70项业务测试/构建；真机不适用，不涉及设备行为变更。实际检查输出写提交body并向主代理交接；双审、实际merge验证和安全归档由主代理后续登记。

原生受管树位于当前sandbox写白名单外；首次mkdir被拒且未产生改动，改用针对上述六路径的授权写入审查，不绕过任何Git/归档门禁。002/003/004/GIT-002四个旧archive请求仍queued且实际active，本任务不复用或盲重试。
