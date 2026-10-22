# NATIVE-053 验证记录

冻结 source：`fd5b0a3468eee62b9d191eaa65dadf857d30ed2a`。base：`2cab4640ee3a375da39fdabf0f5a317600b0c263`；计划提交 `bed07e1e7792584f564eeff8530b7b73d49eee8d`。root 与 026 消费者已分别完成 exact source 审阅并 PASS；作者最终两卡增量仍须双方复核。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-053`。

## 实际红绿与证明边界

1. 只有新测试、没有新 API 时，`api-compile-red` exit1：原 MatchStore 缺少 currentAuthenticationEvidenceV4，连带 XCTUnwrap 类型无法推断；104 项输入零漂移。这是接口编译层，未称安全行为红。
2. 新接口暂只抛 unavailable，原真实 save/accept 认证后关闭重开，同一测试 `unavailable-runtime-red` 实际 1 项/1失败（1 unexpected throw）、exit1；105 项输入零漂移。只读快照实现后 `original-grant-green` 同一用例 1/0、exit0。
3. 原 facade 尚无 optional protocol 转发时，`facade-runtime-red` 实际 1 项/1断言失败（0 unexpected）、exit1：对同一原 SQLiteSessionRepository 的 capability cast 是 nil。加入原 store extension-only 转发后，新 focused 15/0；没有用额外 facade 代读。

15 项实质覆盖原 signed receipt/attempt/binding 关闭重开、原 afterCommit 正面 SQL 丢响应、beforeCommit/afterReceipt 回滚、waiting 角色、不借 suspended 或世代变化的历史 grant、canonical/checksum 正确但单项关系矛盾、坏签名/未知 key/异 purpose、超限/非 canonical 行保全。另有真实第二连接在首次读后提交世代和 binding、持写锁时只读成功、所有表行/user_version/同连接 total_changes 不变与错误后连接正常写入；并发测试不以任意 sleep 放行。

正常初始 auth-admission 为 0，缺失 identity-generation 沿旧读取规则也是 0；新读取不补写这一行。部分或 pending 状态 typed blocked，完全无认证事实才 nil；nil 不证明 namespace 无业务。只读方法不新增诊断、quarantine、schema、网络、vault 写入或任何业务准入。

原 auth receipt 验签明确绑定 requestID/digest/account/epoch/result；device/key/cloud 通过原 accepted 本地 tuple 关联，不能重建未保存的 transient auth body，也未声称 receipt 对这些字段作了不存在的独立签名。026 仍须原资源、signer、独立当前身份与世代/lifetime 门。原 receipt 没有 credential expiresAt，读到旧签名不代表当前 credential 或服务端授权有效。

## 同一冻结 source 的完整自动验证

完整 Core 实际命令：

```sh
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE053-host
```

| 单次完整 Core 内的 XCTest 可执行项 | 实际结果 |
| --- | --- |
| MatchCoreTests | 44/0 |
| MatchStoreTests | 164/0 |
| MatchSessionTests | 47/0 |
| MatchSyncTests | 17/0 |
| 本轮完整合计 | **272/0，exit0** |

focused15/0 是前一独立命令，包含于完整272，不再相加。四项独立 SDK scratch 的命令逐条保存在 frozen-sdk-*-result.json，SDK_PATH 实际取自 xcrun，不猜路径；所有 target 都是 MatchSession，故编译到新 facade forwarder 和 Store 依赖。

| SDK / 最低 triple | 实际结果 | 原日志 SHA256 |
| --- | --- | --- |
| iphonesimulator / arm64-apple-ios17.0-simulator | exit0 | `1a2354cc950e603b9dffd4a697f3d788cc5df30038deaecd4517cfd8e3bbcf8f` |
| iphoneos / arm64-apple-ios17.0 | exit0 | `e19c4703776c1ad43f314683e4ba4f7ed6eede63dfe57509c403460f758904da` |
| watchsimulator / arm64-apple-watchos10.0-simulator | exit0 | `010471206c9f21de00462dcdf55b8b47452d125a63f6286f13019c8eb2292dd0` |
| watchos / arm64-apple-watchos10.0 | exit0 | `25bd48602060bd6c715500d146a3876f500abcab29a1aafee955e40e8005a1a1` |

完整 Core raw log 为 frozen-core-full.log，SHA256 `9c90bd5d47dc952af268920033801847ca9ea6bc8de27970ab6a5e6d07a404e5`；focused-first.log SHA256 `f3e1d9a1f387b7a4f7038ac6a51c3874fa0765e2c9500c197daeabea8746cab2`。工具版本保存在 tool-versions.txt。

## 输入与审阅证据

- source-checkpoint-fd5b0a3.json SHA256 `00620d0b325aa5620d8f305b29ff393101cb1e7a1f561771f628db8c43e9e4b1`：106 项 Core Package/Sources/Tests/Fixtures 的 Git mode/blob/hash/size，以及 677 份冻结证据。
- 所有 10 个阶段的 before/post 输入零漂移；初始104、Store占位/实现105、加入forwarder后106有明确层次。最终完整矩阵均为同106输入，逐 Git source 比对。
- API/首项运行红期间的原测试及 unavailable 占位文件，在变更后按先前记录 hash 重建并逐字验证；input-preservation-audit.json 明确记录这一保全来源，没有冒称执行前已复制这些字节。其余对应未变输入核 hash 后保存；后续冻结完整源输入在执行前直接复制。
- root exact source 审阅记录 source-review-root-fd5b0a3.json SHA256 `a51fa70a76f2dbc7793610bc91466838493ad9950b7b72e7dc01916aea5eb7b1`；消费者独立报告对同 source 无发现。两位均审阅作者实际日志和哈希，未把审计说成重新执行。
- 最终只允许 task/validation 两卡收尾，计划 SHA256 仍为 `c02d3dca5973b5e0b9f79b7b727018582aab811032e400c5dcdd35e306aeb31d`，全部106产品/测试输入与 source 不变；exact final 对照另存树外。

本轮不需要真机：改动为本机 SQLite 读取及原 facade 转发。四 SDK 仅编译；未执行 App/UI、实际 Apple/Keychain/iCloud/CloudKit/Health/WC、个人账号、签名设备安装、部署、整包026或M4验收，生产默认 Unavailable 保持。源码双审不代表整体发布。

作者不 merge/push/archive 或推进 dev/release/main。最终增量双审、实际目标接入及相关复验由 root 执行；活跃依赖期间不清理任务树。
