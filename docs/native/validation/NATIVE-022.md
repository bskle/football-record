# NATIVE-022 独立云台账验证

日期：2026-10-18～19（上海）。范围：文件 SQLite transport ledger、受控 driver、独立测试业务 sink。状态：软件候选自动验证通过，等待两位非作者对最终 exact HEAD 审阅；本卡不宣称真实 CloudKit、现有业务库导入或 M4 完成。

## 输入与同步

| 输入 | 值 |
|---|---|
| 原始 base / 登记目标 | `5e876cfd875585b315b57f91bcb8dc7160f8afa6` |
| 当前已验证 dev 目标 | `a15b8414c460026e5ea7725f9c17ea08ce9ed737` |
| 第三切片源码提交 | `6a7b59fbaacdd2d47d5313ec1d08f8279ed39495` |
| 任务分支普通同步 merge | `d135d48a02b5b90f9469ce6d076890ff449a9b49` |
| 任务分支 | `feat/m4-cloud-ledger` |
| worktree / attachment | `/Users/liam/.codex/worktrees/m4-cloud-ledger/20260830_足球记录` / `01a14f8f-ff04-7203-97ef-8121e71ad4cb` |
| 最终可审 HEAD | 树外最终 Git 输入与 input-manifest.json；不在本提交写自身 SHA |

目标前进后先保存第三切片，再 ordinary no-ff merge 021 已验证 dev。`dev-native-diff.txt` 证明两 dev 输入的 native/scripts 差异为空；`pre-sync-native-inputs.json` / `post-sync-native-inputs.json` 的 **97 文件 SHA256 全等**，`sync-proof.json` 绑定同步前源码、当前目标与实际 merge。没有 rebase/amend/stash/reset，也未推进长期分支。

## 实际命令与结果

| 层次 | 命令 / 原日志 | 实际结果 |
|---|---|---|
| 同步后完整 host | `swift test --package-path native/Modules/CloudSync --scratch-path /private/tmp/football-m4-022-host`；`post-sync-host.log` | 39/39，0 failure：16 Conflict + 10 Ledger + 13 Service |
| 最低 iOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-022-ios`；`ios17-simulator-build.log` | Build complete，exit 0 |
| 最低 watchOS target | `xcrun swift build --package-path native/Modules/CloudSync --target CloudSync --triple arm64-apple-watchos10.0-simulator --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" --scratch-path /private/tmp/football-m4-022-watch`；`watch10-simulator-build.log` | Build complete，exit 0 |
| 文件卫生 | `git diff --check`、限定路径状态/差异、最终 clean | 作者交接时记录树外 Git 输出 |

工具：Xcode 27.0（27A266a），Apple Swift 6.4；完整输出见 tools.txt。最终 host 与两个 SDK 日志无 warning。SDK 使用实际当前 SDK、最低 triple 为 iOS17/watch10，不是最低 OS 真机运行。SDK 在第三切片源码工作树上执行，随后以相同源码形成 `6a7b59f`；同步后 native 输入无变化，保留该层次，没有声称 SDK 在新组合上重跑。历史 9、21、31、33、36 项日志各自只属于当时切片，不与最终 39 混加。

## 红绿与故障覆盖

| 行为 | 红证据 / 最终断言 |
|---|---|
| upload/batch 原 bytes、独立 peer ACK | 022-1 缺接口红；稳定快照去重、同 ID 异载荷拒绝、持久 deletion/attempt、真实 Store route/ACK 后 cloud 独立 |
| 近 8MiB / 安全日期 | `022-1-boundary-red.log` 重开 payloadTooLarge；`022-1-date-red.log` 原 Int64 trap；修后同 bytes 重开、超范围拒绝且行不变 |
| facts/token 同事务 | `022-2-red.log` 缺 sink/service；fixture 在 facts 后 token 前失败，重开 facts=0/token=nil、原 batch 保留；重试原子出现 |
| receipt 优先 / opaque cursor | COMMIT 丢 ACK 后重开、更新批次后重放原 receipt 不倒退；不同 batch 父 token CAS、双 SQLite 连接单赢家、opaque 0/255 bytes 原样复用 |
| expired generation / 旧 epoch | reset CAS 递增并清空 token、旧 batch 拒绝；全扫保留 pending/tombstone；同 stable zone 可读旧 epoch，upload 不换 scope，外账号拒绝 |
| 不兼容旧 schema | `022-3-green-compile.log` 中 v1 缺表/缺列先红显示文件/version 被改；统一预检/DDL事务后 `022-3-green-schema.log` 通过并保留原文件/version |
| 完整保存与修订 | partial 不出 evidence；条件保存/原 bytes/hash/长度/全部 part 引用/manifest 版本与 scope/checkpoint/fact/capture/terminal 绑定；同 match capture 修订使旧 evidence 不匹配 |
| logical record policy/tag | `022-3-logical-record-red.log` 先红；新增逻辑 record 自身条件保存和非空 tag 后通过 |
| accountChanged / TOCTOU | `022-3-fences-red.log`、`022-3-toctou-red.log`；重开停网络、在途 fetch 丢弃、直接 ledger 暂停及拦截 ledger 在检查后暂停三种进度事务均不确认 |
| 冲突 / quota / tombstone | 双方原 facts/tag 保留、blocked 无 LWW；quota 60秒持久 backoff；unknown 不当空库；remote absence 不删、显式 tombstone 后迟到原事实不复活 |
| 失响应 | stage/save evidence 在 COMMIT 前回滚、后丢响应重开保留首次原结果；重试不重复，错误 ACK 无法确认 batch |

fixture sink 位于 Tests，用真实独立 SQLite tables 证明原子性和重开语义；它不能证明现有 MatchStore 或 Session 已导入。受控保存产物名为 `DevelopmentCloudSaveEvidence`，固定 `controlledDevelopmentTransport`，没有 production VerifiedCloudSave 构造工厂。正常完成/后台放锁仍由 023 的双证据与当前事实验证负责。

## 未验与证据位置

023 同业务 facade / 同场队列 bridge、024 真 CloudKit private zone / CKServerChangeToken archive / CKAsset / SDK 回调内复制、026 真实 Apple/iCloud 账号、签名设备、quota/accountChanged 与完整 E2E 均未验。没有修改 App/工程/共享 Core/verify.sh，生产默认路径仍 unavailable；真机对本任务隔离台账与协议单元验证不适用，不能替代后续设备门槛。

树外目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-022`。保留初始及最终六项 Git 输入、原始红绿/SDK日志、工具版本、输入文件 hash 与 evidence SHA256 manifest。双审、合入、实际 merge SHA 与生命周期由主代理补入树外 registry；作者不自行 merge/push/archive。
