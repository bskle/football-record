# NATIVE-031 空账号控制检查点验证

日期：2026-10-19（上海）。原始 base `d59768f5f5d7872b9c520fd746d20f99f236acdc`，当前 target / 普通同步来源 `36daa5526aac447cedab8c0b636c2db80b09cfa6`；分支 `fix/m4-empty-cloud-checkpoint`；worktree `/Users/liam/.codex/worktrees/m4-empty-cloud-checkpoint/20260830_足球记录`；attachment `01a15018-11f6-7b32-abc0-4801d9774030`。source=final SHA 见树外 input-manifest.json，待 root+m2 同 exact SHA 双审。

原 CloudCheckpoint 将空 recordIDs 一律拒绝，真实空历史账号无法提交最终迁移 checkpoint。本次仅 CloudSync 增加 `CloudCheckpoint.account(scope:checkpointID:recordIDs:)` 与统一账号锚规则；控制 UUID 由调用方稳定持久化，锚为 `account-checkpoint:<scope.stableZoneKey>`，只允许此控制元数据使用空集合。CloudRecord 的 typed / raw / Codable 边界精确校验 account、cloudSpace、zone；普通 checkpoint 的非空、唯一、排序与编码规则保持。未使用023未审源码，未改合同、Core、AccountKit、App、工程或脚本。

| 层次 | 实际命令 / 日志 | 结果 |
|---|---|---|
| 运行时红 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-031-host --filter CloudAccountCheckpointTests`；`account-checkpoint-red.log` | 6项，10 failures（1 unexpected）：空账号真实 ledger/save/reopen 路径被 invalidPayload 拒绝，错误锚/跨 scope/import/非法控制ID原实现未拒绝；非空与legacy路径先红时已通过 |
| 完整绿 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-031-host`；`cloud-host-green.log` | 53/53，0 failure：6 AccountCheckpoint + 16 Conflict + 5 EventSequence + 3 IssueDecoding + 10 Ledger + 13 Service |
| 普通同步后完整绿 | 同一完整测试命令；`cloud-host-post-sync.log` | 53/53，0 failure；与初次53为分层重跑，不累计106 |
| 最低 iOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-031-ios`；`ios17-simulator-build.log` | fresh Build complete，exit0 |
| 最低 watchOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-031-watch`；`watch10-simulator-build.log` | fresh Build complete，exit0 |

六项新回归使用真实文件 SQLiteCloudLedger 与 ControlledCloudDriver：空账号只有一条 confirmed control checkpoint，无 matchFacts、terminal event 或 fetch batch；重复 enqueue/close/reopen 保留原 upload/record bytes、recordID 与 digest。非空账号先保存两条真实 facts，再以全部 confirmed recordID 构造控制记录，重开后原 facts bytes 保持。另覆盖错hash、跨 account/space/zone、同 stable zone 新 epoch、raw/Codable record 与 batch 导入、普通 match 空引用、重复引用、非法控制 UUID，以及 legacy 精确 canonical fixture。

迁移提交须绑定控制 **CloudRecord.recordID + CloudRecord.digest（canonical bytes 摘要）**；CloudCheckpoint.checkpointID 为稳定控制 UUID。CloudUpload.checkpointID 继续是 asset manifest ID，原全部有序 part 引用、完整原 bytes / digest 及受控 save 约束未改变，完整53项中保留原47回归。调用方仍须核验 recordIDs 等于当前完整已确认业务 facts 集合，控制元数据不代替同 facade 业务核验。

工具：Xcode27.0 / Swift6.4，SDK27.0，编译 triple 保持 iOS17/watchOS10；完整工具版本见 tools.txt。最终host与双SDK日志无 warning。真机不适用：本次仅隔离 checkpoint 值/边界兼容，不启用生产 App 或改变 SDK 调用。受控 development save 不等于真实 CloudKit、生产 proof、账号/设备或023业务桥整体验收。

031 coherent fix 后普通同步已集成030的当前dev；030只改 backend/合同/两卡。同步组合的 CloudSync + MatchCore 共41项 package/source 编译输入逐 hash 与本轮 fresh 双SDK一致，原始 base 保留。完整host在同步后重跑，SDK证据保留此实际输入层次。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-031`。保留初始/最终六项 Git 输入、源码/编译输入 hash、原红绿/双SDK日志、input/evidence SHA256 manifest。单轮53不与历史47混加；作者 clean 停写后交 root+m2 双审，不自行推进长期分支或合入长期分支/push/archive。
