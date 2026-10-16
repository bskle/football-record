# 协作与执行规则

本仓库的原生开发以 [原生开发母计划](docs/superpowers/plans/2026-10-15-native-development.md) 为任务依据，以 [Git 与工作树治理方案](docs/git-workflow.md) 为分支、提交、验证、合并和清理规则。用户当前明确指令优先于历史工作流记录；历史 `.czy-workflow/runtime/` 不能替代实际 Git 状态。

## 当前执行状态（2026-10-16，上海）

- 正式中文名为“球历”，英文名为 `football-record`；Xcode 工程技术名保留 `FootballRecord`。
- 2026-10-15 规划启动时“尚未创建分支、worktree、标签”的快照已被 bootstrap 取代。永久分支为 `dev`、`release`、`main`；`main` / `release` 均保留浏览器原型基线 `59edac891ee3a1cbb79a30b396ad1902d0907a62`，annotated tag 为 `prototype-baseline-20261015`。尚无原生活动候选或发布。
- M1 本地基础已双审集成，历史组合 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 的 70 项 XCTest 与两端 MatchStore SDK / 两个 App 无签名构建证据保留。旧任务卡与 [GIT-002](docs/native/tasks/GIT-002.md) 只记录当时状态；当前治理台账为 [GIT-003](docs/native/tasks/GIT-003.md)。
- M2 的 NATIVE-006 采集事务 / v2 仓储、007 共享会话、011 已证明未创建采集的收尾修复、009 双端记录 UI 均经两位非作者审阅合入 `dev`。当前 `dev=origin/dev=2e1f9c42f4398a50b66765a0f37f90ced95a7554`，实际合并复验 158 项宿主测试、6 项 SDK 产品编译、2 个 App 无签名构建及每端 1 项 XCUI 通过。009 另有 iOS 27 / watchOS 27 各完整 7 项 XCUI、390pt / 45mm 界面和 375pt 深色最大字体定点视觉证据。App 已接入 Core / Store / Session / Presentation 的原生记录页面，使用 `UnavailableWorkoutGateway`；最低 iOS 17 / watchOS 10 仅编译，未实际运行最低系统，真人 VoiceOver 朗读及触觉手感未验。
- NATIVE-008 WorkoutCapture 最终 head `6e86e8f1ac647b02b8f1ef407226a10398c5d998` 已编译、双审：40 项模块 + 144 项核心宿主测试、双模拟器 / 双设备 SDK 无签名编译；证据来自 fake driver 与真实 SQLite 跨层测试，未实际运行 HealthKit，尚未入 `dev`。NATIVE-010 已从上述最新 `dev` 建独立 `test/m2-device-integration` 树，普通合入已审 008，正在准备真实 gateway、最小能力配置与操作指引；最终包未冻结，签名 / 安装 / 授权 / GPS / 后台 / 锁屏 / 恢复均待真机。008 / 010 相关真机门槛通过后才入 `dev`，不晋级 `release` / `main`。
- 用户已授权按计划推进及同步 GitHub，并以“公开就公开暂时没事”接受 public 仓库，覆盖先前 private 意向。`origin = https://github.com/bskle/football-record.git`；`gh` 登录、HTTPS 与 `PUBLIC` / `ADMIN` 已核对，远端只有三条永久分支，默认 `main`。PR、CI 与服务端保护规则尚未配置，本地双审持续执行；代码同步不等于原生发布。
- NATIVE-005 / 006 / 007 / 011 的受管 worktree 已实际归档、临时分支已用 `git branch -d` 安全删除。旧 NATIVE-002 / 003 / 004 / GIT-002 与新 009 归档请求仍 queued、实际 active，分支保留；必要 ignored 证据已另存，不盲重试、不强删或绕过工具。008 / 010 仍有设备验收依赖，正常保留。
- Xcode 27.0 / Swift 6.4 可用，用户暂不能连接真机。执行 [M2 子计划](docs/superpowers/plans/2026-10-16-native-m2.md)；生产开赛许可留 M4，Debug 使用独立数据库并持续标注“开发模拟锁”，不算生产锁 / E2E。本地普通结束保持 `endedPendingSync`，不释放后台锁或制造 `completed`。

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
