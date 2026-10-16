# NATIVE-015 — 同步服务与 Session 接收桥验证

状态：作者验证完成；精确源head `a6f01d03cd9acc0ff0354354d32c6c6d34543177` / target `c3940dd9a1cf4690d849114290c7614905140c7e` 的 `/root` 质量审与 `/root/m2_review` 独立规格审均PASS，两位均非作者；文档最终检查与集成由主代理执行。未合入dev，作者未merge/push/archive。

## 输入与证据

- 基线/目标：`c3940dd9a1cf4690d849114290c7614905140c7e`；源提交：`a6f01d03cd9acc0ff0354354d32c6c6d34543177`；分支 `feat/match-sync-service`。
- 树：`/Users/liam/.codex/worktrees/match-sync-service/20260830_足球记录`；attachment `01a14399-5be3-7892-a2c2-7ac335f2a761`，createdAt `1792135486`；创建时HEAD等于基线且clean。
- 树外源证据：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-015/source-a6f01d0/`。
- `input/repository/` 保存source完整 **173** 个Git blob；`input/git-input-manifest.json`记录mode/blob/字节数/SHA256。`manifest.json`覆盖 **253** 个输入/日志文件且逐项重算匹配，SHA256 **`6ead33e33741106e64a33099da01440b8fa286f61bdf153cf46f76d05212a795`**；清单自身不计入其列表。
- `logs/full-verify/`来自 `/tmp/football-record-NATIVE015-build/Verify/logs/20261016T081956Z`；`logs/verify-public-dto.log`是最终命令完整输出。系统/编译器、source patch/tree/status/history和原8 fixture hash核对在input；summary记录实际结果、历史失败和限制。

## 实际自动验证

`NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE015-build/Verify scripts/native/verify.sh` 最终exit **0**，全部使用专属 `/tmp`，源输入在本轮开始后未修改。

| 范围 | 实际结果 |
|---|---|
| MatchCore / MatchStore / MatchSession / MatchSync XCTest | **44 + 106 + 46 + 17 = 213**，0 failures |
| Presentation XCTest | **22**，0 failures；宿主总计 **235** |
| 最低 SDK 产品 | MatchStore / MatchSession / MatchSync / MatchPresentation 各iOS17与watchOS10 simulator triple，**8** 项通过 |
| 无签名App | FootballRecord-iOS / FootballRecord-Watch generic simulator，CODE_SIGNING_ALLOWED=NO，**2 BUILD SUCCEEDED** |
| Git/兼容 | diffcheck、精确21路径stage通过；原8个v1 fixture SHA256不变；旧v2固定packet/ACK fixture回归继续通过 |

## 红绿、故障与恢复矩阵

| 日志/测试 | 真实证明范围 |
|---|---|
| red-initial / red-session / red-service | SyncFragment/Store辅助、Session coordinator、MatchSyncService缺失的初始编译红测；后续绿测保存 |
| red-public-delivery-cap / verify-public-dto | 正式质量审发现公开SyncDeliveryRecord仍缺predecode cap；行为红测证实旧实现先JSON解码，普通新fix提交加shared guard后全量通过，未amend原cbba源 |
| 编译迭代日志 | 保留实际async XCTest/字段拼写编译失败，未将编译失败冒充行为断言红测 |
| SyncDeliveryTests（11） | 原字节跨重开重试；乱序/重复/大包重组，whole原canonical hash与kind/message/match头一致；same-ID冲突隔离；8MiB/256KiB/32片、32due、64MiB/256组定额；partial24h/倒退时钟；fragment事务rollback/responseLost；ACK8次休眠/显式唤醒保留total；旧epoch/account/peer不能改绑 |
| PeerTerminalTests（10） | terminal撞start/resume/reconcile悬挂仍先持久原token finish；COMMIT后response/reload丢失，duplicate返回first receipt并republish；cleanup前失败/后失回执复用稳定原请求bytes；失败finish重复包仅原token重试；remote recorder只观察；同facade identity |
| SyncServiceTests（17） | 两实际独立SQLite/持久身份经fake双向传输到精确业务ACK；send callback无ACK仍pending；失trust只暂停不耗8次、普通wake恢复；同instance新激活唤醒ACK但不新增loop；stop/start deliveries门闩无旧listener；订阅先成功→真实SQL读取失败→明确unavailable→修复后新state；backoff/reopen保留错误；身份丢失/替换拒绝；malformed全局错误不因空drain消失；完整组长时重开/trust暂失/运行中丢publish/同instance重启均无新帧恢复；只原tokenfinish；transport输入仅片段成功持久后释放 |
| core-first / verify-full / session-full-tty | 早期完整回归停滞原始日志与进程采样；精确旧例是original linked-token proof优先回查被新finish抢先，另empty-scan gate曾被额外持锁读取截住。只终止本任务精确PID，未碰其他进程；修复保持旧gate语义，最终全部46 Session通过 |
| green-original-proof-order | 原未决operation先回查、保存证明优先，结合新terminal竞态与真实重开路径通过 |
| verify-final | 中途旧输入234/8SDK/2App通过，但最后同instance恢复初始化发生在该轮中，**不作为最终源输入验证**；verify-complete曾完成cbba8ce的235；正式审阅公开DTO上限修复后，最终只认verify-public-dto的235 |

## 实际schema与接口

已发布schema3表结构未改；原generic `sync_delivery_v3` record封装稳定fragment/累计attempt/独立连续次数/sleeping/nextAt/issue；`sync_fragments_v3` record保存header/peer/首次与期限/原片字节和过期状态。完整未consume是持久工作，不按24h丢弃；成功receipt后consume可重试且删除临时片段，原inbox/ACK原字节不删。

所有SQL仍在SQLiteSessionRepository原唯一Store actor/连接。SessionRepository:SyncRepository；实例启动UUID+实际namespace与coordinator相等才启动服务；wrapper均真实转发。开发实际namespace本机显式传入Store，不能由incoming配置，也不要求两端namespace相同。shared DTO/protocol在Store，Sync与Session无源码反向依赖；MatchSync已真实注册并双SDK编译。

root已批准的实际增补：validateSyncDeliveryV3 / reactivateSyncACKsV3 / pendingSyncAssembliesV3；connectionDidActivate；typed SyncStateUpdate；SyncTransport.didPersistDelivery。完整签名和016/017调用限制写入 [合同§5—7](../contracts/m3-durable-sync.md#5-可信-peer-与模块依赖)。持久片通知不等于业务ACK；正式trust/transport仍默认unavailable，fixture仅DEBUG+development。

## 限制与写入治理

本任务是纯Swift服务/fake transport/真实SQLite/Session桥，**真机设备通信不适用本任务，留016/018**。未运行WCSession或HealthKit，不证明实际配对、后台、锁屏、断连、两端重启通信；最低iOS17/watchOS10仅编译，未实际运行。故障注入不等于物理断电/压力。App旧unavailable装配与UI/工程/能力配置未改，未接入未审设备模块。

root纠正过一次共享写入授权偏差：helper已写PeerTerminalTests与SessionTestSupport独立故障钩子后立即停写；作者保留并接管逐行核对、修正async测试表达式，实际执行全部46 Session回归，旧gate不变。源证据summary保留事实，不把helper未运行的测试宣称为其通过。
