# 协作与执行规则

本仓库的原生开发以 [原生开发母计划](docs/superpowers/plans/2026-10-15-native-development.md) 为任务依据，以 [Git 与工作树治理方案](docs/git-workflow.md) 为分支、提交、验证、合并和清理规则。用户当前明确指令优先于历史工作流记录；历史 `.czy-workflow/runtime/` 不能替代实际 Git 状态。

## 当前执行状态（2026-10-16，上海）

- 正式中文名为“球历”，英文名为 `football-record`；Xcode 工程技术名保留 `FootballRecord`。
- 2026-10-15 规划启动快照曾为“尚未创建分支、worktree、标签”；该快照已被本次 bootstrap 事实取代。`dev`、`release`、`main` 均已从 `59edac891ee3a1cbb79a30b396ad1902d0907a62` 建立或保留，原型 annotated tag 为 `prototype-baseline-20261015`；`main` 仍是浏览器原型基线，`release` 没有活动候选。
- M1 本地基础交付完成：NATIVE-001 工程、NATIVE-002 共享事件引擎、NATIVE-003 SQLite 事务仓储 / outbox 与 NATIVE-004 采集片段值合同均经两位非作者审阅合入 `dev`。组合提交 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 已验证 70 项 XCTest 零失败、两端 MatchStore SDK 与两个 App 无签名构建通过。采集元数据仅为合同，落盘及真实采集接线留 M2；App 仍为开发预览壳，没有用户记录页面。当前治理快照见 [GIT-002 台账](docs/native/tasks/GIT-002.md)，旧任务卡保留当时状态。
- 用户已授权按现有计划推进，并以“公开就公开暂时没事”接受当前 public 仓库，覆盖先前 private 意向。`origin = https://github.com/bskle/football-record.git`；主代理已核对 `gh` 登录、HTTPS 认证与仓库 `PUBLIC` / `ADMIN` 权限。GIT-001 合并后已首次原子推送三条长期分支与原型标签；截至本快照，远端 `dev` 已核对为上述组合 SHA，`main` / `release` 仍为原型基线，默认分支为 `main`。代码同步不等于原生发布，PR、CI 与服务端保护规则尚未配置。
- NATIVE-002 / 003 / 004 已请求原生 worktree 归档，但工具仍返回 queued 且实际列表仍 active，三个临时分支均保留；不把请求当作清理成功，不强删或手动绕过。证据已保存到工作树外，代码均已进入 `dev`；GIT-002 文档树待双审集成后按同一规则处理。
- Xcode 27.0 / Swift 6.4 可用；用户暂不能连接真机。M2 已进入技术计划，见 [M2 子计划](docs/superpowers/plans/2026-10-16-native-m2.md) 与 [NATIVE-005](docs/native/tasks/NATIVE-005.md)：先 006 采集事务、007 共享会话，再并行 008 真实采集适配与 009 UI/唯一工程装配；010 为临时设备集成任务，不增加长期分支。无设备不阻止仓储、服务和无设备影响 UI；真实采集先形成已编译/双审包，相关真机验收通过后才入 `dev`。生产许可仍待 M4，开发 fixture 隔离且不算真实锁/E2E。

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
