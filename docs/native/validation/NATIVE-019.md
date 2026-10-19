# NATIVE-019 验证记录

依据：[母计划](../../superpowers/plans/2026-10-15-native-development.md)、[Git 治理](../../git-workflow.md)、[任务卡](../tasks/NATIVE-019.md)、[执行子计划](../../superpowers/plans/2026-10-16-workout-test-sync-compatibility.md)。

本任务恢复旧 WorkoutCapture 测试替身对当前 Core 的编译兼容。唯一源码变化是 `FaultRepository` 的 16 行同步接口转发；产品实现、`commitV2` 故障注入、现有断言与 SQLite 重开逻辑均未改动。删除新增 16 行后的文件与组装基线的 Git blob 严格相同。

## 绑定提交及环境

| 项目 | 实际值 |
|---|---|
| 原始 dev base | `b0070c90d91bf9d7741b7a7ed24165f1ad27383d` |
| 已合入 008 依赖 | `6e86e8f1ac647b02b8f1ef407226a10398c5d998` |
| 实际组装基线 | `1662eef45ed3eaacab9ac348e360817df5e666f6` |
| Source 提交 | `59f439a6d59b926dcf2462f046f45c5513831b35` |
| 临时目标登记快照 | `test/m3-device-integration` / `be73b55e9c7d00cbdaefdebb518a4d30deee218a`，不代表后续实际合并 SHA |
| Swift | Apple Swift 6.4 (`swiftlang-6.4.0.34.1 clang-2100.3.34.1`)，arm64 macOS 27 宿主 |
| Scratch | `/tmp/football-record-NATIVE019-build/WorkoutCaptureHost`，独立于其他任务 |
| Source 内容 SHA-256 | `4a9b0cfe1b751a8db5423f360cadcd344ad9fcc573f6be9d542db54b9c8a1aee` |

绿测试针对实际组装基线加修复文件运行；测试后该文件原样提交为 source，source manifest 再逐文件核对工作树与 Git blob 相同。文档定稿期间不再改源码，复用同一实际测试结果；不把文档提交说成一次新的整包测试。

## 实际红绿命令与结果

工作目录：`/Users/liam/.codex/worktrees/workout-test-sync-compatibility/20260830_足球记录`。

```sh
swift test --package-path native/Modules/WorkoutCapture --scratch-path /tmp/football-record-NATIVE019-build/WorkoutCaptureHost
```

| 阶段 | UTC 时间（2026-10-16） | 实际结果 |
|---|---|---|
| 修改前红证据 | 09:57:58–09:58:12 | exit 1；`FaultRepository` 不符合 `SyncRepository`，16 个唯一缺失要求；未运行测试 |
| 最小补齐后绿证据 | 09:58:47–09:58:56 | exit 0；完整既有 40 项 XCTest，0 失败，无 warning/error |
| 差异检查 | source 提交前 | `git diff --check` 通过；仅指定源码新增 16 行 / 删除 0；每个新增方法均转发同一 `inner` |

| XCTest 分组 | 通过项数 |
|---|---:|
| MetadataReadinessTests | 2 |
| RecoveryEvidenceCacheTests | 4 |
| RouteWriterTests | 5 |
| SessionPersistenceTests | 7 |
| WorkoutLifecycleTests | 18 |
| WorkoutRecoveryTests | 4 |
| 合计 | 40 |

持久化分组保持真实 SQLite：提交前失败、提交后丢响应、负面观察和取消持久化故障、同文件重开、原 token 重试与无持久化证据的新 gateway 行为全部由原 7 项测试覆盖；没有以默认成功或内存仓储替换。未增加只验证转发自身的镜像实现测试。

## 两位非作者 source 审阅

- `/root` 质量审 PASS：16 个方法的签名、参数、throws、结果及 identity 均转发相同 `inner`；剥离新增块后原文件严格相同；红 16 个缺失要求 / exit 1 和绿 40 项 / 0 失败证据已核。
- `/root/m2_review` 规格审 PASS：原 identity 实例保持、故障注入和断言不变、同实例逐参数转发，红绿日志及 source 内容哈希独立核对。

两审均绑定 source `59f439a6d59b926dcf2462f046f45c5513831b35`、组装基线 `1662eef45ed3eaacab9ac348e360817df5e666f6` 和临时目标登记快照 `be73b55e9c7d00cbdaefdebb518a4d30deee218a`。本组三文档最终 head 交付后另审，此处不预记通过。

## 外部证据及清单

持久目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-019`。

| 文件 | 内容 |
|---|---|
| `red-host-tests.log` / `green-host-tests.log` | 完整原始编译/测试输出 |
| `red-run.json` / `green-run.json` | 实际 cwd、命令、开始/结束时间、组装 HEAD 与退出码 |
| `red-summary.json` / `green-summary.json` | 16 缺失要求、40 项分组、差异计数与 source 哈希 |
| `SessionPersistenceTests.before.swift` / `SessionPersistenceTests.after.swift` | 修复前后字节快照 |
| `source.diff` | 唯一源码 16 行新增差异 |
| `source-reviews.json` | 上述两位非作者的 source 审阅绑定与结论 |
| `source-manifest.json` | 89 个实际 Git 输入及 10 项证据的 Git blob / SHA-256 / 字节数；范围为 WorkoutCapture、MatchCore 两个完整 package 目录，包含各自已跟踪文件，并非声明每个文件都被编译 |
| `final-manifest.json` | 文档提交后生成：实际 final SHA、同样 package 输入和三文档 Git blob、证据哈希；记录 final 文档待审，不预记集成 |
| `manifest-checksums.sha256` | source/final manifest 自身哈希，提交后保存 |

| 文件 | SHA-256 |
|---|---|
| `red-host-tests.log` | `1e293cc60a62e6b5b9b368ab468936ff396e1475feaff25f3f1673053e488471` |
| `green-host-tests.log` | `777db8ba8c447c990ad13d20f8e1e26fea7a4fdeab3f4cac52575f9a6d23a51f` |
| `source-manifest.json` | `dc1b94178a3f7dc4087e49bb306eb7e5dfd82e8a223442acdb9a9867bd3b4429` |

最终 manifest 与其哈希在文档提交后交付主代理，避免在同一提交内自引用提交 SHA。日志、快照与构建缓存不进入仓库。未保存凭据、签名资产或个人健康样本。

## 保留门槛

本任务的 40 项只证明当前组装 Core 上的 WorkoutCapture 宿主测试兼容及既有回归通过，不代表全 331 项整包、App 运行、平台 SDK 全矩阵或生产同步验收。真机不适用于纯测试替身兼容修复；008/010/016/018 的签名、安装、授权、GPS、后台、锁屏、恢复与真人体验门槛保持。未合并到 dev/release/main，不晋级发布；后续由主代理普通合入 NATIVE-018 临时整包并验证实际 merge SHA。
