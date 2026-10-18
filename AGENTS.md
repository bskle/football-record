# 协作与执行规则

本仓库的原生开发以 [原生开发母计划](docs/superpowers/plans/2026-10-15-native-development.md) 为任务依据，以 [Git 与工作树治理方案](docs/git-workflow.md) 为分支、提交、验证、合并和清理规则。用户当前明确指令优先于历史工作流记录；历史 `.czy-workflow/runtime/` 不能替代实际 Git 状态。

## 当前执行状态（2026-10-19，上海；历史验证保留原日期）

- 正式中文名为“球历”，英文名为 `football-record`；Xcode 工程技术名保留 `FootballRecord`。
- 2026-10-15 规划启动时“尚未创建分支、worktree、标签”的快照已被 bootstrap 取代。永久分支为 `dev`、`release`、`main`；`main` / `release` 均保留浏览器原型基线 `59edac891ee3a1cbb79a30b396ad1902d0907a62`，annotated tag 为 `prototype-baseline-20261015`。release尚无原生冻结候选，尚无原生发布。
- M1 本地基础已双审集成，历史组合 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 的70项XCTest与四项构建证据保留。旧任务卡、[GIT-002](docs/native/tasks/GIT-002.md)、[GIT-003](docs/native/tasks/GIT-003.md)及[NATIVE-013](docs/native/tasks/NATIVE-013.md)保留各自时点证据；M3历史治理台账为[GIT-004](docs/native/tasks/GIT-004.md)，当前M4交付与适配所有权补充见[GIT-005](docs/native/tasks/GIT-005.md)。
- M2的006/007/011/009/012与M3的013/014/015/017均已双审合入并同步。历史已验证App组合 `b0070c90d91bf9d7741b7a7ed24165f1ad27383d`，实际merge单轮252项宿主测试（44 Core + 106 Store + 46 Session + 17 MatchSync + 39 Presentation）、8项最低SDK产品、2个无签名App与两端各1项XCUI spot通过。该252项证据不包含后续M4新增模块；当前dev/origin HEAD以Git现场及下方M4记录为准。017作者此前双端各9项XCUI、375pt深色最大字体与旧009证据保留各自输入层次；最低iOS17/watch10只编译，真人VoiceOver及触觉未验。
- 008最终`6e86e8f1ac647b02b8f1ef407226a10398c5d998`已编译双审；010最终`cdbafb7822ca2371a3d1eaa6da8b95e54da78f2f`（source `834cac5`）本机可完成部分已双审，105 input / 157 evidence已核。212是旧Core/Workout184 + 当前Presentation22/Integration6的分层累计，不是一次全212；两模拟器/两设备SDK无签名App与两端各3项UI通过。签名/安装/授权/GPS/后台/锁屏/恢复仍待真机，008/010不入dev、不晋级release/main。
- 用户已明确“先跳过需要我协助部分，往下推，后续再做相关测试”。[M3](docs/superpowers/plans/2026-10-16-native-m3.md)已交付完整v2快照/schema3、持久分片/ACK服务、同Session接收桥与状态UI；主线仍用unavailable采集gateway、transport和生产trust。016最终 `001f9a3bff46856fa7845c4243603f131f26f5bf` 已双审，21项host/四最低SDK编译通过，保留独立树待配对真机。018已在独立树普通合入016/010及019测试兼容修复，source `72846583e503349d117dac84e42fde746d384fee` 双审PASS；单次331host/14最低SDK/2simApp通过，两generic设备App及两端UI保留分层证据，最终 `891000e1842f21f4a594a1d29168974debed68b9` 已源码 / 最终双审PASS，作者clean停写；本人设备/账号/环境验收延期，008/010/016/018不提前合dev。
- 用户已授权按计划推进及同步 GitHub，并以“公开就公开暂时没事”接受 public 仓库，覆盖先前 private 意向。`origin = https://github.com/bskle/football-record.git`；`gh` 登录、HTTPS 与 `PUBLIC` / `ADMIN` 已核对，远端只有三条永久分支，默认 `main`。PR、CI 与服务端保护规则尚未配置，本地双审持续执行；代码同步不等于原生发布。
- 005/006/007/011/012/GIT-003及013/014/015已实际归档并安全`git branch -d`。旧002/003/004/GIT-002/009共五树仍queued且实际active；017归档请求也queued、实际active（当前attachment `01a14403-f412-7d11-8799-21b42f0884f4`），分支保留。必要ignored证据已另存，不盲重试、强删或绕过工具。008/010/016/018因验收依赖正常保留；019测试兼容任务已合入018、实际归档并安全删分支。
- Xcode27.0 / Swift6.4可用，最低iOS17/watch10不升级。M4的[NATIVE-020规划](docs/native/tasks/NATIVE-020.md)已双审合入；[子计划](docs/superpowers/plans/2026-10-18-native-m4.md)/[合同](docs/native/contracts/m4-account-lock-cloud.md)按既有授权推进。021 final `a55dab4d10bf2b10011c81a49a30128cd9f835ad` 实际合并为 `a15b8414c460026e5ea7725f9c17ea08ce9ed737`（Node 56）；022 final `b648b730fbb9929453c32a43b12bc77bd2d67faf` 实际合并为 `8d6ec935efa060ab462b2913ab8460734871ff40`（Cloud 42及新增两个最低simulator SDK target编译）。root+m2双审、实际merge Node56+Cloud42均通过并已同步，当前 `dev=origin/dev=8d6ec935efa060ab462b2913ab8460734871ff40`；本批文档合并后以现场为准。020/021/022均已实际archive并安全branch-d；旧queued树和008/010/016/018保留原状态。
- 021是loopback HTTP/文件SQLite参考后台，022是独立云台账/受控driver，均未启用到生产App，不能与历史App252混称一次整包验证。023仍在独立树实现schema4、原Session和同facade纵向，未交付。生产Apple/可信peer/开赛provider、真实CloudKit、签名与服务部署仍未验；默认unavailable。Debug独立DB/固定身份持续标“开发模拟锁 / 开发配对”；peer ACK不释放后台锁、不制造completed，正常completion仍需当前完整云proof与正常后台释放双证据。
- [GIT-005](docs/native/tasks/GIT-005.md)仅补既有M4删除责任：027独占backend服务端AppleRevoker，可与023独立并行；024只持客户端AuthenticationServices/Keychain/CloudKit，TeamID/.p8/client_secret绝不进App。028独占新`native/Modules/HealthKitDeletion/`，先受控driver及四triple最低SDK编译，不调用用户HealthStore读/删/授权。025仍为Apps/project/scheme/entitlements/UI唯一作者，026映射删除saga并验真实账号/服务/设备；SDK候选门槛前留树，工程拆分不新增产品审批。

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
