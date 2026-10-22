# NATIVE-055 验证记录

修订冻结 source：`dc9fcee1a869219a5a676d1577fe92c151b7b91a`；prior source：`c55a802b59dbfa94b1a3b8e855d36b3661f26355`；effective base：`27a0aef4dac7f2beb8189303b75a12ac1e1b53da`；计划提交：`2038bad0b935911e24d0ca89d1b0401dfd12567f`。root 与 `/root/m4_recovery_audit` 已分别 whole/source PASS，R55-1 闭合，无其他发现；本次仅两卡收尾，exact final 增量双审尚待 root 安排。

工作树、依赖和所有权见[任务卡](../tasks/NATIVE-055.md)及[具体计划](../../superpowers/plans/2026-10-22-m4-watch-current-evidence.md)。证据根为 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-055`，下文简称 E055；R55-1 新层全部位于 E055/R55-1，不覆盖旧层。

## 实际红绿与先前输入层

| 阶段 | 实际证据及边界 |
| --- | --- |
| 原首次绑定缺 marker | marker-assertion-red：1 项/1 断言失败/0 unexpected；原事务实现后 marker-focused-green 2/0，含 beforeCommit/afterReceipt/afterCommit 和幂等 marker bytes |
| reader 接口与运行 | reader-api-compile-red 为缺 API 编译失败，独立于 reader-unavailable-runtime-red 的 1 项/1 unavailable unexpected throw；原关闭重开事实在实现后通过 |
| 原 facade 转发 | facade-capability-runtime-red：原 SQLiteSessionRepository capability cast 为 nil，1 项/1 断言失败/0 unexpected；只转发其原 Store 后通过 |
| 原三个 consumer | consumer-assertion-red：inventory/erase/current-zero 三项共 7 断言失败/0 unexpected，含错误擦除造成 rows/total_changes 改变；只增三调用后原 focused 22/0 |
| R55-1 检出与修复 | c55 whole 审阅发现历史环境关联未闭合到 signed receipt。四个真实接受 fixture 只 canonical 改写 attempt.context 与 marker 的本地环境为 production，原 development signed raw receipt/hash/key 保持；signed-environment-runtime-red 实际 4 项/8 断言失败/0 unexpected，exit1 |
| R55-1 GREEN | 仅一条 `receipt.body.environment == binding.environment` guard；同四用例及全部 focused 25 Store + 1 Session = 26/0，exit0；完整 rows/total_changes 保全，26 已含后续 Core364 |

原 marker-runtime-red 是 sandbox Swift module-cache 阻断，没有执行测试。marker-runtime-red-executed 的早期测试 helper 用 scalar 读取缺行而抛 missing SQL result，改成 optional rows 后才取得上述纯断言 RED；marker-first-green 缺 try、consumer-runtime-red 缺测试 fixture fields 均为编译层，无测试执行。所有这些原日志保留，未冒称行为红。

prior c55 完整 Core360/0、四最低 SDK 和 Account80/0 只证明 prior source。首个 frozen-account-full 的 163 项 Swift 输入未包含 Node fixture 实际读取的 Backend，随后同 c55 再执行 frozen-account-complete-input-full，以直接冻结的 212 项输入得到独立 80/0；不与首轮相加。这些旧层未冒称覆盖 R55-1。

## 修订 source 的完整矩阵

本节六个独立命令均在同一修订 source bytes 上执行；每次执行前直接复制同 **212 项** tracked 输入（含 49 个 Backend 运行依赖），manifest SHA256 为 `904c9998af6b9fd98af3fbe68326e9b3cda26fffba5ab93c0e5286c6fc5bea40`，每次 after 零漂移。原 argv/cwd/exit/实际计数/rawlog SHA 位于 E055/R55-1 的各 `*-result.json`。

```sh
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE055-r55-1-core-full
swift test --package-path native/Modules/AccountKit --scratch-path /private/tmp/football-record-NATIVE055-r55-1-account-full
```

| 独立完整命令及其 XCTest 可执行项 | 实际结果 |
| --- | --- |
| Core 同一完整命令内 MatchCoreTests | 44/0 |
| Core 同一完整命令内 MatchStoreTests | 234/0 |
| Core 同一完整命令内 MatchSessionTests | 69/0 |
| Core 同一完整命令内 MatchSyncTests | 17/0 |
| Core 完整单命令合计 | **364/0，exit0** |
| 独立完整 AccountKit 命令 | **80/0，exit0**，其中原 WatchRegistrationTests 11/0 已含于 80 |

Core364 与 Account80 是两个独立完整命令，不称一次 444 项；focused26 已包含于 Core364，不再相加。新 Core raw log SHA256 `0d6d5983c8fa8ffa945fb7087987473f49928f9a0fc90ed5f1d22decbac298a9`；Account raw log SHA256 `2beb1b9a621a9b685aa0b1460750dafa511bd79ac76cd9e549b34bd89dd4f47a`。

四项命令均为 `xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk <实际 xcrun SDK_PATH> --triple <下表 triple> --scratch-path <独立目录>`；实际 SDK 路径与完整 argv 保存在相应 frozen-sdk-*-result.json。

| 实际 SDK / 最低 triple | 实际结果 | 原日志 SHA256 |
| --- | --- | --- |
| iPhoneSimulator27.1 / arm64-apple-ios17.0-simulator | exit0 | `c5e35661abb29ef2a42f624b6f4438fa471877ae9c0a688513fc0f602480607c` |
| iPhoneOS27.1 / arm64-apple-ios17.0 | exit0 | `7d5d4f32ec9d177f790b5fa09b2dd8dddbab2144eba156fea4705e37bd5a2f5a` |
| WatchSimulator27.0 / arm64-apple-watchos10.0-simulator | exit0 | `6c05aa852950ae5bdabbd9eb4408d80101dc8068984d573c29b9d571cfd86d67` |
| WatchOS27.0 / arm64-apple-watchos10.0 | exit0 | `2b85280ff47edfff41b4979a52a11e00dc1efec199c5fc4b842bf6e43654de01` |

实际 Xcode27.1 / Swift6.4 与 Node 版本保存在 R55-1/tool-versions.txt；最低 iOS17/watchOS10 未变。原有 LifecycleInboundCoordinator unused repository warning、Node SQLite experimental warning 如实保留，未借本任务改其他路径。

## 输入、审阅与最终收尾

- E055/R55-1/source-checkpoint-dc9fcee.json SHA256 `483bb0aa12772878361406e1c214f4ebe07af1f3ca37f465941df8137a92b4af`：212 输入的 Git mode/blob/hash/size、各直接 before copy 与六个完整命令；同 source/current Git bytes 全相等。
- R55-1 新冻结 evidence-manifest-source-dc9fcee.json 包含 **1724** 份证据，SHA256 `37307f551fa7126dd5a034d5d7e96e779b2c7ad43195d6fe964a9e80616923f3`；旧 c55 index 包含 **3357** 份，SHA256 `78e3bf342e26e7917a99f6ce43e3ddc64d828e88619cbbf92858e7e7c630624c`。两层逐文件 hash/size 保全，未混合成新 source 单轮证据。
- 旧 E055/source-checkpoint-c55a802.json SHA256 `411179e7ad5461cd69b2f3f06fb4b6db127a43c13b0e0aab69f5e1abe1c033d1` 保持。R55-1 RED 的产品 bytes 等于 prior c55 helper，RED 测试 bytes 等于新 source 测试；GREEN/full bytes 等于新 source，均为执行前直接保存，非事后推测输入。
- root whole-source-review-root-dc9fcee.json SHA256 `0f9508e50e3e989986e8762ae60cefeed9e5ba4f85d8beeab0279019928a46df`，second source-review-recovery-dc9fcee.json SHA256 `978cc34c0452a5cf395089c65763da99e8726e3425f71155121017b574afb8f7`，均在 R55-1 目录，对 whole revised source PASS、R55-1 闭合且无其他发现。审阅者只读复核原作者日志与全部输入/证据，未重新执行产品测试。
- 最终只改 task/validation 两卡；产品/测试/计划及其他 tracked 条目保持修订 source。计划 SHA256 仍为 `125f9f0139bbcfdd0b5fa7b816789a8e10b92f0f56acbb4aae7e8a309fbbd97c`。exact final 的全树差异、212 输入、两层 evidence 全 hash、链接/diff/clean 含 ignored 对照另存 final checkpoint，待双方增量复核。

## 证明边界

新覆盖包括真实原接受事务故障/重放、legacy 和 receipt-only 不补造、较新 marker 不倒退、当前完整 tuple/generation/admission 与 fixed trust、authority/device key 区分、两真实 SQLite 连接快照及持 writer 时读取、全表 rows/user_version/total_changes 无 mutation、失败后释放快照、保留旧控制事实及严格库存/擦除/zero。R55-1 额外闭合可检测的 signed environment 矛盾，不声称抵御所有本地 metadata 协同改写/回滚。

结果只证明本地当前接受来源，不是 live credential、资源 scope 或业务/录制准入；026 仍须独立身份、原资源 owner、signer/lifetime 检查。历史 getter 继续可读旧事实，历史库存校验不依赖当前 generation/admission；新 current reader 独立严格检查当前条件，删除后保留 marker 不等于仍授权。

本机事务/reader 不需用户接设备。SDK 仅编译；未执行 App/UI、真实 Apple/Keychain/iCloud/CloudKit/Health/WC、个人账号、签名设备、部署、whole026/M4 或发布验收。生产默认 Unavailable 保持，main/release 不动。作者停写，不 merge/push/archive 或推进长期分支；最终双审、实际 held026 接入/复验与后续安全治理由 root 执行。
