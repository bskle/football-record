# NATIVE-033 单云台账本地传输清理验证

日期：2026-10-19（上海）。原始base `ef10b33a10663ad94b0bb4a3e43106af108c38bb`；current target / 普通同步来源 `aa9977805dfb172cf1ece605d1f575cf7684df72`；分支 `feat/m4-local-transport-erasure`；worktree `/Users/liam/.codex/worktrees/m4-local-transport-erasure/20260830_足球记录`；attachment `01a1502d-7e43-78e2-9f4e-0271040e9f06`。source/final SHA 留树外 manifest，待root+m2 exact双审。

| 层次 | 实际命令 / 原日志 | 结果 |
|---|---|---|
| 原实现运行时红 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-033-host --filter CloudLocalTransportErasureTests`；`persistent-fence-red.log` | 2项/9 failures，0 unexpected：持久fence、新epoch及enqueue/conflict/stage未受保护 |
| SQLite TEXT运行时红 | 同命令使用 `--filter testNulSuffixedAndInvalidUTF8ControlTextCannotProduceEraseReceipt`；`strict-text-red-2.log` | 1项/14 failures，0 unexpected：NUL后缀被C字符串截断，错误产生receipt或删除；随后按column_bytes严格UTF8/NUL解码修复 |
| 控制一致性运行时红 | 同命令使用 `--filter testReceiptWithoutItsPersistentFenceCannotReplayOrResumeTransport`；`control-consistency-red.log` | 1项/4 failures，0 unexpected；receipt缺永久fence时不能继续重放成功或恢复传输 |
| 完整host绿 | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-033-host`；`cloud-host-final-green.log` | 单轮74/74，0 failure：原53 + 新21；无warning |
| 普通同步后host绿 | 同一完整测试命令；`cloud-host-post-sync.log` | 单轮74/74，0 failure；与前74为分层重跑，不累计148 |
| 最低iOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-033-ios-final`；`ios17-simulator-final-build.log` | fresh Build complete，exit0；无warning |
| 最低watchOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-033-watch-final`；`watch10-simulator-final-build.log` | fresh Build complete，exit0；无warning |

新21项：2 PermanentFence + 14 ErasureLifecycle + 5 ErasureMigration。原53在同一轮包括6 AccountCheckpoint、16 Conflict、5 EventSequence、3 IssueDecoding、10 Ledger、13 Service；IssueDecoding仅将当前schema断言3更新为4，测试意图和坏issue原bytes验证不变。首次API缺失编译及fixture修正、先前72单轮/初步SDK原输出另存，不能作为最终源码证据或与74累计。

真实SQLite覆盖：空/非空账号、多epoch，同file其他account/space/zone全列原bytes保持；pending/blocked/confirmed uploads、batch ACK、conflict与save evidence；重复首次receipt、同ID异scope意图拒绝；beforeCommit四表/文件原bytes和无fence/receipt；afterCommitResponseLost重开重放；两个已打开connection的enqueue/stage/ACK/confirm/conflict/重试/清状态阻断；save成功或冲突/fetch迟到，以及callback先完成再清理的反序；重开与未来epoch始终阻断；显式新namespace与旧文件fence隔离。

坏行用真实SQL修改四表canonical、scope、digest、issue、ACK及scope-state issue，共11种；另含外账号无法归属行、真实NUL后缀scope/issue/state和非法UTF8。所有失败保留原文件与原业务bytes，不产生新receipt/fence。成功在同事务严格重枚举，确认目标canonical零。

schema4只新增两最小控制表。五处初始化故障点（旧结构/canonical校验、fence DDL、receipt DDL、版本、最终结构）逐一回滚并保留v3文件和原bytes；迁移COMMIT响应丢失后可重开；v1/v2/v3原upload等canonical保持；v3坏canonical/NUL在迁移前失败保留，未来99与缺当前控制表失败保留。原CloudLedger协议字节未改，其他模块不写入。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-033`。保留六Git输入、实际红绿/SDK日志、工具版本及源码/编译输入/evidence SHA256 manifest。

coherent提交后普通合入已验证032 target aa9977；Git核其Native相对原base零delta。同步后的42项CloudSync + MatchCore package/source输入逐hash匹配本轮fresh双SDK；host对同步组合重跑。最终source/final精确SHA与clean停写状态见树外manifest，不以Node128作为本作者重跑。

交接限制：receipt只证明该文件四表逻辑清理，不等于全本地删除/物理介质或备份擦除。026负责所有owned ledger catalog、024 stagingfiles、023 Store和业务写入fence/cursor再初始化，保留saga/capability/028 selection。旧文件永不unfence，新epoch不能恢复写入；026先使旧actors失效，明确选新namespace恢复保留云。默认unavailable；本次未调用真实CloudKit/账号/设备。真机不适用：隔离SQLite/受控driver实现，不能代替后续真实SDK或整包验收。
