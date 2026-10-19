# NATIVE-019：WorkoutCapture 测试替身同步兼容

依据：[原生开发母计划](../../superpowers/plans/2026-10-15-native-development.md)、[Git 治理](../../git-workflow.md)、[子计划](../../superpowers/plans/2026-10-16-workout-test-sync-compatibility.md)。

| 字段 | 实际登记 |
|---|---|
| 负责人 | 开发子代理 `/root/capture_test_compat`，唯一写入；主代理 `/root` 统筹及集成 |
| 两位非作者审阅者 | `/root` 质量审 PASS；`/root/m2_review` 规格审 PASS，均绑定下述 source SHA；final 三文档另审 |
| 创建 base_ref / base_sha | `dev` / `b0070c90d91bf9d7741b7a7ed24165f1ad27383d` |
| 已组装依赖 | NATIVE-008 final `6e86e8f1ac647b02b8f1ef407226a10398c5d998`，主代理已普通合入 |
| 实际开工 HEAD | `1662eef45ed3eaacab9ac348e360817df5e666f6`，已核对干净 |
| 分支 | `fix/workout-test-sync-compatibility` |
| Worktree 标识 | `01a14423-5cad-7523-afee-cb74931a10a2` |
| 绝对目录 | `/Users/liam/.codex/worktrees/workout-test-sync-compatibility/20260830_足球记录` |
| 工具创建时间 | `2026-10-16T09:55:30+00:00`（`createdAt=1792144530`） |
| 合并目标 | 仅 `test/m3-device-integration`；开工观察 SHA `be73b55e9c7d00cbdaefdebb518a4d30deee218a`，集成时主代理复核 |
| 写入所有权 | 本任务卡；上述子计划；`docs/native/validation/NATIVE-019.md`；`native/Modules/WorkoutCapture/Tests/WorkoutCaptureTests/SessionPersistenceTests.swift` |
| 共享配置 | Xcode project、scheme、target/capability、entitlements、锁文件均不修改 |
| 问题 | 旧 `FaultRepository: SessionRepository` 未实现继承的 16 个新 `SyncRepository` 要求，NATIVE-018 全验证停在 WorkoutCapture 编译 |
| 修复合同 | 16 方法全部转发同一个现有 SQLite `inner`，保留 `commitV2` 故障注入、数据库重开、原测试语义 |
| 自动门槛 | 保存当前 Core 上编译红证据，再跑完整 40 项 WorkoutCapture 宿主 XCTest；源码 diff/空白检查；双审 |
| 真机 | 本测试替身兼容修复不适用；008/010/016/018 物理设备门槛保持 |
| 结果状态 | source 已双审；红证据 exit 1 / 16 缺失；绿证据 40 项 / 0 失败；本次单独定稿三文档，等待 final 文档审阅 |
| 集成/生命周期 | 开发代理不合并、不推送、不归档；等待主代理实际 `--no-ff` 集成及验证 |

外部证据位置：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-019`。NATIVE-018 原红日志 `/tmp/football-record-NATIVE018-build/logs/20261016T094814Z/WorkoutCapture-tests.log` 仅作为问题来源；本任务单独运行并保存自身红绿证据，不声称全 331 项已通过。

## 交付与证据

| 项目 | 实际结果 |
|---|---|
| Source 提交 | `59f439a6d59b926dcf2462f046f45c5513831b35`，parent 为已登记组装 HEAD |
| Source 差异 | 唯一测试文件新增 16 行 / 删除 0；所有新增方法对同一 `inner` 逐参数转发，剥离新增块后与旧 Git blob 完全相同 |
| 红命令 | `swift test --package-path native/Modules/WorkoutCapture --scratch-path /tmp/football-record-NATIVE019-build/WorkoutCaptureHost`；2026-10-16 09:57:58–09:58:12 UTC，exit 1，16 个协议要求缺失 |
| 绿命令 | 原命令；2026-10-16 09:58:47–09:58:56 UTC，exit 0，40 项 / 0 失败，含 7 项持久化回归 |
| 源码审阅 | `/root` 核签名、参数、throws/result/identity、原内容不变和红绿证据，PASS；`/root/m2_review` 核规格、同实例转发、故障与断言保留及 40 项证据，PASS |
| 审阅边界 | 两审都绑定 source SHA / 组装基线 / 登记时临时目标；不提前表示 final 三文档已审 |
| 证据清单 | `source-manifest.json`：89 个 Git 输入、10 项证据；`final-manifest.json` 在文档提交后绑定实际 final SHA 和三文档，外部保存 |
| 内容绑定 | 绿测试时未提交的修复源码字节与 source 提交相同；此后只改三文档，无源码变化，不复跑 40 项冒充新的整包结果 |
| Final 提交 | 本卡所在文档提交的实际完整 SHA 由外部 `final-manifest.json` 记录，交付主代理作最终审阅 |
| 生命周期 | worktree / 分支保留；无合并、推送、归档，未触碰 dev/release/main |

[验证记录](../validation/NATIVE-019.md)保存准确分组、日志哈希、清单范围及门槛。真机不适用于本修复；原真实 SQLite 故障/重开回归保持，008/010/016/018 物理验收和整包门槛继续保留。
