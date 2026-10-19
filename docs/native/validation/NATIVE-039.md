# NATIVE-039 验证

source `9b6de569d53ff6ebcf0292a2c1041e6fec29e68a` 已 root + m2 exact source PASS，限 held026 的本机独立桥；final 两卡待同 HEAD 复核。原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`、稳定依赖 `40417c61058d7653737ceb23b821f11ba75e53c8`、实际普通合并输入 `de68f7f777b373c14363173a15fe9bcd6dddee5c` 与 held target `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55` 分开保留。[任务卡](../tasks/NATIVE-039.md)和[计划](../../superpowers/plans/2026-10-20-m4-health-deletion-bridge.md)列出五路径所有权。

## 实际红绿

| 层次 | 实际结果与原日志 |
|---|---|
| 基线 | root 完整 AppIntegration28/0，327 conservative inputs before/post0，18 prepared API blobs/hash一致 |
| slice1 | 7项/14失败（5 unexpected）runtime red →7/0；再实际 Core start→recover→restart→finish 1项/1失败 →最终同轮8/0。日志 slice1-red、slice1-recovery-red、slice1-final-green |
| slice2 | 同轮16项/7失败（6 unexpected）runtime red →16/0。日志 slice2-red、slice2-final-green |
| slice3 | 同轮23项/21失败（3 unexpected）runtime red →23/0；追加并发及精确本地count0后同轮25/0。日志 slice3-runtime-red、slice3-final-green |
| 完整相关回归 | `swift test --package-path native/Apps/iOS/Integration --scratch-path /private/tmp/football-NATIVE039-host`，实际单轮53/0，含原28与新25，不相加旧轮。日志 full-host |

各 slice 先有 missing API 编译失败日志，再最小 scaffolding 后取得 executable red。slice2-green 为历史编译失败，最终通过只引用 slice2-final-green。slice3-red 的受控 completion helper在尚未派发时越界导致signal5，已保留原log并修helper；完整可计数的红灯为 slice3-runtime-red，不把该崩溃当产品通过。全部原日志未覆盖。

新25项覆盖实际 Core 原 externalToken（含 recover/restart 与 gap/旧 sibling）、opaque segment ID、raw Unicode binding、来源/覆盖/冲突/超限/空集合；真实 SQLiteSessionRepository 原 parent；test-only SQLite mapping 写前回滚/COMMIT丢响应和重开原 bytes；真实028 submit/confirm提交丢响应、first confirmation、request bytes/digest与双ledger重开；full seal/backend/原parent门禁、同parent并发、first receipt/本地count0、timeout迟到、close/reopen interrupted、旧callback不改新owner、failed+outcomeUnknown不重派及已知authorizationDenied沿原request重试。

## 最低 SDK 产品编译

每条实际命令为 `xcrun swift build --package-path native/Apps/iOS/Integration --target AppIntegration --triple <下表> --sdk <xcrun对应SDK实际路径> --scratch-path /private/tmp/football-NATIVE039-<层>`；完整 argv/SDK路径和各原日志 SHA 见树外 commands.json。

| Triple | 结果 | 原日志 |
|---|---|---|
| arm64-apple-ios17.0-simulator | Build complete | ios-sim.log |
| arm64-apple-ios17.0 | Build complete | ios-device.log |
| arm64-apple-watchos10.0-simulator | Build complete | watch-sim.log |
| arm64-apple-watchos10.0 | Build complete | watch-device.log |

四项均 fresh scratch；只编译 AppIntegration 及其依赖，不执行 SDK、签名或安装。Core 既有 LifecycleInboundCoordinator.swift 第23/33行 unused repository警告保留且输入未变，无039新警告。未重跑 Node/所有叶包测试或整 App/UI，不借此声明整包通过。

## 输入与限制

source-input-manifest 绑定139 build /146 host文件，另 conservative-inputs 保留 root 原327零差异+新source/test共329；全部 host与四SDK运行后 hash零差异。source-git-proof保留7 Git对象、5授权Git文件。source-aggregate-manifest SHA256 `c2af16170badf392ea01d3ae84bfc59aaad905280630d9c0720240242c47f4ce` 绑定34份证据；final aggregate另外绑定仅两卡提交、最终clean状态与source/final产品相同证明，不回写自SHA。证据位于树外 `native-validation/NATIVE-039`，不以日志文件名猜通过。

本任务为纯装配/持久契约与受控 driver 软件验证，未调用 HKHealthStore、来源查询、授权、真实账号或设备；真机无本任务执行结果。默认 unavailable。test-only file-backed mapping不证明026生产 journal/capsule/full seal已接入，caller必须提供受验收的真实平台来源与全 seal持久读回。wrapper比028叶层更保守，interrupted/outcomeUnknown不得自动新attempt；原 entry/UUID/first receipt保留。Health失败独立，count0只描述精确本地范围，不能声称全 owned、全本地、全设备或远端已空。真实 Health/权限/设备与026全catalog组合仍待，M4未完成。
