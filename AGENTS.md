# 协作与执行规则

本仓库的原生开发以 [原生开发母计划](docs/superpowers/plans/2026-10-15-native-development.md) 为任务依据，以 [Git 与工作树治理方案](docs/git-workflow.md) 为分支、提交、验证、合并和清理规则。用户当前明确指令优先于历史工作流记录；历史 `.czy-workflow/runtime/` 不能替代实际 Git 状态。

## 当前执行状态（2026-10-15）

- 正式中文名为“球历”，英文名为 `football-record`；Xcode 工程技术名保留 `FootballRecord`。
- 2026-10-15 规划启动快照曾为“尚未创建分支、worktree、标签”；该快照已被本次 bootstrap 事实取代。`dev`、`release`、`main` 均已从 `59edac891ee3a1cbb79a30b396ad1902d0907a62` 建立或保留，原型 annotated tag 为 `prototype-baseline-20261015`；`main` 仍是浏览器原型基线，`release` 没有活动候选。
- `docs/native-development-plan` 已在独立受管 worktree 创建，文档提交、双审及合并结果以 [NATIVE-000 台账](docs/native/tasks/NATIVE-000.md) 的实际记录为准；分支存在不表示文档已合入 `dev`，也不表示原生构建或发布已完成。
- 用户已授权按现有计划本地推进。`origin` 已登记为 `https://github.com/bskle/football-record.git`，实查仓库为 public，当前连接只读且 `gh` 未登录；尚未推送，不将先前“私有远端待提供”当作当前事实，也不虚构 PR、CI 或保护规则。
- Xcode 27.0 / Swift 6.4 可用；用户暂不能连接真机。签名、真实设备和远端写权限不阻止 M1 工程搭建、纯业务测试与无签名 SDK 构建；真实采集、联网锁及分发仍须各阶段证据。

## 角色与派工

- 主代理负责统筹、依赖拆分、派工、进度、验证安排、验收、审阅与合并决策；产品实现、工程实现、自动测试编写及测试修复由开发子代理执行。该限制只约束主代理，开发子代理应完成受派实现和修复工作。
- 创建 worktree 前登记任务、子代理、完整 base SHA、合并目标、临时分支及目录/文件所有权；创建后立即补齐工具返回的 worktree 标识、绝对路径和实际 HEAD，核对后再开始写入。依赖未满足不得并行；禁止共享写入 worktree，不得覆盖或撤销其他代理改动。
- `project.pbxproj`、共享 scheme、target/capability、entitlements 和依赖锁文件等共享工程配置指定单独所有者，串行修改。

## Git、验证与安全

- 常规任务从最新已验证 `dev` 建立 `feat/`、`fix/`、`test/`、`docs/` 等临时分支；候选修复从 `release`、生产紧急补丁从 `main` 建立，并按治理方案完成回流。优先原生 `create_worktree` / `archive_worktree`，仅工具不可用时用安全 Git 后备。
- 每任务一分支、一 worktree、一位写入负责人。按明确路径暂存并做 Conventional Commits，默认不加 scope；提交 body 记录实际验证与限制，不混入他人成果或凭证。
- 合并前必须通过两位非作者审阅者检查及相关自动和真机验证；无设备影响的任务须说明真机不适用。主代理触发 `--no-ff` 合并并核对实际 merge SHA。开发子代理不得自行推进长期分支。
- `dev → release → main`；`release` 同时只持有一个候选版本，冻结后不整体接收继续前进的 `dev`。主代理在会话已有任务授权内完成本地分支治理与合并，已授权动作不重复询问；推送、上传、部署或外部分发缺乏既有授权时，先准备可审阅结果，再请求相应授权，不由历史门禁自动新增审批。
- 任务提交已被所有必需目标接收、无活跃依赖，且未提交、未跟踪和必要 ignored 文件已妥善保存后，先安全归档 worktree，再以 `git branch -d` 删除临时分支；远程副本依治理方案核对及清理，拒绝时保留并报告。
- 禁止强推（含 `--force-with-lease`）、硬重置、强删、自动 stash 来源不明修改、改写共享历史、移动已发布标签或删除长期分支；禁止用 `git clean`、`rm -rf` 等消除他人成果或绕过归档。无 remote 时不自动添加 remote 或推送。
