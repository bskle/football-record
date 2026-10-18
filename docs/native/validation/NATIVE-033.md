# NATIVE-033 单云台账本地传输清理验证

日期：2026-10-19（上海）。原始base `ef10b33a10663ad94b0bb4a3e43106af108c38bb`；current target / 普通同步来源 `aa9977805dfb172cf1ece605d1f575cf7684df72`；分支 `feat/m4-local-transport-erasure`；worktree `/Users/liam/.codex/worktrees/m4-local-transport-erasure/20260830_足球记录`；attachment `01a1502d-7e43-78e2-9f4e-0271040e9f06`。修订后source/final SHA 见树外 `NATIVE-033/S33-1/input-manifest.json`，待root+m2新exact双审。

以下75项与对应SDK表为旧source `15a6e8e1ec77e30899a629c99e3e921e13e10a22` 的历史层次；m2发现S33-1 Unicode identity阻断，旧source/manifest/原日志及BLOCK保留，不能将旧75称为修订后通过。

| 层次 | 实际命令 / 原日志 | 结果 |
|---|---|---|
| 原实现运行时红 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-033-host --filter CloudLocalTransportErasureTests`；`persistent-fence-red.log` | 2项/9 failures，0 unexpected：持久fence、新epoch及enqueue/conflict/stage未受保护 |
| SQLite TEXT运行时红 | 同命令使用 `--filter testNulSuffixedAndInvalidUTF8ControlTextCannotProduceEraseReceipt`；`strict-text-red-2.log` | 1项/14 failures，0 unexpected：NUL后缀被C字符串截断，错误产生receipt或删除；随后按column_bytes严格UTF8/NUL解码修复 |
| 控制一致性运行时红 | 同命令使用 `--filter testReceiptWithoutItsPersistentFenceCannotReplayOrResumeTransport`；`control-consistency-red.log` | 1项/4 failures，0 unexpected；receipt缺永久fence时不能继续重放成功或恢复传输 |
| coherent host绿 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-033-host`；`cloud-host-final-green.log` | 单轮74/74，0 failure；后续增加一项错误重试竞态回归 |
| 普通同步后host绿 | 同一完整测试命令；`cloud-host-post-sync.log` | 单轮74/74，0 failure；与前74为分层重跑，不累计148 |
| 错误重试竞态红 | 同测试命令使用 `--filter CloudErasureRetryRaceTests`；`retry-erasure-race-red.log` | 1项/1 failure（1 unexpected）：purge在错误路径检查之后、retry保存之前提交，原路径抛invalidPayload；修后返回accountChanged terminal outcome |
| 最终完整host绿 | 同一完整测试命令；`cloud-host-final-75.log` | 单轮75/75，0 failure：原53 + 新22；无warning，已包含032同步组合 |
| 最终最低iOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-033-ios-race`；`ios17-simulator-final-75-build.log` | fresh Build complete，exit0；无warning |
| 最终最低watchOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-033-watch-race`；`watch10-simulator-final-75-build.log` | fresh Build complete，exit0；无warning |

新22项：2 PermanentFence + 14 ErasureLifecycle + 5 ErasureMigration + 1 RetryRace。原53在同一轮包括6 AccountCheckpoint、16 Conflict、5 EventSequence、3 IssueDecoding、10 Ledger、13 Service；IssueDecoding仅将当前schema断言3更新为4，测试意图和坏issue原bytes验证不变。首次API缺失编译及fixture修正、先前72/74单轮/初步SDK原输出另存，不能作为最终源码证据或与75累计。

真实SQLite覆盖：空/非空账号、多epoch，同file其他account/space/zone全列原bytes保持；pending/blocked/confirmed uploads、batch ACK、conflict与save evidence；重复首次receipt、同ID异scope意图拒绝；beforeCommit四表/文件原bytes和无fence/receipt；afterCommitResponseLost重开重放；两个已打开connection的enqueue/stage/ACK/confirm/conflict/重试/清状态阻断；save成功或冲突/fetch迟到，以及callback先完成再清理的反序；重开与未来epoch始终阻断；显式新namespace与旧文件fence隔离。

