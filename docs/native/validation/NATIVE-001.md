# NATIVE-001 验证记录

日期：2026-10-15；作者 `/root/native_foundation`；原始基线 `2d4616355221af0969e07e9b1f45852449cbb98e`，分支 `build/native-foundation`。记录随工程提交绑定，最终完整 head 由作者交付及主代理双审记录引用；本记录不宣称已合入 dev。

## 环境与命令结果

工作目录：`/Users/liam/.codex/worktrees/native-foundation/20260830_足球记录`。Xcode `27.0 (27A266a)`，Apple Swift `6.4 (swiftlang-6.4.0.34.1)`；使用 iOS / watchOS 27 SDK。项目语言模式 Swift 6，包 tools 6.0。最低系统仍为 iOS 17 / watchOS 10；macOS 14 是共享包的宿主编译下限。

作者执行 `scripts/native/verify.sh`，退出码 **0**。脚本依次运行：

```bash
swift build --package-path "$repo_root/native/Packages/MatchCore" --scratch-path "$build_root/SwiftPM"
xcodebuild -project "$repo_root/native/FootballRecord.xcodeproj" -scheme FootballRecord-iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build_root/DerivedData-iOS" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project "$repo_root/native/FootballRecord.xcodeproj" -scheme FootballRecord-Watch -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$build_root/DerivedData-Watch" CODE_SIGNING_ALLOWED=NO build
```

其中 `repo_root` 为上述工作目录，`build_root = $repo_root/native/.build`。SwiftPM 输出 `Build complete!`；两个 Xcode 日志均输出 `** BUILD SUCCEEDED **`，脚本输出 `Native verification passed.`。没有业务逻辑、测试 target 或业务测试；本任务未运行 `swift test`。静态身份常量由真实双端消费者编译，不增加镜像测试。

原始日志目录：`native/.build/logs/20261015T092639Z/`；已逐文件复制至工作树外 `/tmp/football-record-NATIVE-001/20261015T092639Z/`，归档 worktree 不会删除该副本。日志摘要：

| 文件 | 结果 / SHA-256 |
|---|---|
| `swift-build.log` | 成功；`ec29e37ca9c7f64159250ce90900979c58e8abee2b644389324bc0b852bce1d7` |
| `ios-build.log` | 成功；`5bf36e7577573675490269515c49214015021aff7b7860656d94b70de07f56b7` |
| `watch-build.log` | 成功；`7d499e0f34c7eedb0c0a1c1e157b67143992a340a0d311c2ea14401beaeacc8d` |

Xcode 共出现三条 `Metadata extraction skipped, no AppIntents.framework dependency found` 提示；本壳不实现 App Intents，未为了消除该提示引入框架或能力。没有编译错误。

## 工程与产物自验

- 只有两个 App target；Watch 是现代 `com.apple.product-type.application`，没有 WatchKit extension。共享 schemes 为 `FootballRecord-iOS`、`FootballRecord-Watch`。
- 两个 target 均通过 `XCLocalSwiftPackageReference` 指向 `Packages/MatchCore` 并链接 `MatchCore` 产品；实际 package graph 解析为本地路径。两个 SwiftUI 入口都引用 `AppIdentity`，产物中存在其符号。
- iOS target 依赖 Watch target；Embed Watch Content 使用 `dstSubfolderSpec = 16`、`$(CONTENTS_FOLDER_PATH)/Watch`，实际 iOS 产物中存在 `FootballRecord.app/Watch/FootballRecordWatch.app`，不是只有文件引用。
- iOS 产物 `CFBundleIdentifier = com.example.footballrecord`、`CFBundlePackageType = APPL`、`MinimumOSVersion = 17.0`、`UIDeviceFamily = [1]`。
- 嵌入和独立构建的 Watch 产物均为 `com.example.footballrecord.watchapp`、`APPL`、`MinimumOSVersion = 10.0`、`UIDeviceFamily = [4]`、`WKApplication = true`、`WKCompanionAppBundleIdentifier = com.example.footballrecord`。三个产物各有实际可执行文件。
- 双端 en / zh-Hans `InfoPlist.strings` 分别设置英文 `football-record` 与中文“球历”。项目未设置 Team、entitlements 或 HealthKit / CloudKit / Sign in with Apple 能力；Bundle ID 仅为本地占位，不代表已注册。
- `plutil -lint` 检查工程与两个 Info.plist、`bash -n scripts/native/verify.sh`、`git diff --check` 均通过；暂存后另检查完整新增文件差异和 whitespace。忽略规则仅覆盖 native 构建目录、SwiftPM 本地产物与 Xcode 用户状态，不忽略源码和本记录。

## 模拟器启动与界面

作者仅为本次验证创建 iPhone 18 Pro / iOS 27.0 模拟器 `C72EE3AF-1761-4276-B496-562B590F6ACF` 和 Apple Watch Series 12 (42mm) / watchOS 27.0 模拟器 `BF4FE046-067C-4DB0-AF7D-AD164FBD4A58`。`xcrun simctl boot`、`bootstatus -b`、`install` 与 `launch` 均返回 0；iOS 启动 PID 为 `9614`，Watch 为 `9725`。未配对模拟器，未验证通信。

启动日志 `/tmp/football-record-NATIVE-001/simulator-launch.log`；截图 `/tmp/football-record-NATIVE-001/ios-preview.png` 与 `/tmp/football-record-NATIVE-001/watch-preview.png`。作者已读取两张图：显示“球历”、`football-record`、“开发预览”与“尚未开始记录”，内容完整，无假健康 / 比赛数据，无正式开赛入口。两个自建临时模拟器在截图后关闭并删除；未操作已有用户模拟器。

## 验收边界

NATIVE-001 仅完成 M1 的工程基础。NATIVE-002 事件引擎、NATIVE-003 事务仓储 / outbox 尚未实现；不把模拟器预览称为真实比赛记录。真机不作为本次纯工程壳的合入门槛：没有设备采集或通信能力变更，用户暂不能连接真机。仍未验证签名、真实设备安装 / 启动、配对通信、采集、后台恢复、联网锁、云服务或分发；这些属于后续阶段。未推送、上传或发布。
