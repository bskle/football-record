# NATIVE-029 云事件零起始序号兼容修复

状态：窄修复与自动验证完成，候选待双审；仅 CloudSync 接受原 Session / LiveMatchRecorder 的合法首事件，不改变共享业务核心或 wire/hash。

| 字段 | 登记 |
|---|---|
| 唯一作者 | /root/m4_cloud |
| 主代理 / 双审 | /root；待 root + m2 exact SHA 双审 |
| base_ref / base_sha | dev / `03dbd35bd467a4a7334e2d1acf561af575935a86` |
| 合并目标 | dev / `03dbd35bd467a4a7334e2d1acf561af575935a86` |
| 临时分支 | `fix/m4-cloud-event-sequence` |
| worktree | `/Users/liam/.codex/worktrees/m4-cloud-event-sequence/20260830_足球记录` |
| attachment / createdAt | `01a14ff0-e98b-7801-9fa4-9a2a5b4b2b28` / 1792342550 |
| 初始实际 HEAD / 状态 | `03dbd35bd467a4a7334e2d1acf561af575935a86` / clean，分支已核 |
| 唯一写入范围 | `native/Modules/CloudSync/**`、本任务卡、`docs/native/validation/NATIVE-029.md` |
| 禁止写入 | MatchCore、AccountKit、工程、脚本、其他文档或其他代理树 |
| 前置与阻塞关系 | 022 已合入；023 真实 bridge 暴露合法首事件被 CloudSync 拒绝，本任务修复后由主代理交付依赖 |

根因：原 Core `CommandFacts.nextSequence([])` 为 0，真实 `LiveMatchRecorder.start` 产生 sequence=0；CloudMatchFacts 误要求 sequence>0。按先红再绿，以真实 recorder facts 验证，仅将 CloudSync 合法序号界限放宽到非负，保留负数、重复/冲突与其他原校验。DTO、canonical 编码和 hash 域不变。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-029`，保留六项 Git 输入、红绿原输出、工具版本与输入/证据 SHA manifest。禁止作者推进长期分支或 merge/push/archive；新树独占，不复用已归档的 022 树。

实际产品差异仅 `CloudModels.swift` 一行 `event.sequence > 0` → `event.sequence >= 0`；未改 DTO、canonical 或 hash 域。新增五项测试使用真实 LiveMatchRecorder，覆盖首事件0、完整比赛0/1/2的真实云台账 enqueue/reopen 与原 bytes/digest、既有sequence1、负数和同 recorder 重复0拒绝。

先红：五项运行时测试中两项真实 recorder 合法 facts 被拒绝；最小修复后完整 CloudSync 单轮 **47/47**（原42 + 新5）通过，iOS17 simulator / watchOS10 simulator 的 CloudSync target 各 1 项编译通过。详见 [验证卡](../validation/NATIVE-029.md)。真机不适用：本次仅纯事件值校验兼容，不启用生产 App 或改变 SDK 调用；真实 CloudKit、生产 proof 与023桥的后续整合验收不在本任务宣称范围。

最终可审 source/final SHA 与两审/合并结果保存在树外 manifest / 主代理 registry，避免写入自身 SHA 再产生提交。作者交付后 clean 停写，等待 root+m2 对同一 exact HEAD 双审。
