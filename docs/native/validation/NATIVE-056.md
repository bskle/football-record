# NATIVE-056 验证记录

状态：source `ee3e4fc469074f21e819c27421e9af740bd2b62e` 已实现、作者验证并获两位非作者 whole source PASS；本次 final 只更新本卡和 [任务卡](../tasks/NATIVE-056.md)，等 exact final 双审后由 root 接入 held026。产品/测试/计划保留 source bytes。

- original/effective base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；plan `d3bc96fd510c775934e1b6ec0cfcd1012806f585`。
- branch `fix/m4-account-final-publish`；tree `/Users/liam/.codex/worktrees/m4-account-final-publish/20260830_足球记录`；attachment `01a16197-99bc-71f0-9989-31f43c8d06d6`。
- 具体接口、测试代码、所有权及命令依据 [已双审计划](../../superpowers/plans/2026-10-22-m4-account-final-publish.md)。source 两路径 +143/-2，其中 model +13/-2；不含其他实现或配置变更。
- 实际 Xcode **27.1**（27A9275），Apple Swift **6.4**（swiftlang-6.4.0.34.1）。最低部署版本保持 iOS17 / watchOS10。

## 原始分层证据

每条命令开始前直接复制四个包 MatchCore/AccountKit/CloudSync/MatchPresentation 的164项 tracked Package/Sources/Tests/Fixtures，保存 git mode/index blob/current blob、SHA256、bytes、literal argv、cwd、工具版本、raw log、exit与实际XCTest summary；执行后再次读取并直接保存，均0漂移。temporary diagnostic产品状态的输入副本保留，不作为最终代码。

| 目录（E/NATIVE-056下） | 目的及实际结果 | 与最终source的关系 |
| --- | --- | --- |
| baseline-original-api | 原 API held-read真实期限跨越；1 test/0失败，exit0 | 只加原API兼容基线，产品仍原 bytes；基线通过不称缺陷RED |
| compile-red-missing-api | 新 guarded tests 对旧产品编译，extra/incorrect finalCheck argument，exit1 | 无XCTest执行，不称runtime RED |
| runtime-red-ignored-veto | 临时 API-shaped implementation 未调用veto；2 tests/17 assertion failures/0 unexpected，exit1 | 明确的暂存外诊断状态；未提交，证明过期与收紧测试能捕捉忽略veto |
| runtime-red-missing-post-callback-guard | 已调用veto但缺 callback 后token重核；1 test/7 assertion failures/0 unexpected，exit1 | 明确的未提交诊断状态；pause/stop/reload被旧赋值覆盖 |
| targeted-account-green | 正确实现全部 AccountStatusTests，16 tests/0失败，exit0 | 产品/测试字节与最终source相同，focused已含于full，不叠加 |
| source-presentation-full | source固定后隔离fresh scratch完整Presentation；79 tests/0失败/0 unexpected，exit0 | 唯一完整host计数，本次新增5tests已在79中 |
| source-sdk-ios-sim | MatchPresentation arm64-apple-ios17.0-simulator，exit0 | SDK编译；非设备验证 |
| source-sdk-ios-device | MatchPresentation arm64-apple-ios17.0，exit0 | generic device SDK编译；无签名安装 |
| source-sdk-watch-sim | MatchPresentation arm64-apple-watchos10.0-simulator，exit0 | SDK编译；非设备验证 |
| source-sdk-watch-device | MatchPresentation arm64-apple-watchos10.0，exit0 | generic device SDK编译；无签名安装 |

两类 runtime RED 都由已编译执行的断言产生，不包含编译错误。过期测试在实际 read barrier前断言真实Date仍早于expiresAt；待真实Date达到期限才释放 barrier，ContinuousClock仅限制等待，不注入生产时钟，不凭固定yield数判断完成。重入回调真实调用公开 pauseIdentity/stop/requireReload；最终必须抛identityChanged且不能发布ready。

## 最终source命令

完整宿主只运行一次下列无filter命令，raw log确认为79/0；不加旧基线、focused或其他任务计数：

```sh
swift test --package-path native/Modules/MatchPresentation --scratch-path /private/tmp/football-record-NATIVE056-presentation-full
```

四项SDK编译分别使用独立scratch，实际绝对SDK路径及argv已写对应command.json/result.json：

```sh
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator --scratch-path /private/tmp/football-record-NATIVE056-sdk-ios-sim
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --triple arm64-apple-ios17.0 --scratch-path /private/tmp/football-record-NATIVE056-sdk-ios-device
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --triple arm64-apple-watchos10.0-simulator --scratch-path /private/tmp/football-record-NATIVE056-sdk-watch-sim
xcrun swift build --package-path native/Modules/MatchPresentation --target MatchPresentation --sdk "$(xcrun --sdk watchos --show-sdk-path)" --triple arm64-apple-watchos10.0 --scratch-path /private/tmp/football-record-NATIVE056-sdk-watch-device
```

以上为可重现shell表达；本次driver实际通过subprocess argv调用xcrun解析SDK后，再以绝对SDK路径执行swift build，未让shell重解释凭据或内容。四SDK不运行XCTest，不能称4项设备测试。

## 固定输入、审阅与final不变性

- `E/NATIVE-056/source-inputs-ee3e4fc.json`：164行，当前原文件、committed source Git mode/blob及直接full-before副本逐字节一致；fresh full+四SDK的全部before/after manifest相同。focused前的index blob属于未提交基线，current blob/hash与source相同；不将两者混称同index。
- `source-checkpoint-ee3e4fc.json` SHA256 `713b3c719f06ebcf61c23612f10a71ebdb183b5b2ea5577b1a7728d561da9cc9`。
- `source-evidence-manifest-ee3e4fc.json` 列3338个作者证据文件；日志、direct copies、执行结果、原plan三文档副本与diff均保留。final新增文档/checkpoint不改该固定manifest或任何已列证据。
- root whole source PASS report SHA256 `4b6c3a077b1afdfb1c1642408f4d71d543d172ae2d8c178fbfd119828807c14d`；recovery whole source PASS report SHA256 `8c4d42209c3ded5719113bdb4330ae6b9181cf627ef8c1f1a25c64413f98af0f`。报告为 `whole-source-review-root-ee3e4fc.json`、`source-review-recovery-ee3e4fc.json`，均无findings。
- final只两卡的实际SHA、parent/source、164 source/current/Git对等、3338证据未改、全树其余路径不变与clean（含ignored）在final checkpoint生成时逐项重核，不预填自SHA。root另行进行exact final双审、actual merge及相关Presentation/Integration复验。

`E=/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation`。Source稳定后无额外产品更改；计划不回写完成勾选，避免改变已审计划bytes。

## 限制

原 Core `LifecycleInboundCoordinator.swift:23/33` 两处unused repository binding warning在fresh host/SDK日志出现，文件与base原bytes一致；没有跨所有权修改。所有新model/test输入已通过上述验证。

真机不适用：本任务只改软件查询投影同步否决，不调用设备功能。未执行其他包host、App/XCUI、真人VoiceOver、Apple/iCloud/CloudKit/Health/WC、签名安装、真实设备或部署。原API保留no-op附加检查以兼容旧consumer；新callback仅能额外拒绝，不认证或授予recording。026尚未在本任务消费新接口，其独立当前身份、原credential/full tuple、资源owner/pair seal、整包及真实能力验收仍单独安排；不声称external identity/SQLite/vault全局原子、未来TTL lease、M4完成或原生发布。
