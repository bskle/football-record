# CloudSync（NATIVE-022）

独立 SwiftPM 云传输模块，最低 iOS 17 / watchOS 10。它不直接写 MatchStore，不连接 CloudKit，不生成生产 `VerifiedCloudSave`。生产 App 装配没有变更；未注入业务 bridge 时，sink 明确返回 `awaitingBusinessImport`。

## 数据与持久化

`CloudScope` 固定 accountID / cloudSpaceID / zoneID / activationEpoch。`stableZoneKey` 不包含 epoch；新 epoch 的 fetch 可以读取同一稳定 zone 的合法历史。历史读取不授予旧 epoch 当前写入权限：`CloudUpload` 要求 record 与当前完整 scope 相同，旧 pending 不自动换账号、zone 或 epoch。023 bridge 仍须验证只读恢复授权。

scope 的相等与 Hashable 使用三个 ID 的原 UTF-8 bytes 加 epoch，与既有 stable-zone/SQL key 身份保持一致。Unicode NFC/NFD 字符串即使在 Swift String 中规范等价，只要原 bytes 不同就是不同 scope；不会在枚举清理、upload 或 save readback 边界合并。既有编码、hash域和keys不归一化、不改写。

`CloudMatchFacts` 复用 MatchCore 的 start identity、完整 events（含 correction / deleted tombstone）与非健康 capture metadata；不保存 permit、后台 release 或 completion。`CloudPayload` 只有 `MatchFactsV1` / `CheckpointV1` / `DeletionV1` 的固定 typed 内容，没有开放 properties 或健康/GPS字段。解码后 canonical round-trip 拒绝未知字段/枚举；record ID 由稳定 zone、类型、match 与完整内容摘要域 hash 派生。纯结构回放的临时 development permit 不进入 payload 或台账，不能成为授权来源。

每份业务 payload 上限 8 MiB。Data/base64 的外层 envelope 单独限为 64 MiB；一个下载批次最多 64 records 且仍受 envelope 总量限制，超限显式失败，不截断。合法近 8 MiB typed payload 已测试 enqueue、close/reopen 原 bytes 相等。时间写入使用 checked Int64 毫秒转换，超范围有限 Date 也会被拒绝。

`SQLiteCloudLedger` 用独立文件、参数化 SQL、BEGIN IMMEDIATE、WAL / synchronous FULL。cloud ledger schema 4 与 MatchStore 的版本无关。升级前先验证已有结构与 canonical 归属；所有升级 DDL、最终结构检查和版本在同一事务中提交。不兼容/损坏文件保留。上传、staged batch、失败次数/重试时间、双方冲突原 facts、changeTag 与首次 development save evidence 均持久化。相同 ID 异 bytes 拒绝；peer 路由/ACK 不影响独立云队列。

## Driver 与业务 sink

`CloudDriver.fetch(scope:cursor:)` 输入的是业务 sink 的 `CloudCursor`；token 是不透明 Data，模块不解析、排序或猜测其时间。driver 输出完整 `CloudFetchBatch`，包括 scope、batchID、原 records、expectedAppliedToken、nextToken、fetchGeneration、moreComing。显式删除由 `CloudDeletion` 表达；远端缺席不表示删除。

`CloudCommitSink` 的固定方法是：

```swift
func importBatch(_ batch: CloudFetchBatch) async throws -> CloudImportAcknowledgement
func appliedCursor(scope: CloudScope) async throws -> CloudCursor
func resetCursor(scope: CloudScope, expectedGeneration: Int64) async throws -> CloudCursor
```

服务先持久 stage，再调用 sink，检查 ACK 的 scope / batchID / 全 batch digest / token / generation，最后确认 transport stage。任何下载失败或导入失败都不使 transport inbox 成为 cursor 权威。每次 `synchronize()` 处理已存 pending batches，或一次到期上传，或一次 fetch；调用方根据队列和已存批次的 moreComing 继续唤醒，不能把单次 issue=nil 当作整个云库/比赛已经完成。

sink 必须在现有业务 facade 同一事务内：先查询并重放首次 receipt，再 CAS 原 parent token bytes 与 generation，再合并全批事实/显式 tombstone、保存 receipt 和 nextToken。原 batch 的失 ACK 重放返回首次结果，即使 cursor 后来前进也不倒退；不同 batch 父 token 不符时拒绝。reset 用 generation CAS 递增并清空 token。未提交的旧 generation batch 不可恢复旧 cursor；已有 receipt 重放只返回原结果。

022 的 `FixtureCloudSink` 只在 Tests 中，用真实独立 SQLite facts / tombstones / receipt / cursor 表验证这些事务故障。它没有接入现有 MatchStore、Session 队列或生产授权。023 必须提供显式 same-facade bridge，不能将此 fixture 安装到 App。

## 保存、冲突与重试

`CloudDriver.save(_:)` 接收持久原 upload 与 expectedChangeTag。完整返回必须同时匹配事实 record、checkpoint manifest 与每个 part 的 ID / changeTag / `.ifServerRecordUnchanged` 策略。服务验证 manifest 版本、scope、match、snapshot/fact/capture digest、terminal event、checkpoint、全部有序引用、每份长度/hash、合并后的完整原 bytes；缺 part、partial failure、无条件保存、空 tag 或任何跨 snapshot 内容都不能确认。

检查成功后只形成 `DevelopmentCloudSaveEvidence`，固定标识 `controlledDevelopmentTransport`。这不是可信生产 CloudKit 保存证明，也不是比赛完成/后台放锁证据。当前全 facts/capture 改变时旧 evidence 不匹配新 upload；023/024 必须在可信 SDK 与同 facade 边界重新验证，不得将 development evidence 升格为 production。

