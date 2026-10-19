# NATIVE-016 — WatchConnectivity 适配验证

状态：源 `73275bb4724b1525e21e14507c13892d9f297a6e` / target `a5d70759b1ff7c67b92f2082244fd189c119418d` 的root质量审与m2_review规格审均PASS，两位均非作者。作者自动验证完成；文档最终检查待root。**已自动验证，待配对真机**，不入dev/release/main；作者未merge/push/archive。

## 输入与证据

- `feat/watch-connectivity`，专属树 `/Users/liam/.codex/worktrees/watch-connectivity/20260830_足球记录`；attachment `01a143d5-2d5f-7311-86e6-13f2c45e84b0`，createdAt `1792139406`；初始HEAD/clean已核。015旧树不再写。
- 树外源证据 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-016/source-73275bb/`；`input/repository/`完整 **189** Git blob，mode/blob/bytes/SHA256在git-input-manifest；source diff仅13 DeviceSync路径。
- `manifest.json`覆盖 **228** 输入/日志文件且逐项重算匹配，SHA256 **`c99807b76164adfd621f16f72758312b01112b6a0393c36ea8003715cf9ea177`**，清单自身不包含自身。安装SDK的iOS/watchOS两组WCSession/WCSessionFile头、官方预检index、Swift/Xcode/系统与exact Git信息均保存。
- 实际日志根 `/tmp/football-record-NATIVE016-build`；已另存 `logs/`，不依赖ignored cache。SDK精确命令脚本另存input/verify-sdk.sh，未修改仓库脚本。

## 最终自动验证

| 命令/范围 | 实际结果 |
|---|---|
| `swift test --package-path native/Modules/DeviceSync --scratch-path /tmp/football-record-NATIVE016-build/Host` | host-final.log：5 FileInbox +2 MessageReply +2 PairingBaseline +12 TransportLifecycle = **21** XCTest，0 failures，exit0 |
| iOS17 simulator | `xcrun swift build --package-path native/Modules/DeviceSync --target DeviceSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /tmp/football-record-NATIVE016-build/iOS-Simulator`；ios-simulator-final.log，exit0 |
| watchOS10 simulator | 相同package/target，`--triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /tmp/football-record-NATIVE016-build/Watch-Simulator`；watch-simulator-final.log，exit0 |
| iOS17 device | 相同package/target，`--triple arm64-apple-ios17.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path /tmp/football-record-NATIVE016-build/iOS-Device`；ios-device-final.log，exit0 |
| watchOS10 device | 相同package/target，`--triple arm64-apple-watchos10.0 --sdk "$(xcrun --sdk watchos --show-sdk-path)" --scratch-path /tmp/football-record-NATIVE016-build/Watch-Device`；watch-device-final.log，exit0 |
| diff/scope | diffcheck与精确13路径stage通过；未写Core/Presentation/Apps/Xcode/配置/脚本/合同；真实product/target仅依赖MatchSync |

四端均为target编译，**不是运行、签名安装、真file delegate或真实通信证据**。宿主工厂明确unavailable，不以stub代替SDK能力。

## 红绿与故障矩阵

| 日志/组 | 实际证明 |
|---|---|
| red-inbox / green-inbox | 缺DurableFileInbox API真实初始编译红；同步接管、SDK返回删原文件后仍保留owned原bytes、重建扫描、重复、quota和仅Store持久通知释放 |
| red-transport / green-transport-first | 缺driver/transport API红；active+reachable≤48KiB边界快路，其余同canonical bytes文件；未激活/缺companion拒绝；同ID离线8次与Transport重建只1 SDK outstanding/出件，异bytes拒绝；快路Task取消不等reply；无business ACK逻辑 |
| red-native-factory / green-native-factory | host工厂未实现红；真实iOS/watchOS driver条件实现、host明确unavailable；settlement覆盖取消先于continuation安装、重复reply/error/迟到结算只一次 |
| FileInboxTests（5） | 属性先限大小再bounded读；symlink拒绝；损坏owned文件重hash报错并保留，不能当Store已持久删除；源文件不可读的复制失败保留此前原输入并记录last-error；去重/帧数/字节定额 |
| MessageReplyTests（2） | reply同步为transport accepted/deferred/unavailable，输入仍在owned inbox；真正释放只didPersistDelivery；文件delegate返回前接管、无新SDK帧重建扫描重放 |
| red-activation-orphan → green-review-edges | 实际2测试3断言失败：安装await期间第二activate先调用SDK/重复调用；无record孤儿未回收。Task合并与owned orphan回收后闭环 |
| **S16-1** TransportLifecycleTests:115 | `testCrashAfterCompletionMetadataRemovalCanReclaimOrphanAndResendOriginal` 调用真正completed(afterRecordRemoval fault)，断言metadata已失效但payload仍在；重建回收无SDK引用孤儿，原bytes可重试。修复真实file-first双unlink留下坏live record的窗口，未以相反手工顺序冒充 |
| **S16-2** TransportLifecycleTests:132 | `testConcurrentActivationCannotPassSuspendedCallbackInstallation` 真install门闩，第二activate不能提前返回/启动SDK；释放后1 install、1 activate |
| red-pairing-baseline / PairingBaselineTests（2） | **Q16-1** :6旧基准→重建观察新fingerprint→invalidated持久锁存，旧指纹回来不能靠activate重授权；:15坏原file保留并failclosed。NativeWCSessionDriver:137完成对比/持久化后才activationAccepted，SDK path/installed只为观察提示，不是账号或设备身份认证 |
| red-invalidated-input / host-final | 显式identity失效后互动输入原先仍accepted的真实红；同步失效门槛改为unavailable、不入inbox。SDK lifecycle事件先锁存再hop；文件仍可被bounded接管保留但不会转业务处理/产生ACK |

## 018 接线与持久格式

- 真实工厂 `WCSessionTransport.system(applicationSupportDirectory:)` 在App-owned DeviceSync下创建inbox/outbox/state，driver强持有非actor NSObject proxy；SDK delegate weak。所有SDK对象、Any metadata、reply closure留在非actor owner；同步reply与文件接管完成后，仅Data/URL/typed ID/状态hop到actor。iOS inactive/deactivate/watchState与watchOS companionInstalled分平台guard，四SDK验证签名。
- 订阅events后启动：`.activated`→service.connectionDidActivate；`.wake`→普通wake；`.trustInvalidated`→撤销provider并stop服务；failure显示运输错误。实际activation和可达变化分开，重复delegate不制造第二loop。失效锁存不因SDK重新激活而恢复授权。
- App账号、本机UUID、远端UUID变化只由上层显式notify；SDK不提供accountSubject/本App身份。iOS持久fingerprint仅比较SDK可观察Watch目录/安装/配对状态；watchOS只有companionInstalled弱状态，不能保证探测远端更换，上层须每次重新验证当前provider并在变更时notify。M4生产trust仍unavailable。
- inbox文件名为原frame SHA256稳定ID，重新hash后才投递；仅didPersistDelivery删除自有输入。出件record为deliveryID/checksum/token/byteCount，payload原bytes单独保存；SDK metadata带protocol/原ID/hash/token。重复send先查outstanding，SDK接纳即返回，不等后台传输数小时；完成仅按token回收运输文件，旧callback不能删新轮。原business pending/ACK由015 Store持久台账决定。
- DeviceSync本地inbox/outbox分别最多64MiB/256 frame，单frame16MiB，独立于Store per-peer message配额；快路48KiB是应用策略。错误保留owned输入并尽力记录bounded last-error（存储本身不可写时仍发typed failure），损坏不当空成功；完成窗口metadata先失效，孤儿只在确认无SDK引用时回收。Pairing state canonical checksum保护摘要+invalidated，失败保留原file，不静默覆盖。

## 必须保留的边界

未把DeviceSync接入App；没有实际运行WCSession、发送/接收真transferFile、真实回调时序、配对切换、断连、后台、锁屏或两端重启。**transferFile及其接收delegate不支持Simulator**，host fake和四SDK不解除真机门槛。最低iOS17/watchOS10只编译、未实际运行；文件故障注入和重建对象不等于真实进程杀死/物理断电/压力保证。018须在实际配对iPhone/Apple Watch完成设备矩阵后再决定集成。

本任务唯一作者实际写全部源/测试；helper仅只读SDK头，未共享写树。root双PASS仅覆盖本精确源和上述自动证据；最终docs复审与未来真实merge由root负责。作者不合dev/release/main、不push临时分支、不归档，保留本地树/分支给018。
