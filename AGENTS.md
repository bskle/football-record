# 协作与执行规则

本仓库的原生开发以 [原生开发母计划](docs/superpowers/plans/2026-10-15-native-development.md) 为任务依据，以 [Git 与工作树治理方案](docs/git-workflow.md) 为分支、提交、验证、合并和清理规则。用户当前明确指令优先于历史工作流记录；历史 `.czy-workflow/runtime/` 不能替代实际 Git 状态。

## 当前执行状态（2026-10-19，上海；历史验证保留原日期）

- 正式中文名为“球历”，英文名为 `football-record`；Xcode 工程技术名保留 `FootballRecord`。
- 2026-10-15 规划启动时“尚未创建分支、worktree、标签”的快照已被 bootstrap 取代。永久分支为 `dev`、`release`、`main`；`main` / `release` 均保留浏览器原型基线 `59edac891ee3a1cbb79a30b396ad1902d0907a62`，annotated tag 为 `prototype-baseline-20261015`。release尚无原生冻结候选，尚无原生发布。
- M1 本地基础已双审集成，历史组合 `f94c915f5d2486ba1ff54471de9de98bc7fdc4d0` 的70项XCTest与四项构建证据保留。旧任务卡、[GIT-002](docs/native/tasks/GIT-002.md)、[GIT-003](docs/native/tasks/GIT-003.md)及[NATIVE-013](docs/native/tasks/NATIVE-013.md)保留各自时点证据；M3历史治理台账为[GIT-004](docs/native/tasks/GIT-004.md)，M4适配责任补充见[GIT-005](docs/native/tasks/GIT-005.md)，历史本地交付见[GIT-006](docs/native/tasks/GIT-006.md)，当前账号/SDK/UI交接见[GIT-007](docs/native/tasks/GIT-007.md)。
- M2的006/007/011/009/012与M3的013/014/015/017均已双审合入并同步。历史已验证App组合 `b0070c90d91bf9d7741b7a7ed24165f1ad27383d`，实际merge单轮252项宿主测试（44 Core + 106 Store + 46 Session + 17 MatchSync + 39 Presentation）、8项最低SDK产品、2个无签名App与两端各1项XCUI spot通过。该252项证据不包含后续M4新增模块；当前dev/origin HEAD以Git现场及下方M4记录为准。017作者此前双端各9项XCUI、375pt深色最大字体与旧009证据保留各自输入层次；最低iOS17/watch10只编译，真人VoiceOver及触觉未验。
- 008最终`6e86e8f1ac647b02b8f1ef407226a10398c5d998`已编译双审；010最终`cdbafb7822ca2371a3d1eaa6da8b95e54da78f2f`（source `834cac5`）本机可完成部分已双审，105 input / 157 evidence已核。212是旧Core/Workout184 + 当前Presentation22/Integration6的分层累计，不是一次全212；两模拟器/两设备SDK无签名App与两端各3项UI通过。签名/安装/授权/GPS/后台/锁屏/恢复仍待真机，008/010不入dev、不晋级release/main。
- 用户已明确“先跳过需要我协助部分，往下推，后续再做相关测试”。[M3](docs/superpowers/plans/2026-10-16-native-m3.md)已交付完整v2快照/schema3、持久分片/ACK服务、同Session接收桥与状态UI；主线仍用unavailable采集gateway、transport和生产trust。016最终 `001f9a3bff46856fa7845c4243603f131f26f5bf` 已双审，21项host/四最低SDK编译通过，保留独立树待配对真机。018已在独立树普通合入016/010及019测试兼容修复，source `72846583e503349d117dac84e42fde746d384fee` 双审PASS；单次331host/14最低SDK/2simApp通过，两generic设备App及两端UI保留分层证据，最终 `891000e1842f21f4a594a1d29168974debed68b9` 已源码 / 最终双审PASS，作者clean停写；本人设备/账号/环境验收延期，008/010/016/018不提前合dev。
- 用户已授权按计划推进及同步 GitHub，并以“公开就公开暂时没事”接受 public 仓库，覆盖先前 private 意向。`origin = https://github.com/bskle/football-record.git`；`gh` 登录、HTTPS 与 `PUBLIC` / `ADMIN` 已核对，远端只有三条永久分支，默认 `main`。PR、CI 与服务端保护规则尚未配置，本地双审持续执行；代码同步不等于原生发布。
- 005/006/007/011/012/GIT-003及013/014/015已实际归档并安全`git branch -d`。旧002/003/004/GIT-002/009共五树仍queued且实际active；017归档请求也queued、实际active（当前attachment `01a14403-f412-7d11-8799-21b42f0884f4`），分支保留。必要ignored证据已另存，不盲重试、强删或绕过工具。008/010/016/018因验收依赖正常保留；019测试兼容任务已合入018、实际归档并安全删分支。
- Xcode27.0 / Swift6.4可用，最低iOS17/watch10不升级。020～022、027/029～033的既有本地交付及各自清理保留[GIT-006](docs/native/tasks/GIT-006.md)层次；034 final `c0743b0615e127c3801558f988e88ff3e310341e` → actual `bcf211d5f1c5ee1e5179ca4b4e37121ae1edbccf` Node145/0，035 final `447a834e74372e8b87bc84f60f481d4a3256b0e6` → `75c3b0e833ea71c0e69c3c3b40e8c3c766074969` Presentation39/0，036 final `d5c7017efbd61f1570062dac07380c8c86bc68f1` → `17f2e39adcdbc633682992d5e5e2f348dbc940e6` Node161/0均已双审、实际merge复验/同步、原生实际archive与safe branch-d。034仅本机ops/TLS fixture/一致备份点恢复，不证明持续durability/RPO/epoch高水位或生产部署。
- 023执行source `5ee7bd33721a9015e23dfe23fd0e31c15fafd211`、final `f7f7a3bceb3000fd6d655d4724089601870eeb4d` 已root+m2 whole source/final exact PASS，实际no-ff `2642b426ee0ade276316a348537f72c0b2a1ed8a` 全树等于f7。root实际merge单轮591/0（161 Node +257 Core包[44 Core/149 Store/47 Session/17 Sync]+80 Cloud+54 Account+39 Presentation）、12最低sim SDK产品、2无签名generic sim App通过，dev=origin/dev已同步2642，023树已实际archive及安全删分支。223产品输入、234 manifest rows/236 checksums及19个merge分项日志见[GIT-007](docs/native/tasks/GIT-007.md)；094失败/27d570和此前Node128/Cloud80旧层不混入本轮591。本批文档合并后以Git现场为准。
- 024/025已正式独立树推进，登记base为已验证`17f2e39adcdbc633682992d5e5e2f348dbc940e6`并普通合入whole PASS的023候选f7；该输入产品树与actual2642相同。024持客户端SDK指定16路径，须8项最低sim/device产品编译，候选留026；025持39项UI/App/工程路径，独占pbxproj/config/schemes，entitlements仅reserved无真实值不写，不改Core/SDK/backend/verify.sh。两任务均未final/未入dev，selected在途结果不计主线591；完整界面/Debug纵向及最终Debug/Release两端App、XCUI/375pt深色最大字体验收仍待。
- 008/010/016/018及028 final `0fa3dff4d3232e72257f6fa115ecada873f086db`（双审29host/四SDK）保持独立候选；旧五树+017 archive queued且实际active，不盲重试/删除。真实Apple/Keychain/iCloud/CloudKit/Health/WC/签名安装/真机/部署及026全owned catalog组合擦除均延后，production trust/provider/bootstrap保持Unavailable。M4未完成，无原生冻结/发布，main/release及原型tag不动。
- [合同](docs/native/contracts/m4-account-lock-cloud.md)的既有wire和证明边界不变：knownAbandoned不是历史从未commit，404/401/timeout不关闭unknown；peer ACK不放锁/造completed；033仅单ledger跨epoch逻辑清理及永久fence，026仍聚合全部owned ledger catalog、024 staging、023 Store并保护saga/capability/028 selection。按既有public GitHub同步授权推进，不新增审批。

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