同 ID 异 digest 或 changeTag 冲突保留本地与远端原 typed facts 和 tag，上传 blocked，不做 LWW。partial、quota、网络、账号不可用、权限和 unknown 是有限 typed issue；时钟可注入，指数重试上限 3600 秒，quota 首次 60 秒。分析默认开关不参与业务云队列。坏批次 blocked 会阻止继续 fetch，旧 generation/父 token 已失效的批次保留而不复活 cursor。

accountChanged 是持久 scope fence，重开不自动解除。服务在网络前后复查；stage / ACK / save evidence 的新进度写入还在各自 SQLite 事务内复查，防止检查后账号切换的竞争。已有完全相同 receipt 可以只读重放；历史读取与本地 pending 意图可保留。新账号/epoch 需新 scope，旧上传不重绑。

scope / upload / batch 的可选持久 issue 只将 SQL NULL 视为无 issue；非 NULL 必须是已知 CloudIssue 枚举，否则抛 invalidPayload，保留原文件与原 bytes，并在任何 driver 调用或业务导入前停止。不会把未知状态自动清除或当作恢复正常。

## 账号迁移控制检查点（NATIVE-031）

`CloudCheckpoint.account(scope:checkpointID:recordIDs:)` 接收调用方持久的稳定控制 UUID 与当前完整已确认 facts 的 recordID 集合。其 `matchID` 固定为 `CloudCheckpoint.accountMatchID(for:)`，即 `account-checkpoint:<scope.stableZoneKey>`；仅此账号控制锚允许空集合。它只产生 checkpoint 元数据，不创建 Match、events、permit 或 scratch facts。非空引用仍去重校验并排序；普通 match checkpoint 仍要求非空引用。

CloudRecord 的 typed / raw canonical / Codable 导入边界都检查控制锚与 record 的 account、cloudSpace、zone 精确一致；错 hash 或其他稳定 scope 的锚被拒绝。epoch 不属于 stable zone 锚，旧 epoch 合法历史的读取规则保持。调用方的业务 bridge 仍负责确认引用集合就是当前完整已确认 facts，不能用控制记录代替业务集合核验。

迁移提交绑定的是该控制 **CloudRecord.recordID + CloudRecord.digest（canonical bytes 摘要）**。`CloudCheckpoint.checkpointID` 是稳定控制 UUID；`CloudUpload.checkpointID` 仍是既有 asset manifest ID，与迁移提交 ID 不同。普通非空 match checkpoint 的 canonical bytes、recordID 与 digest 编码规则不变。031 的六项回归与原47项在同一轮完成53/53；两项 fresh 最低 simulator target 编译通过，详见 [031验证卡](../../../docs/native/validation/NATIVE-031.md)。

## 验证与交接

### 单 ledger 本地传输清理（NATIVE-033）

`CloudLocalTransportErasing` 是独立可选协议，原 `CloudLedger` required 方法不变。默认 `UnavailableCloudLocalTransportEraser` 返回 storageUnavailable；025/026 必须显式注入拥有具体文件的 SQLiteCloudLedger。调用 `eraseLocalTransport(CloudLocalTransportEraseRequest(requestID:scope:))` 使用稳定 requestID，按 scope 的 accountID/cloudSpaceID/zoneID 精确选择该文件中所有 epoch，清理 upload、staged batch（含ACK）、conflict双方原内容与save evidence的canonical副本。026在业务擦除前保存稳定requestID和完整原scope供重试，不能换成重开时的新epoch重建同ID请求。

一次 BEGIN IMMEDIATE 内先重放相同 requestID / 完整请求摘要的首次 receipt，否则严格解码并核对原 bytes、scope key、digest、batch ACK，再写永久 stable-zone fence、删除目标、读回核实目标 canonical 零、保存最小 receipt。同 ID 异请求拒绝；无法判断归属、未知状态、坏原bytes或NUL/非法UTF8文本时整次失败，保留文件和原数据。其他账号、空间或 zone 的原 bytes 不变。两个控制表只保存稳定scope hash及requestID/摘要，不保存业务原bytes、saga capability或Health选择。

fence在所有canonical写事务中检查；旧连接及迟到 save/fetch/conflict 回调不能复活数据。scopeState将该稳定zone永久呈现为 accountChanged 阻断，clearScopeIssue和新epoch都不能解除；服务开始/await返回后停止新进度。COMMIT前失败全回滚；COMMIT后丢响应以同一请求重开重放首次receipt。没有in-file unfence API。

033 receipt只证明**该ledger文件四表的逻辑清理**，不是整个本地数据完成、物理介质/备份擦除或CloudKit删除证明。026仍须遍历完整owned ledger catalog，处理024 CKAsset staging文件和023业务Store，并保留独立saga/capability/028 selection恢复控制。恢复保留云时先使旧actors失效，再由026明确选择新ledger namespace/文件和已授权业务cursor初始化；旧文件永久fence继续拦旧实例。生产装配仍默认unavailable，内部表名不作为产品UI文案。

033的完整host与最低SDK实际结果见 [033验证卡](../../../docs/native/validation/NATIVE-033.md)。

```sh
swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-022-host
xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-022-ios
xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-022-watch
```

本任务使用文件 SQLite 与受控 driver，覆盖原 bytes、失败重开、双连接 parent CAS、receipt 优先重放、token 过期、tombstone、quota、完整保存约束及账号切换 TOCTOU。确切 SHA、单轮数量和原日志见 022 验证卡及树外 manifest。

024/026 尚须真实 CloudKit private custom zone、CKServerChangeToken archive、CKAsset 上传/回读与回调内复制 staging 文件、真实 quota / accountChanged 及设备/账号验证。022 两个最低 SDK target 编译不能替代这些门槛。该模块未修改工程、App Bootstrap、共享 Core、verify.sh 或既有 canonical 协议。