坏行用真实SQL修改四表canonical、scope、digest、issue、ACK及scope-state issue，共11种；另含外账号无法归属行、真实NUL后缀scope/issue/state和非法UTF8。所有失败保留原文件与原业务bytes，不产生新receipt/fence。成功在同事务严格重枚举，确认目标canonical零。

schema4只新增两最小控制表。五处初始化故障点（旧结构/canonical校验、fence DDL、receipt DDL、版本、最终结构）逐一回滚并保留v3文件和原bytes；迁移COMMIT响应丢失后可重开；v1/v2/v3原upload等canonical保持；v3坏canonical/NUL在迁移前失败保留，未来99与缺当前控制表失败保留。原CloudLedger协议字节未改，其他模块不写入。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-033`。保留六Git输入、实际红绿/SDK日志、工具版本及源码/编译输入/evidence SHA256 manifest。

coherent提交后普通合入已验证032 target aa9977；Git核其Native相对原base零delta，74层42项输入在同步前后相同。随后新增错误重试竞态修复，最终75与两fresh SDK均绑定新42项CloudSync + MatchCore package/source输入；两层hash及各原日志分开保存。最终source/final精确SHA与clean停写状态见树外manifest，不以Node128作为本作者重跑。

交接限制：receipt只证明该文件四表逻辑清理，不等于全本地删除/物理介质或备份擦除。026负责所有owned ledger catalog、024 stagingfiles、023 Store和业务写入fence/cursor再初始化，保留saga/capability/028 selection。旧文件永不unfence，新epoch不能恢复写入；026先使旧actors失效，明确选新namespace恢复保留云。默认unavailable；本次未调用真实CloudKit/账号/设备。真机不适用：隔离SQLite/受控driver实现，不能代替后续真实SDK或整包验收。

## S33-1 原UTF8 scope身份修订

根因：Swift String规范等价令NFC `space-é` 与NFD `space-e\u{301}` 的CloudScope synthesized equality/hash相同，但原stableZoneKey/fullscope SQL key按原UTF8不同。Set归属枚举和postzero检查都漏掉其中一份；合法目标四表canonical还在却已成功commit receipt。相同比较也会使CloudUpload和save readback的scope校验误认另一原字节域。

| 层次 | 实际命令 / S33-1原日志 | 结果 |
|---|---|---|
| 真实SQL运行时红 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-033-host --filter CloudScopeRawIdentityTests`；`unicode-scope-red-2.log` | 5项，21 failures，0 unexpected；legacy固定bytes/keys在红阶段通过。首轮错误fixture值日志另存，未作有效红计数 |
| 新完整host绿 | 同命令去掉filter；`cloud-host-green.log` | 单轮80/80，0 failure，包含旧75+新5，无warning |
| fresh最低iOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-033-s331-ios`；`ios17-simulator-build.log` | Build complete，exit0，无warning |
| fresh最低watchOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-033-s331-watch`；`watch10-simulator-build.log` | Build complete，exit0，无warning |

产品只给CloudScope补原UTF8 bytes+epoch的自定义==/hash，scope encoder/CodingKeys、stableZoneKey、SQL key和所有hash域不改。五项新增回归覆盖真实四表NFC先入/NFD后入、分别擦每一方后的原SQL-key postzero/首次receipt重开及另一域全列原bytes保持；account/cloudSpace/zone三个ID字段各自不折叠；跨scope upload与完整save readback拒绝；erase request相等/摘要及receipt重放绑定；legacy固定scope canonical与stable/SQL key fixture。既有所有scope==边界统一继承原字节比较；fetch稳定域键、receipt域键原本就是原bytes hash，不作归一化。

新完整80包含原53、033前版22及本次5，不与旧75或旧SDK累计。S33-1独立保存六Git输入、旧source对应红输入、新42项编译输入、原红绿/双SDK日志、source/final及evidence hash manifest；父目录旧证据逐hash保持。仍为单ledger/受控本机，不扩大033范围，不调用真实CloudKit/账号/设备。
