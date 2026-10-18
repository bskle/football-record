# NATIVE-029 云事件序号兼容验证

日期：2026-10-19（上海）。base=target `03dbd35bd467a4a7334e2d1acf561af575935a86`；分支 `fix/m4-cloud-event-sequence`；worktree `/Users/liam/.codex/worktrees/m4-cloud-event-sequence/20260830_足球记录`；attachment `01a14ff0-e98b-7801-9fa4-9a2a5b4b2b28`。最终 source/final SHA 见树外 input-manifest.json，双审待主代理安排。

根因与最小修复：真实 `LiveMatchRecorder.start` 的首事件 sequence=0，而 CloudMatchFacts 误要求 >0。产品只改该条件为 >=0；保持 Core、DTO、canonical/hash 域、负数/重复等原防线。没有改 AccountKit、工程、脚本或其他文档。

| 层次 | 实际命令 / 日志 | 结果 |
|---|---|---|
| 运行时红 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-029-host --filter CloudEventSequenceTests`；`event-sequence-red.log` | 5项中2项失败：真实 recorder 首事件0和完整0/1/2事实均抛 invalidPayload；其余3项通过 |
| 完整绿 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-029-host`；`cloud-host-green.log` | 47/47，0 failure：16 Conflict + 5 EventSequence + 3 IssueDecoding + 10 Ledger + 13 Service |
| 最低 iOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-029-ios`；`ios17-simulator-build.log` | Build complete，exit0 |
| 最低 watchOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-029-watch`；`watch10-simulator-build.log` | Build complete，exit0 |

本次五项新回归不手写合法首场 sequence1：首场和完整比赛均由真实 recorder 产生；完整比赛进入真实 SQLiteCloudLedger 后 close/reopen，逐 bytes 比较 upload/record 与 digest/recordID/factDigest 保持。既有1起始数据仍可解码且原 bytes/digest 不改；负数和同一 recorder 的重复0仍 invalidPayload。

工具为 Xcode27.0 / Swift6.4，最低 triple iOS17/watchOS10；完整工具版本见 tools.txt。最终 host 与两项 SDK 日志无 warning。真机不适用：本次为隔离 CloudSync 纯值校验修复，未启用生产 App 或改变 SDK 行为；编译不代表真实 CloudKit、生产 proof 或023同facade桥已验收。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-029`。保存初始/最终六项 Git 输入、产品最小差异、原红绿/SDK日志、源码与编译输入 hash、evidence SHA256 manifest；单轮47不与历史022的42混加。作者 clean 停写，source=final 交 root+m2 exact 双审，不自行 merge/push/archive。
