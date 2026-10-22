# NATIVE-052 验证记录

2026-10-22：[任务卡](../tasks/NATIVE-052.md)、[计划](../../superpowers/plans/2026-10-20-m4-deletion-control-reauth.md)和[合同](../contracts/m4-account-lock-cloud.md)对应的 whole source 为 `04c5393cceeb5dbc6ec90d3af422d26d63ce93de`。两位非作者源码审阅均 PASS；本次两卡 final 尚待窄审，未合入026。

证据目录（下文 E）：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-052`。所有 manifest、原始命令、日志、source/final SHA 与审阅记录存树外，不在卡片回写自身提交 SHA。

## 固定源码与双审

| 记录 | SHA256 |
| --- | --- |
| `resume-source-c52-6-checkpoint.json` | `f3cf5afd4e400b769e76d469ee56f4dee5c5f8523c8d9c8b0740a99aba57dce3` |
| `/root`：`resume-whole-review-root-04c5393.json`，whole PASS | `7e56367151dbd316a12c46b68287435ec12b2b42a4046bea4d388a51f19c53e3` |
| `/root/m4_recovery_audit`：`whole-source-review-recovery-04c5393.json`，whole local software PASS | `7464e345aeb906237669a4275f40118b860460c934f2c0a2055bb088a1701911` |

相对 effective base `07c1b92a75d1c9998afecbfb8cb731a464b414af` 仅20条 owned 路径，C52-6 相对 `1c41d88277025b1101a5c5b0e5b61c6b35ee3bb2` 仅已双审计划允许的7条路径。source checkpoint 固定207条运行输入及53条证据；两位审阅者核对全部 Git mode/blob/size/hash、证据哈希与实际日志，未声称审阅者重跑运行矩阵。

6个命令均在冻结 WIP 上执行，命令记录当时 Git HEAD 为1c41；冻结内容随后提交为04c5393，所有实际输入已逐条匹配04c5393。每个命令 before/post 差异0，exit0，不能把提交前的命令 HEAD 写成04c5393。final 仅两卡改动，不重跑不受影响的产品矩阵；其全树差异、207条 runtime 和18条非卡 owned 输入的 source/final blob 对等，由 `resume-final-checkpoint.json` 记录供窄审。

## 最新受影响范围实际验证

命令 cwd 均为 `/Users/liam/.codex/worktrees/m4-deletion-control-reauth-resume/20260830_足球记录`；完整 argv、SDK 路径、时长、输入、日志 SHA256 见同名 `-command.json`、`-inputs.json`、`-post.json`。工具版本为 Xcode27.0 / Swift6.4；最低系统未升级。

| 实际命令 / 日志标签 | 结果 |
| --- | --- |
| `swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE052-core-resume --jobs 4`；`resume-c52-6-full-core` | **323/0**：44 Core +194 Store +68 Session +17 Sync |
| `swift test --package-path native/Modules/AccountKit --scratch-path /private/tmp/football-record-NATIVE052-account-resume --jobs 4`；`resume-c52-6-full-account` | **80/0**，其中专用控制流程26项 |
| `xcrun swift build`，AccountKit，iPhoneSimulator27.0 SDK，`arm64-apple-ios17.0-simulator`；`resume-c52-6-sdk-iphonesimulator` | exit0 |
| 同上，iPhoneOS27.0 SDK，`arm64-apple-ios17.0`；`resume-c52-6-sdk-iphoneos` | exit0 |
| 同上，WatchSimulator27.0 SDK，`arm64-apple-watchos10.0-simulator`；`resume-c52-6-sdk-watchsimulator` | exit0 |
| 同上，WatchOS27.0 SDK，`arm64-apple-watchos10.0`；`resume-c52-6-sdk-watchos` | exit0 |

本轮宿主 **403/0 是两个完整命令合计**；四 SDK 为编译验证，没有真人设备或账号验收含义。所有 SDK 命令 target 为 `AccountKit`、jobs4、独立 `/private/tmp/football-record-NATIVE052-AccountKit-<sdk>-c52-6` scratch，完整精确 argv 以原记录为准。

## Backend 独立保留层与历史

Backend scoped source `58ff1f1b4f7ceece4e5019d71ad72b9c69daba78` 先前已双审；最新已有 Node 整包 **228/0，193 top-level** 原始命令为 `resume-fixed-whole-node`，固定于1c41候选层。当前7路径修复未改 Backend，其49条实际 Backend consumer 输入与04c5393逐条相同。此处保留历史 Node228，不重跑、不加进新403，也不把旧整个207条输入误称全部与新 Swift 输入相同。

| 历史 source | 原层结果与状态 |
| --- | --- |
| `50463f4bb3b2c582d191d6bb5448ab46d310ebf1` | Core317/0；审阅发现 C52-1～3，不作最终通过。 |
| `f96289f7edc5646700c4352c6b51e677137e618b` | Core321/0；C52-1～3 修复获 scoped 双 PASS。 |
| `f13965032600a6ac20568ab871104ce42990b084` | Node228 +Core321 +Account75，三命令624/0及4SDK；whole 审阅发现 C52-4/5。 |
| `1c41d88277025b1101a5c5b0e5b61c6b35ee3bb2` | Node228 +Core321 +Account79，三命令628/0及4SDK；C52-4/5 修复后 whole 审阅发现 C52-6。 |
| `04c5393cceeb5dbc6ec90d3af422d26d63ce93de` | 新 Core323 +Account80，两命令403/0及4SDK；C52-1～6 均闭合，whole source 双 PASS。 |

旧 snapshot 恢复记录 `resume-20261022-restored.json`、旧编译 RED、行为 RED、旧 checkpoint 和各次 CHANGES_REQUIRED 均保留，不覆盖为通过或混加计数。

## 真实 RED→GREEN 与安全边界

| 发现 | 保留的实际验证 |
| --- | --- |
| C52-1 丢失 ready 后 trusted closing、C52-2 原 Watch ID 碰撞、C52-3 closing 后晚到 ready | 4测试/6失败的行为 RED → focused4/0 → Core321/0；同 SQL 不污染原库、不接纳已 closing 的 active ready。 |
| C52-4 SQL accept/vault 等待跨 TTL、C52-5 旧 attempt/new generation | 3测试/5失败的真实 RED；修复后专用24/0，再补 vault TTL 为25/0；当前全部26/0。新 generation 在签名/HTTP 前拒绝。 |
| C52-6 已准入 vault 等待期间第二控制服务 recover 已可信 revoked | `resume-vault-closing-red` 1测试/1失败；原 Node 撤销、同库第二 recover 已落 closing、parent/gen/TTL 不变。修复后 `resume-vault-closing-green` 专用26/0，不再返回 ready；已准入 vault 正面 write 保留并 join。 |
| current-ready 门反例 | 独立接口编译 RED `resume-ready-gate-api-red`；context-only 门行为 RED `resume-ready-gate-runtime-red` 2测试/4失败；`resume-ready-gate-green` 2/0，覆盖不同 signed raw、closing、过期、错误/新 generation、当前 completed parent 与 retained history，确认无控制行写入。 |

same-SQL current-ready 门在原 Store 同事务验证严格历史、原 parent/control/cap/raw scope/binding/key/generation、原 auth attempt、固定 trust 的原始 signed ready、未 closing 和当前 TTL。vault 前后最后 await 为此门，之后仅同步 running/full tuple/当前时钟检查；无异步 history/context 再穿过门。它提供当前检查点，不提供未来有效期租约或 SQL/vault/独立身份/时间的全局原子性。已经准入的正面 vault 写入可能晚于并发 closing/过期，须 join 和保留，不宣称可撤销已执行 write；最终不能错误返回 ready。

控制 purpose 仅原 parent，旧 business gate 永久关闭；不走 generic signIn、不造新身份/Match、不恢复 Watch 业务。unknown 仅 recover 原 auth ID，401/404/timeout 不证明关闭；knownAbandoned 不证明历史未 commit。challenge-only 丢失分支严格限定尚无 auth attempt/尚未派发 auth POST 或 Apple code，并在结束前复查原 parent/gen/scope；它只要求调用方显式新 IDs，不自动重试或归类已存在 auth。

公开服务操作保留 owned FIFO、取消传递和 stop-and-join；026 owner 还须串行 Lifecycle resume、join 全部控制尾部再关闭原 Store，整包 owned catalog、App/UI 和组合擦除均由026验收。真实 Apple/Keychain/iCloud/CloudKit/Health/WC、本人账号/设备、签名安装及部署延后，production provider/trust/bootstrap 仍 Unavailable。没有 whole026/M4 完成、原生冻结或发布结论。
