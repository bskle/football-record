# NATIVE-022 独立持久云台账

状态：无需用户协助的软件实现与自动验证完成，候选待两位非作者 exact HEAD 双审；尚未合入 dev。

| 字段 | 登记 |
|---|---|
| 作者 | /root/m4_cloud，唯一写入作者 |
| 主代理 | /root |
| base_ref / base_sha | dev / `5e876cfd875585b315b57f91bcb8dc7160f8afa6` |
| 登记合并目标 | dev / `5e876cfd875585b315b57f91bcb8dc7160f8afa6` |
| 当前目标 / 同步输入 | dev / `a15b8414c460026e5ea7725f9c17ea08ce9ed737` |
| 普通同步 merge | `d135d48a02b5b90f9469ce6d076890ff449a9b49`；原始 base 不改写 |
| 分支 | `feat/m4-cloud-ledger` |
| attachment | `01a14f8f-ff04-7203-97ef-8121e71ad4cb`，createdAt 1792336199 |
| 绝对路径 | `/Users/liam/.codex/worktrees/m4-cloud-ledger/20260830_足球记录` |
| 初始实际 HEAD / 状态 | `5e876cfd875585b315b57f91bcb8dc7160f8afa6` / clean，分支已核 |
| 唯一所有权 | `native/Modules/CloudSync/**`、本任务卡、`docs/native/validation/NATIVE-022.md` |
| 禁止写入 | MatchCore、App、工程配置、verify.sh、AGENTS、冻结合同、其他任务树 |
| 前置 | 020 exact 双审后 no-ff 合入上述 base，主代理已核验证和同步 |
| 审阅 | 待两位非作者 exact source/final 双审 |

执行依据为 [M4 计划第 6 节](../../superpowers/plans/2026-10-18-native-m4.md) 与 [冻结合同](../contracts/m4-account-lock-cloud.md)。按 022.1/2/3 分别先失败测试、实现、绿验证与 Conventional Commit；不推进长期分支、不 push/merge/archive。

证据：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-022`。六项 Git 输入、工具版本、红绿日志及 SHA manifest 在该树外目录保存。

真实 CloudKit / CKAsset、生产 VerifiedCloudSave、现有 MatchStore 同 facade 接入以及真实账号/设备测试留 023/024/026；本任务的独立 SQLite fixture 不能当作业务库已经导入。生产默认 sink 保持 awaitingBusinessImport。真机对本任务隔离台账和协议单元验证不适用，不替代后续真实层。

## 软件交付与验证

- [x] 022.1 独立 SQLite 上传队列：稳定 ID、原 canonical bytes、deletion/tombstone、持久重试、同 ID 异 bytes 拒绝、commit 前回滚/后丢响应、文件重开；真实 peer route/ACK 后仍可产生独立云上传。
- [x] 022.2 原下载 batch 先 stage，业务 sink 是唯一 applied cursor 来源；真实文件 SQLite fixture 将 facts/tombstone/首次 receipt/token 同事务提交，先 receipt 重放再父 token 原 bytes + generation CAS；错误 ACK、不同 batch 乱序、过期 generation、双连接和默认 awaitingBusinessImport 均覆盖。
- [x] 022.3 typed 冲突/配额/partial/unknown/accountChanged、持久 backoff、tokenExpired generation reset、remote missing 不删本地、明确 tombstone 不复活；完整 conditional save / manifest / part 回读检查仅产生 DevelopmentCloudSaveEvidence。
- [x] 审查反馈已先红后修：近 8MiB payload 的 base64 envelope 重开、有限超 Int64 毫秒日期、v1 不兼容结构 failed-open 不改库、逻辑 record 条件保存/tag、坏 batch 不被下次唤醒跳过、账号切换 check→SQL 进度事务 TOCTOU。相同既有 receipt 可只读重放，新 stage/ACK/evidence 写入在事务内复查持久 fence。

正式审阅发现 `d37c597` 的可选 issue loader 将非 NULL 未知枚举误当 nil；该旧 SHA 不算最终 PASS。先补三个真实文件 SQL 红例，再统一严格区分 SQL NULL / 合法 CloudIssue / 非法值；未知 scope（原 accountChanged）、upload、batch issue 均以 invalidPayload 停止，不调用 driver 或业务 sink，原文件与原 bytes 保留。

修复后 `CloudSync` 单轮 **42 项 host**（16 Conflict + 3 IssueDecoding + 10 Ledger + 13 Service）通过；源码改变后已重新执行 iOS17 simulator / watchOS10 simulator 的 `CloudSync` target，各 1 项通过。历史同步节点 `a15b841` 只引入 021 backend/两卡，当时 97 项 native/脚本/模块文件同步前后 SHA256 相等；该旧 SDK 层次仍保留，但不替代本次修复后的两项重新编译。详见 [验证卡](../validation/NATIVE-022.md) 与 [模块交接说明](../../../native/Modules/CloudSync/README.md)。

三个实现提交：`46ba945`、`af9eda1`、`6a7b59fbaacdd2d47d5313ec1d08f8279ed39495`。最终可审 SHA、六项 Git 输入、文件 hash、红绿日志 SHA manifest、双审/合并状态由树外 registry 保存，避免为写入自身 SHA 再生成提交。作者冻结后停止写入，后续合并/同步/归档仅由主代理执行。
