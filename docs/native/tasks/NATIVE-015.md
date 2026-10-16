# NATIVE-015 — 纯同步服务与 Session 接收桥

状态：作者实现与完整验证完成；源head `a6f01d03cd9acc0ff0354354d32c6c6d34543177` / target `c3940dd9a1cf4690d849114290c7614905140c7e` 已获 `/root` 质量与 `/root/m2_review` 规格两位非作者双PASS；文档收尾后待主代理最终检查与集成，未合入。

| 登记项 | 实际事实 |
|---|---|
| 作者 / 主代理 | `/root/m3_store` 唯一写入；`/root` 质量审与治理；`/root/m2_review` 独立规格审 |
| base_ref / target | `dev`；完整 base/target `c3940dd9a1cf4690d849114290c7614905140c7e` |
| 分支 / 树 | `feat/match-sync-service`；attachment `01a14399-5be3-7892-a2c2-7ac335f2a761`，createdAt `1792135486` |
| 路径 / 初始HEAD | `/Users/liam/.codex/worktrees/match-sync-service/20260830_足球记录`；上述base，写入前clean |
| 前置 | 014已双审、实际merge全量197/6SDK/2App通过并同步dev |
| 所有权 | MatchCore整个包；verify.sh；本卡/验证卡/小计划；root另批准合同中仅015已测实际接口增补；仅Presentation两个repository wrapper机械协议转发 |

不触碰Apps/Xcode/entitlements/根AGENTS；合同仅补root已批准的实际015接口。计划见 [实施小计划](../../superpowers/plans/2026-10-16-match-sync-service.md)，冻结依据 [M3合同](../contracts/m3-durable-sync.md)。独占 `/tmp/football-record-NATIVE015-build`；完整证据保存树外NATIVE-015。作者不merge/push/archive。纯fake transport/SQLite不等于真WC通信，设备验收留016/018。


## 作者交付

源head `a6f01d03cd9acc0ff0354354d32c6c6d34543177`：功能提交 `cbba8cee608d9db8231533b2932909ff2bc7b7a4` 为21路径，普通后续fix补公开DTO predecode cap及同组断言；原提交与红测保留。最终 `verify-public-dto.log` / `Verify/logs/20261016T081956Z` exit 0：44 Core + 106 Store + 46 Session + 17 MatchSync + 22 Presentation = **235** 项宿主测试、**8** 项最低 SDK 产品编译、**2** 个 App 无签名模拟器构建。旧8个 fixture SHA256 不变。作者未 merge/push/archive。

树外证据 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-015/source-a6f01d0/`，保存完整173个Git blob输入与253个输入/日志文件；manifest SHA256 `6ead33e33741106e64a33099da01440b8fa286f61bdf153cf46f76d05212a795`。详见 [验证卡](../validation/NATIVE-015.md)。

本任务一次写入治理偏差已由root纠正：helper误获可写权限后写入 `PeerTerminalTests.swift` 与 `SessionTestSupport.swift` 的独立inbound/cleanup故障钩子；立即收回权限。作者接管逐行核对、修正 async XCTest 自闭包并实际运行全部46项Session测试；旧gate语义保留，未撤销成果或掩盖来源，后续唯一作者写入。

## 016 / 017 交接

- MatchSync是真实product/target；共享DTO/protocol在MatchStore；Session与Sync无源反向依赖。SessionRepository继承SyncRepository，所有调用真实转发同一facade内部Store连接；identity一次启动UUID+实际namespace，不能用相同namespace伪装另一个实例。
- 最小新增辅助为 `validateSyncDeliveryV3(deliveryID:peer:now:)`、`reactivateSyncACKsV3()`、`pendingSyncAssembliesV3(peer:now:)`；完整签名与语义见 [合同§5](../contracts/m3-durable-sync.md#5-可信-peer-与模块依赖)。生产默认 unavailable；DEBUG fixture每次核对两个实际持久身份文件，不接受丢失/替换或production namespace。
- 016每次真实新连接激活调用 `connectionDidActivate()`；普通timer/wake不重置ACK8次预算。`SyncTransport.didPersistDelivery(_:)` 仅释放transport自有输入临时文件，只有Store片段成功返回才触发，绝非业务ACK。无新帧也会恢复完整未consume组；完整组不按24h清理。source保留total attempt审计、另记连续次数；失效trust不耗send次数。
- 017使用 `AsyncStream<SyncStateUpdate>`：state为持久计数，unavailable明确未知/blocked。读取失败不保留旧成功通知；backoff错误与重开状态来自持久delivery台账。App旧unavailable装配未改，本任务无UI行为/设备模块接线。
- schema仍为已发布v3，仅填原generic record：delivery内有稳定fragment、累计/连续attempt、sleeping、nextAt和issue；fragment组内有header、peer绑定、first/expiresAt、原fragment bytes和expired状态。consume核receipt后清临时片，原inbox/ACK原字节继续留存。
