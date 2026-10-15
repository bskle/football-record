# NATIVE-002：共享比赛事件引擎

日期：2026-10-15。状态：实施中；未合并，不代表 M1 完成或可采集真实比赛。

| 字段 | 实际值 |
|---|---|
| 主代理 / 唯一写入者 | `/root` / `/root/match_engine` |
| base / 开写 HEAD | `dev` / `b7729b75ff29fccb578ec204438aa37dc3ab2136`，clean |
| 合并目标 | `dev` |
| 临时分支 | `feat/match-event-engine` |
| 受管 identityKey / 路径 | `/Users/liam/.codex/worktrees/match-event-engine/20260830_足球记录` |
| 所有权 | `native/Packages/MatchCore/`、`scripts/native/verify.sh`、`native/README.md` 必要状态、本卡、子计划、验证记录 |
| 不修改 | Xcode 工程 / scheme / capability / 配置、原型、产品方案、母计划、AGENTS / Git 治理 / 准备检查 |
| 计划 | [实施子计划](../../superpowers/plans/2026-10-15-match-event-engine.md) |
| 验收 | 纯 Swift 行为测试、双端无签名 SDK 构建、diff check、两位非作者审阅 |
| 真机 | 本任务纯业务计算无采集或通信，真机不适用；签名 / 实采 / 锁与分发留对应阶段 |
| 后续 | NATIVE-003 事务仓储 / outbox；当前只输出待保存事实 |
| 提交 / 审阅 / 合并 / 清理 | 作者完成后交主代理登记；不自行 push / merge 长期分支 |
