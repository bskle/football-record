# NATIVE-016 — WatchConnectivity 传输适配

状态：源 `73275bb4724b1525e21e14507c13892d9f297a6e` / target `a5d70759b1ff7c67b92f2082244fd189c119418d` 已获 `/root` 质量与 `/root/m2_review` 规格两位非作者双PASS；作者21项host/四SDK自动验证完成。文档最终复审待root，配对真机门槛保留；不入dev/release/main。

| 登记 | 实际事实 |
|---|---|
| 唯一写入负责人 | `/root/m3_store`；helpers仅只读；`/root`质量与`/root/m2_review`独立规格审 |
| base / 当前target | 已验证 `dev=origin/dev=a5d70759b1ff7c67b92f2082244fd189c119418d` |
| branch / 树 | `feat/watch-connectivity`；`/Users/liam/.codex/worktrees/watch-connectivity/20260830_足球记录` |
| attachment / createdAt | `01a143d5-2d5f-7311-86e6-13f2c45e84b0` / `1792139406`；初始HEAD等于base，clean |
| 所有权 | `native/Modules/DeviceSync/**`及本任务/验证/实施计划3文档；不写Core、Presentation、Apps、工程、脚本、AGENTS或合同 |

前置015已双审集成并验证。计划见[小计划](../../superpowers/plans/2026-10-16-watch-connectivity.md)，冻结依据M3§7与合同§5/7/8。作者不merge/push/archive，旧015树不再写。独占构建目录 `/tmp/football-record-NATIVE016-build`，完整输入/日志manifest保存在树外NATIVE-016。

真实SDK只在iOS/watchOS条件编译；host fake只证明driver与文件协议，不证明WC通信。transferFile不支持Simulator；签名/安装/授权、真实配对、断连、后台与重开通信留018及本人设备验收。


## 作者交付

源码仅DeviceSync实际包 **13** 路径，依赖仅MatchSync产品，系统框架为Foundation/CryptoKit及iOS/watchOS条件编译WatchConnectivity。旧Core/Presentation/Apps/工程/配置/脚本/合同未改。21项host XCTest、iOS17/watchOS10各simulator/device四项SDK target均exit0；未装入App、未实际运行WCSession。

树外源证据 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-016/source-73275bb/` 保存 **189** Git blob输入及 **228** 输入/日志文件；manifest SHA256 `c99807b76164adfd621f16f72758312b01112b6a0393c36ea8003715cf9ea177`。准确命令/红绿/源输入见[验证卡](../validation/NATIVE-016.md)。作者不merge/push/archive；本地分支/树保留给018和配对真机。

## 018 接口交接

- `WCSessionTransport.system(applicationSupportDirectory:)`：iOS/watchOS真实WCSessionDriver，存于调用方App自有Application Support下DeviceSync/inbox、outbox、state；host明确throw unavailable。也可注入 `WCSessionDriving`、DurableFileInbox与outboxDirectory用于协议夹具。
- `events()`提供 `.activated`、`.wake`、`.trustInvalidated(reason)`、`.failure(issue)`。018在真实activated调用service.connectionDidActivate，仅wake调用service.wake；不可达不阻止合法后台排队，不得每次可达poll重置ACK8次。订阅失效事件应先于启动；失效后撤销provider并stop服务。SDKinactive/deactivate/watch状态来源与App显式identity来源分别记录。
- `notifyTrustInvalidated(.accountChanged/.localIdentityChanged/.remoteIdentityChanged)`由上层持久身份/账号可信owner显式注入；WCSession不能提供这些身份。失效锁存暂停发送和互动输入，重复activate不重新授权。iOS已存可观察Watch基准变化先持久失效再允许发送；watchOS仅companionInstalled弱状态，远端变更必须由上层重新核对provider并通知，不能声称自动识别。
- active+reachable且encoded frame≤48KiB走sendMessageData，其余同一原bytes排transferFile。48KiB为应用策略。后台同deliveryID同bytes共用一SDK outstanding与自有出件，异bytes拒绝；send在SDK接纳队列后返回，completion仅按原transfer token清对应自有出件，不确认business ACK。迟到旧completion不删新轮文件。
- native delegate同步接管文件、bounded读取/hash并持久保存后返回；transportID为原bytes SHA256，不信任来件metadata。只有`didPersistDelivery(ID)`释放已提交Store片段的owned输入；enqueue/reply/transport completion不删inbox。失败/responseLost会留到合法重放成功。两个临时队列各有64MiB/256 frame限额（独立于Store的message配额），单frame≤16MiB。
- S16-1关闭：TransportLifecycleTests:115真实afterRecordRemoval故障，metadata先失效/孤儿回收/原bytes重试；S16-2:132 gated install合并activate；Q16-1 PairingBaselineTests:6/:15跨重建指纹失效和坏基准保留。详见验证卡。真实App挂起/终止、配对换表、后台与断连恢复仍待物理验收。
