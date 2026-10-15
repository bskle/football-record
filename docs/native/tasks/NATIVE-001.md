# NATIVE-001：原生工程基础

日期：2026-10-15。状态：实施中；不是 M1 全部完成，也未合并或发布。

| 字段 | 实际值 |
|---|---|
| 目标 | 可构建 iOS / watchOS SwiftUI 壳，实际消费共享 MatchCore 产品身份 |
| 主代理 / 唯一写入负责人 | `/root` / `/root/native_foundation` |
| 两位非作者审阅者 | `/root`、`/root/environment_check`，待绑定最终提交审阅 |
| base_ref / 原始 base_sha | `dev` / `2d4616355221af0969e07e9b1f45852449cbb98e` |
| 合并目标 / 创建时目标 SHA | `dev` / `2d4616355221af0969e07e9b1f45852449cbb98e` |
| 临时分支 | `build/native-foundation` |
| 受管 worktree identityKey / 绝对路径 | `/Users/liam/.codex/worktrees/native-foundation/20260830_足球记录` |
| 开写前实际 HEAD / 状态 | `2d4616355221af0969e07e9b1f45852449cbb98e` / clean，作者已核对 |
| 所有权 | `native/FootballRecord.xcodeproj/`、`native/Configuration/`、`native/Apps/iOS/`、`native/Apps/Watch/`、`native/Packages/MatchCore/`、`native/README.md`、`scripts/native/`、`.gitignore`、本卡、本任务子计划及验证记录 |
| 共享工程所有者 | `/root/native_foundation`；pbxproj / schemes / 配置串行修改 |
| 前置 | 已验证 dev 含 NATIVE-000 与 IDENTITY-001；Xcode 27 / Swift 6.4 可用，真机暂不能连接 |
| 计划 | [精简执行子计划](../../superpowers/plans/2026-10-15-native-foundation.md) |
| 验收 | `scripts/native/verify.sh`（SwiftPM、iOS Simulator、watchOS Simulator 无签名构建）；`git diff --check`；工程嵌入与包引用自审 |
| 业务 / 真机边界 | 无业务引擎与业务测试；本次 SDK 构建不证明签名安装、配对、采集、锁或分发，真机验证留对应阶段 |
| 后续依赖 | NATIVE-002 事件引擎；NATIVE-003 事务存储与 outbox，均为独立任务 |
| 提交 / 双审 / 合并 | 待实际执行；不以计划命令冒充验证结果 |
| 清理 | 活跃 worktree 保留；主代理集成验证且无活跃依赖后安全归档并 `git branch -d` |

验证原始结果与限制将记录于 `docs/native/validation/NATIVE-001.md`。远端 private / 写权限未落实前不推送；本任务不推进 `dev` / `release` / `main`。
