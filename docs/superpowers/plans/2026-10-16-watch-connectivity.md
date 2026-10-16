# NATIVE-016 WatchConnectivity Implementation Plan

> Execute the frozen M3 plan with test-driven-development. `/root/m3_store` is the sole writer; `/root` quality and `/root/m2_review` specification are independent non-author reviews. Helpers may inspect only.

**Goal:** transport the existing immutable sync frames through WatchConnectivity without treating transport callbacks as business ACKs.

**Architecture:** a real DeviceSync SwiftPM product depends only on MatchSync. A synchronous, lock-protected durable inbox owns copied input before SDK delegate return. A nonactor NSObject proxy strongly retained by the real driver extracts Sendable values; no WC object, Any dictionary or reply closure crosses into the transport actor. Driver sends use cancellable, exactly-once settlement. All Store/business authentication remains in the existing service.

- [x] Add real package/test target plus missing-API red tests for route policy, synchronous inbox takeover/restart and cancellation.
- [x] Add typed driver snapshot/events and transport replies; implement durable hash-ID inbox with bounded file-size-before-read, total quota, startup rehash/scan, duplicate preservation, diagnostics and didPersistDelivery-only input deletion.
- [x] Implement WCSessionTransport: quick deliveries stream, active+reachable+encoded48KiB message route, otherwise identical frame file route; callbacks remain transport-only; actual activation events differ from reachability wake. Expose explicit upper-layer account/localIdentity invalidation notification; SDK lifecycle/pairing never claims account identity.
- [x] Add real iOS/watchOS driver with strong nonactor delegate proxy, fast synchronous reply and copy, iOS inactive/deactivate/watchState guards, watch counterpart-install guard, cancellation and late-callback protection. No App integration or capability edits.
- [x] Complete fake/real-file host matrix, then one full host run and four minimum SDK target builds (iOS17 and watchOS10 simulator/device). Preserve all actual red/failed logs and use unique /tmp caches.
- [x] Freeze source commit for exact-head double review. Save full Git input/log SHA256 manifests outside tree; finish only three docs, clean and stop. Keep branch/tree locally pending paired-device acceptance and018.

## Interface handoff

`WCSessionTransport.events()` provides actual activation (018 calls service.connectionDidActivate), reachability wake (ordinary service.wake), failure and trustInvalidated. SDK pairing/lifecycle changes are distinct from explicit `notifyTrustInvalidated` calls for app account/local persistent identity changes;018 must revoke the provider and stop service on invalidation. No identity/account is inferred from WC state.

`SyncTransport.didPersistDelivery` deletes only hash-addressed owned inbox input after successful Store fragment persistence. Enqueue/reply/file completion never confirms business ACK or deletes inbox input. Device frame cap remains16MiB, consistent with015; fast48KiB policy is an application choice, not an Apple guarantee. Temporary outgoing files and incoming durable input have separate ownership and cleanup.


## 实际结果与审阅

源 `73275bb4724b1525e21e14507c13892d9f297a6e` / target `a5d70759b1ff7c67b92f2082244fd189c119418d` 已双非作者PASS，审阅者为 `/root`质量与 `/root/m2_review`规格。完整host为5 FileInbox +2 MessageReply +2 PairingBaseline +12 TransportLifecycle = **21**，0 failures；四项最低SDK编译通过。仅13个DeviceSync源码/测试路径，唯一作者实际写入，helper仅只读SDK头。

实际文件包括DeviceSyncModels、DurableFileInbox、OutgoingFileQueue、PairingBaseline、WCSessionDriver协议/结算器、NativeWCSessionDriver及WCSessionTransport。出件同ID/bytes去重以持久record+SDK outstanding metadata/token实现；enqueue即返回，实际完成只清运输文件。S16-1使用真实afterRecordRemoval故障点，S16-2安装门闩并发回归；Q16-1以App-owned配对摘要/失效锁存保证重建时不静默替换基准，Native完成检查后才设置activationAccepted。

源证据manifest `c99807b76164adfd621f16f72758312b01112b6a0393c36ea8003715cf9ea177`，189 Git输入/228证据文件，完整目录与命令见[验证卡](../../native/validation/NATIVE-016.md)。21 host+四SDK只证明协议/文件故障/签名availability编译，不证明真实WC通信。transferFile不支持Simulator；代码未接App、最低系统未运行、物理断电/压力未验。三docs最终提交后停写；不合dev、不push临时分支、不归档，等018/物理验收。
