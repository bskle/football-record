# NATIVE-040 验证

source `ea3d57e2bf84f1d2848b2fb632f0a2d98e66c9a4` 已 root + cloud exact source PASS；final 两卡同HEAD复核另存。原base `2cab4640ee3a375da39fdabf0f5a317600b0c263`、稳定依赖 `40417c61058d7653737ceb23b821f11ba75e53c8`、实际初始merge `7007d7b68167659da6a44e759126a39cd6af0b58`、held target `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55` 分开保留。[任务卡](../tasks/NATIVE-040.md)和[计划](../../superpowers/plans/2026-10-20-m4-watch-registration-relay.md)限定五路径。

| 层次 | 原始日志与实际结果 |
|---|---|
| 基线 | 初始tree与039 `de68f7f777b373c14363173a15fe9bcd6dddee5c` 及327输入一致，复用原28/0；不是040新运行 |
| typed转发 | API编译红独立；最小unavailable外壳后040-1-runtime-red为4项6失败（1 unexpected）→040-1-green的4/0 |
| 生命周期 | 040-2-final-runtime-red为8项12失败→040-2-green的8/0；endpoint cancel独立040-2-cancel-red为1项1失败→040-2-final-green同轮9/0 |
| HTTP/SQLite组合 | 040-3-first-http为13/0；追加真实持久identity fence的迟到回复组合后040-3-final-green为14/0 |
| 完整相关回归 | full-host.log实际单轮42/0（原28+新14），不相加以上轮次 |

两次早期生命周期红灯中，test helper未结算迟到进入或关闭后错误复用而挂起，仅终止本任务的已定位xctest，原日志保留；不将挂起当产品通过。API红的原wrapper测试结束后误用zsh只读status变量，编译错误原log完整，后续使用run_code。树外保留测试/最小外壳写入前的部分快照；TDD日志是历史层，不宣称均运行于final源码。最终完整运行前固定所有输入。

14项新测试覆盖 typed correlation/requestID/digest/action和超限拒绝、非canonical attempt、默认不可用、close并发合并/owned任务join/迟到拒绝、caller原correlation cancel、endpoint重复correlation和取消结果。真实Node HTTP fixture配合独立Phone/Watch SQLite验证：原body与submit/recover、每次fresh Phone PoP、Watch credential仅安装Watch vault且不进入业务文件；已commit回复丢失后关闭/重开沿原pending恢复、未知时不换ID；404/401/timeout不关闭pending；过期未提交原attempt仅凭pinned签名knownAbandoned封闭；真实Watch持久identity fence后晚到凭据不安装。测试只调用既有软件fixture，不执行真实WC/Apple/账号。

完整host命令为 `swift test --package-path native/Apps/iOS/Integration --scratch-path /private/tmp/football-record-NATIVE040-build/Host`。四SDK命令为 `xcrun swift build --package-path native/Apps/iOS/Integration --target AppIntegration --triple <下表> --sdk <实际xcrun路径> --scratch-path /private/tmp/football-record-NATIVE040-build/<层>`。

| Triple | 实际结果 | 日志 |
|---|---|---|
| arm64-apple-ios17.0-simulator | Build complete /exit0 | full-ios-sim.log |
| arm64-apple-ios17.0 | Build complete /exit0 | full-ios-device.log |
| arm64-apple-watchos10.0-simulator | Build complete /exit0 | full-watch-sim.log |
| arm64-apple-watchos10.0 | Build complete /exit0 | full-watch-device.log |

四SDK均fresh scratch，只编译AppIntegration及依赖；host单独缓存目录同source执行。原始argv、时间、exitCode、各log SHA见 `source-commands.json`。Node22.23.1 SQLite ExperimentalWarning、macOS CoreData/Contacts helper诊断与既有Core LifecycleInboundCoordinator.swift23/33 unused repository警告保留，不称零诊断。未改或调用用户联系人API，未执行真实SDK、签名、安装或设备操作。

树外 `native-validation/NATIVE-040/source-aggregate-manifest.json` SHA256 `bde5853f86228cd571d55f8d8712745c06363251c9103afe63986f1e94efdaa7` 绑定31份证据、6Git对象/5owned输入。`source-input-manifest.json` 固定329项tracked native/backend/scripts保守输入（含真实Node fixture和backend support，超集不冒称每文件均执行），逐Git字节/mode/blob及运行后hash零差异。source与final产品相同证明、最终两卡/链接/clean状态和非作者审阅由final aggregate另存，不回写旧source证据。

本组件只交付controlled typed登记通道，真实WC控制RPC、配对/账号/Keychain/签名环境及026composition全部后验；不放宽既有AccountKit签名、knownAbandoned或identity gate。默认Unavailable，不称生产身份、整包026或M4完成；不合dev/发布。
