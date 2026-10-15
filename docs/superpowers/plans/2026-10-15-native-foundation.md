# 球历原生工程基础执行计划

> 执行者：`/root/native_foundation`。本任务已有精确规格与本地执行授权，按下列步骤实现和验证，由两位非作者审阅后交主代理集成。

**Goal:** 建立 iPhone / Apple Watch 可构建的 SwiftUI 开发预览壳，以及双端实际使用的单个本地 MatchCore 包。

**Architecture:** Xcode 工程有 iOS App 和现代单目标 watchOS App；iOS 嵌入 watch 产品。`MatchCore` 仅提供共享产品身份，不引入比赛、采集、网络或存储实现。英文名 `football-record`、中文名球历，技术工程名 `FootballRecord`。

**Tech Stack:** Xcode 27、Swift 6、SwiftUI、SwiftPM tools 6.0；最低 iOS 17 / watchOS 10，包允许 macOS 14 宿主构建。

## 执行基线与所有权

- NATIVE-001，`base_ref = dev`，原始 base / 创建时目标 SHA：`2d4616355221af0969e07e9b1f45852449cbb98e`。
- 临时分支 `build/native-foundation`；合并目标 `dev`。受管 worktree identityKey 与绝对路径均为 `/Users/liam/.codex/worktrees/native-foundation/20260830_足球记录`；开写前实际 HEAD 与上述 base 一致、状态 clean。
- 唯一写入负责人 `/root/native_foundation`；主代理 `/root`；非作者审阅者 `/root` 与 `/root/environment_check`。共享 `project.pbxproj`、scheme、target 与配置由本作者串行修改。
- 所有权：`native/FootballRecord.xcodeproj/`、`native/Configuration/`、`native/Apps/iOS/`、`native/Apps/Watch/`、`native/Packages/MatchCore/`、`native/README.md`、`scripts/native/`、`.gitignore`、本计划、`docs/native/tasks/NATIVE-001.md`、`docs/native/validation/NATIVE-001.md`。
- 不修改原型、产品方案、治理文档、其他任务卡或其他 worktree，不合并长期分支、不推送。主代理补充授权仅同步 `docs/development-readiness.md` 的工程当前事实和母计划阶段表 M1 行，不改产品范围或历史快照。

## Task 1：登记与共享入口

- [x] 写本计划和任务卡，核对 SHA / 目录 / 所有权后作独立文档提交。
- [x] 创建 `native/Packages/MatchCore/Package.swift` 与 `Sources/MatchCore/AppIdentity.swift`：唯一产品 `MatchCore`，只暴露中文名与英文名；无外部依赖、无比赛功能。
- [x] 包使用 `.iOS(.v17)`、`.watchOS(.v10)`、`.macOS(.v14)`，Swift tools 6.0。静态身份常量不新增镜像测试，实际消费者编译证明入口可用；尚无业务测试。

## Task 2：双端工程壳

- [x] 创建 `native/FootballRecord.xcodeproj/project.pbxproj` 和共享 `FootballRecord-iOS`、`FootballRecord-Watch` scheme。两个 App target 链接同一个本地包产品；iOS 的 Embed Watch Content 与 target dependency 包含 Watch App。
- [x] iOS / Watch 各用独立 SwiftUI `@main` 入口与空状态视图，显示共享名称及“开发预览”“尚未开始记录”；不显示假健康数值，不提供正式开赛入口。
- [x] 创建显式 Info.plist 和 en / zh-Hans 显示名称。Watch 设置 `WKApplication = YES` 与 `WKCompanionAppBundleIdentifier = com.example.footballrecord`，不建旧 WatchKit extension。
- [x] 使用 `com.example.footballrecord`、`com.example.footballrecord.watchapp` 本地占位 Bundle ID；无 Team、entitlements 或付费能力，不接 HealthKit / CloudKit / Sign in with Apple。只设置最低系统与 Swift 6 等本任务所需配置。

## Task 3：可重复构建与交付

- [x] 创建 `scripts/native/verify.sh`，`set -euo pipefail`；项目缺失或任一构建失败立即返回非零，不作 skip。以脚本位置定位仓库，可从任意目录调用。
- [x] 依次执行 `swift build --package-path native/Packages/MatchCore`；`xcodebuild -project native/FootballRecord.xcodeproj -scheme FootballRecord-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`；Watch 对应 `FootballRecord-Watch` 和 `generic/platform=watchOS Simulator`。DerivedData / 包缓存隔离在 ignored `native/.build/` 下。
- [x] README 说明命令、签名占位、M1 未完范围与真机待验。`.gitignore` 仅追加真实 SwiftPM / DerivedData / xcuserdata 产物。
- [x] 运行完整脚本并保存本地原始日志；核对退出码、包引用、target dependency、watch 嵌入与 Info.plist；运行 `git diff --check`，将结果和限制写入验证记录。
- [x] 按明确路径暂存并提交工程基础与实际证据，交付完整 HEAD 与提交清单。两位非作者针对最终 SHA 审阅及主代理集成仍按任务台账继续处理，不提前声明已集成。

## 后续 M1 子任务

| 任务 | 边界与后续验收 |
|---|---|
| NATIVE-002 共享事件引擎 | 扩展同一 `MatchCore` 包内业务 target；确定事件 / 更正 / 回放 / 可注入时钟契约。先写首发替补、暂停恢复、跨日、未闭合、计分更正、1000ms 防重、撤销与生涯筛选等确定性失败测试，再实现。不得依赖 UI、HealthKit、网络或本任务未实现的仓储。 |
| NATIVE-003 事务存储与 outbox | 在同一个包内新增 `MatchStore` target / 产品边界，单独确认 SQLite 适配与事务方案，依赖 NATIVE-002 已审阅契约；覆盖迁移、失败不显示成功、重启重放、幂等重复、破损恢复、检查点与持久化 ACK 后清理 outbox。共享工程变更仍由明确工程所有者串行注册。 |

本任务不是全部 M1；没有比赛引擎、SQLite、真实采集、设备同步、账号或联网锁。后续加入业务测试时将脚本包检查升级为 `swift test`。用户暂不能连接真机，不阻塞本次工程与 SDK 构建；签名安装、配对通信、真实采集和发布仍待对应阶段验收。
