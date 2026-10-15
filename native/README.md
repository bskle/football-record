# 球历原生工程

正式名称：球历 / `football-record`；Xcode 技术名：`FootballRecord`。

用 Xcode 27 打开 `FootballRecord.xcodeproj`，选择共享 scheme `FootballRecord-iOS` 或 `FootballRecord-Watch`，再选择相应模拟器运行。最低系统为 iOS 17 / watchOS 10；项目使用 Swift 6。Watch 是现代单目标 App，iOS target 会构建并嵌入 Watch 产品。

从仓库任意位置调用脚本：

```bash
/path/to/repository/scripts/native/verify.sh
```

在仓库根目录也可运行 `scripts/native/verify.sh`。脚本依次执行共享包 `swift build`、iOS Simulator 与 watchOS Simulator 无签名构建；任何一步失败都返回非零。构建产物、DerivedData 和逐次日志位于已忽略的 `native/.build/`。可用 `NATIVE_BUILD_ROOT=/absolute/path` 改用独立目录。仅共享入口宿主编译可运行：

```bash
swift build --package-path native/Packages/MatchCore
```

两个 App 都实际链接 `MatchCore` 产品，并从 `AppIdentity` 显示身份。当前只有明确标记“开发预览”的空状态，没有开赛入口、健康数据或已记录比赛。尚无业务逻辑与业务测试；NATIVE-002 扩展同一包的事件引擎，NATIVE-003 在同一包建立事务存储 / outbox，加入测试后再将脚本升级为 `swift test`。本任务只完成 M1 工程基础，不代表 M1 全部完成。

## 签名与真机

`com.example.footballrecord` 和 `com.example.footballrecord.watchapp` 是本地开发占位 Bundle ID，不代表已注册。工程没有 Developer Team、entitlements、HealthKit、CloudKit 或 Sign in with Apple 能力。`WKCompanionAppBundleIdentifier` 与 iOS 占位 ID 一致；后续正式配置 ID 时须同时修改该键及两个 target。

用户能够连接配对的 iPhone / Apple Watch 后，在 Xcode 登录 Apple 账号，为两个 target 选择本人的 Team，配置可用的 App ID 和签名；设备解锁并信任 Mac，按系统提示开启开发者模式，再选择真实 iPhone / Watch 运行。账号授权和 Team 归属由用户完成。本次不需要该步骤来构建模拟器；付费账号能力和分发资格不能由模拟器构建推断。

尚待后续验收：真机签名安装与启动、配对通信、真实采集、后台恢复、联网锁和分发。无签名 SDK 构建不替代这些证据。NATIVE-001 的实际命令结果见 `../docs/native/validation/NATIVE-001.md`。
