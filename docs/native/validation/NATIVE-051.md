# NATIVE-051 validation

状态：source `183601ac74af3ab7565932eb4a952a41ea7d5097` 已精确 source 双审 PASS；本次仅两卡收尾，最终文档双审待完成。见 [任务卡](../tasks/NATIVE-051.md)、[计划](../../superpowers/plans/2026-10-20-m4-debug-material-inbox.md) 与 [M4合同](../contracts/m4-account-lock-cloud.md)。

原生独立树 branch `feat/m4-debug-material-inbox`；base `2cab4640ee3a375da39fdabf0f5a317600b0c263` + accepted043 final `cfeefe85b1489227664a3bc19b9c6c78367e581e` → effective `ddb659f37cfdaf3a154a59859b63649c46818ec2`。仅 held026 登记目标 `eb05eaf2c4521ccd0406a1d3e1bb599952ec9609`，不推进长期分支。依赖历史88/四SDK不当051新运行。

## 同源最终自动验证

- `swift test --package-path native/Modules/MatchPresentation --scratch-path /private/tmp/football-record-NATIVE051-build/full-host --jobs 4`：单轮 **105 tests / 0 failures**，原88 + 新10材料 + 新7inbox。完整日志 `source-full-presentation.log`；focused运行不相加。
- 四 fresh `MatchPresentation` 产品：`arm64-apple-ios17.0-simulator`、`arm64-apple-watchos10.0-simulator` 各 Debug/Release，明确 Xcode27.0 SDK、独立 scratch、`swift build --target MatchPresentation --jobs 2`，全部实际exit0/Build complete。
- 普通 `import MatchPresentation` / `AccountKit`、Swift6 typecheck直接使用上述四套实际产物：Debug两项exit0；Release两项预期exit1，明确找不到 DEBUG-only material/scenario类型，非模块缺失。没有 `@testable` 或真实API执行。
- 全部9个命令冻结同一source，241 tracked runtime/backend/scripts输入 before/post/Git/working 无差异；84实际swiftmodule/swiftdoc/ABI artifacts及消费者源码另绑 SHA。原 `LifecycleInboundCoordinator.swift:23/33` unused repository 警告保留，不称零诊断。

## 行为与历史失败分层

材料 API编译RED、minimal-unavailable runtime 9项7失败是可用性RED；最终10项核 first vault先DB、原ID/key/pin/credential/generation、两handle实际casealias、全部partial/sidecar/缺坏保全。初alias测试把交错低generation误当应成功，10项49断言失败为测试前提错误；同产品修正断言后10/0，不冒称安全RED。

inbox API编译RED及minimal-unavailable 4项4失败单列；首实现4项1断言失败实际揭示替换原request回调拒绝后下一poll重新接纳，永久fence修复后4/0。最终7项含 cancellation-insensitive handler stop/join、success/error原request及目录替换门、401/404/timeout不能造knownAbandoned、stop后Cloud-delete继续。

真实原AccountKit服务经本机Node RSA/HTTP/SQLite软件fixture与原mailbox：Phone原signIn、Watch register实际COMMIT丢响应、关旧Watch客户端/DB、同原ID/key/DB重开recover原canonical及首次receipt；Phonevault保持原Phone凭据。首broker重复转发已完成context造成1项1断言失败是test-only fixture问题，修正后1/0并纳入最终105。没有真实Apple网络或真实独立身份provider；每请求受控admission只是026注入契约。

## 证据与双审

树外 `native-validation/NATIVE-051/source-aggregate-manifest.json` SHA256 `d6d38a084aeb3674d0e91c1932b45d4baeaff3b9fa00a3e5604633653a33bb31`，107证据/7Git/6owned；保留原logs、逐命令argv/inputs/post、RED源码快照及三份分层notes。原Runtime make/privateWrite和phone-migration dispatch逐bytes核对保留。四项原本地链接通过；本次两卡追加合同链接后共六项。

root `source-review-root.json` SHA256 `49632ce28a62511c25b7d9ac55a0c4aa46754d7ce98ffc91de0584753d082c0b`；cloud `review-source-cloud.json` SHA256 `70ee323d8fd1075dd825aa7739278a46919fdc748669c0b32cb15c5145c9ff64`，两位非作者均 source PASS_HELD_026。仅两卡final，产品/测试/计划、107证据/241输入/9命令/84产物不变，无重跑声明；最终aggregate与最终双审另存，不预填merge。

真实 Apple/Keychain/iCloud/CloudKit/Health/WC、账号/设备/签名/掉电/部署、App/UI、production Mapping/身份及whole026未验。文件fsync/目录barrier不表示物理掉电保证；共享材料gate仅同进程，026原namespace owner lease须跨全部使用。候选held026，production默认Unavailable保持。
