# NATIVE-000：规划与 Git bootstrap 台账

日期：2026-10-15。正式名称：球历 / `football-record`。本卡是当前事实记录，历史 runtime 仅参考。

| 字段 | 实际值 |
|---|---|
| 任务 | 将已审阅母计划、准备检查与 Git 治理落入受管任务分支；不含原生实现 |
| 主代理 / 写入负责人 | `/root` / `/root/foundation_plan` |
| 双审 | 尚未开始，由主代理派两位非作者审阅者；作者自审不计 |
| base_ref / base_sha | `dev` / `59edac891ee3a1cbb79a30b396ad1902d0907a62` |
| 合并目标 / 创建时目标 SHA | `dev` / `59edac891ee3a1cbb79a30b396ad1902d0907a62` |
| 分支 | `docs/native-development-plan` |
| 受管 worktree identityKey / 路径 | `/Users/liam/.codex/worktrees/native-planning/20260830_足球记录` |
| attachment id | `01a13ecf-a912-79c0-9148-ed2f2429a6de` |
| 创建日期 / 开写前 HEAD | 2026-10-15 / `59edac891ee3a1cbb79a30b396ad1902d0907a62`，已核对分支与路径 |
| 写入所有权 | `AGENTS.md`、`docs/git-workflow.md`、`docs/development-readiness.md`、`docs/superpowers/plans/2026-10-15-native-development.md`、本卡；NATIVE-001 另含其子计划及任务卡，由同一作者串行写入 |
| 禁止写入 | `prototype/`、产品方案、品牌任务文件、`native/` 与其他代理 worktree |
| 原型基线 | annotated `prototype-baseline-20261015` → `59edac891ee3a1cbb79a30b396ad1902d0907a62` |
| 长期分支快照 | `dev` / `release` / `main` 均为完整 base；`main` 为原型，`release` 无活动候选 |
| remote | `origin = https://github.com/bskle/football-record.git`；public，连接只读，`gh` 未登录；未推送 |
| 前置与范围 | 已获本地推进授权；Xcode 27.0 / Swift 6.4 可用，真机暂不能连接不阻塞文档与 M1 |
| 提交 / 审阅 / 合并 | 提交 SHA 以本卡对应 Git 提交及主代理交付记录为准；双审与合并尚未执行 |
| 清理 | 保留活跃 worktree；只有主代理集成验证且无依赖后，才归档并以 `git branch -d` 删除临时分支 |

## 实际核对与限制

- 作者已读取并核对母计划、工作流、准备检查和产品方案有关状态、事件、可靠性条款；已运行 `git status --short`、`git branch -v`、`git rev-parse HEAD`、`git remote -v`、`git worktree list --porcelain` 与 `git tag -n3`。
- 文档变更提交前运行 `git diff --check`、本地 Markdown 链接存在性和过期事实扫描；实际结果记录在提交 body，不能把计划命令记成已运行。
- 真机不适用：本任务只改开发与治理文档。没有原生工程，未执行原生构建、SDK 测试、真实联网锁、HealthKit 或发布验证。
- 2026-10-15 规划启动时曾“尚无分支/worktree/tag/remote”，该历史快照不再代表当前状态；本任务也不声称文档已合并或远端规则已配置。
