# NATIVE-037：DeviceSync 命名空间擦除

状态：本机软件实现及作者验证完成，独立 held026 候选；等待 root、m2 对 exact source/final 双审，不入 dev。唯一作者 `/root/m4_cloud`。

- original base/登记 target：`fcf530ada01a7cbf87bbfde598f611d8a35705b2`。
- accepted018：`891000e1842f21f4a594a1d29168974debed68b9`；root 普通依赖合并后的起始 HEAD：`f15938e8e56f1c4f0a3166bdf3259a06c28e8214`。
- source：`66c800f69f329492860a3fd80255c2e4c3592b43`；最终两卡提交的 final SHA、双审及后续治理只记树外 registry，不回写自 SHA。
- current target：`e3e4b09d79c1f2556b8648c214f6c3c148ca8cd1`。该025组合的 Core/AccountKit/CloudSync tree 与原 base 一致，相关 DeviceSync 编译输入无 delta；按 root 指令不合入025 App/工程改动，026由指定工程 owner 组合候选。
- 分支：`feat/m4-device-sync-erasure`；受管树：`/Users/liam/.codex/worktrees/m4-device-sync-erasure/20260830_足球记录`。
- attachment：`01a150f7-24bc-7ee0-aaa5-b51ce8e6932e`；createdAt：1792359736。写入前已核实际 HEAD/分支/clean。
- 所有权：root 登记25个精确路径；实际相对依赖合并22文件，均为 DeviceSync 模块、本卡、[验证卡](../validation/NATIVE-037.md)和[实施计划](../../superpowers/plans/2026-10-19-m4-device-sync-erasure.md)。未改旧018树、Core、AccountKit、CloudSync、App、工程、配置、共享脚本。

依 [M4母计划](../../superpowers/plans/2026-10-18-native-m4.md) 与 [Git治理](../../git-workflow.md) 完成真实红绿、分 slice Conventional Commits、明确路径暂存。作者不推进长期分支、push或归档。

## 交付与026责任

固定 `<namespace>/DeviceSync/{inbox,outbox,state}` 共用 SQLite durable control 和保留的 `.control/.owner` inode gate。026须先提供已验收 catalog 的 namespaceID、原 account/cloudSpace/zone UTF8、epoch、revision/digest、实际 rootIdentity，显式绑定 fresh 空 root；非空 unbound legacy、未知、混合、损坏与未来 schema 均失败保留，不猜账号或自动 adoption。

持久原 saga requestID/digest、冻结 owned transfer 身份及永久 fence；精确排空 SDK owned inventory 后删已验证 canonical，再严格 zero 检查及最小 receipt。unlink 与 SQLite 非同一事务，故支持部分删、COMMIT 丢响应和重开原请求；已有 receipt 重放仍校验当前 strict inventory/zero。64KiB control 编码/解码预算在 UPDATE/进度前一致校验，超预算保留旧业务字节。root/control/owner 及 parents 保留，无自动 unfence。

managed inbox/outbox 必须为同一实际 root/control/owner/database gate，不混 standalone。内建 native driver 以内部可选 binding 能力核同 gate；`WCSessionDriving` 原 required 方法不变。未知自定义 WC driver 可保留普通调用兼容，但不能仅凭声明 erasure 能力让 transport 生成完成；直接注入 erasure service 的 driver 属026负责证明的受控适配契约。

永久 fence 后正常 constructor/activate/send/adopt 继续拒绝。iOS/watchOS 可用显式 `WCSessionDriver(stateDirectory:erasureRequest:)`，先核持久原 request/owner，仅为排空取得 native handle，不创建 pairing 或安装普通接收。仅在原 fenced 请求下为恢复 SDK inventory 设置 delegate/activate；本 owner 收到成功 activated 回调且查询时仍 activated 才可读队列，未知/启动中/失活均不能完成。cancel 后重查，原 token/checksum、storage owner 与实际 source 归属矛盾维持 unresolved；其他 root 不扩大取消。`sendMessageData` 无 SDK cancel handle，仅结束本地 waiter。

receipt只证明该已声明独占 root 的逻辑清理与受控队列结果。026仍需全部 owned namespace catalog、033各 ledger、024 staging、023 Store 聚合，并保护 saga/capability/028 selection；必须先失效旧执行实例，保留云恢复须显式选新 namespace。037不证明远端召回、备份/物理擦除或整个账号删除，不启用生产 provider/trust/bootstrap。

## 验证层次

固定 source 的一次 fresh 完整 DeviceSync host 为 **69项/0失败**，含原21项和旧62项全部回归；另有真实子进程 gate、双 handle/重开、故障、原字节保护、late callback、SDK共享归属及 readiness helper。四项 fresh 最低 iOS17/watch10 sim/device 产品编译通过。018旧331、主线591、44a3旧62和其他模块测试不累计成本轮数字。

官方 SDK headers 只读核验与四端编译均未执行真实 WCSession、账号或设备。配对、后台队列恢复/取消的实际 SDK 时序、签名安装、本人设备及026全 owned 聚合仍待后续；不以软件绿替代真机或双审。证据与局限见验证卡及树外 manifest。
