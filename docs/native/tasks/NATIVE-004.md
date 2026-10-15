# NATIVE-004：采集片段元数据契约

状态：计划登记，待 TDD 实施和双审。仅 M1 合同补缺，不代表 M2 采集或恢复完成。

| 字段 | 实际值 |
|---|---|
| 主代理 / 唯一写入者 | /root / /root/capture_contract |
| 两位非作者审阅者 | /root/environment_check（规格）、/root（质量），待最终源码 SHA 审阅 |
| 原始 base / 开写 HEAD | f2cf0786fa57f846001a8df67d1861803f4a090d，clean；共享事件引擎已审依赖满足 |
| 合并目标 / 创建时目标 SHA | dev / f2cf0786fa57f846001a8df67d1861803f4a090d |
| 临时分支 | feat/capture-metadata-contract |
| 受管 identityKey / 绝对路径 | /Users/liam/.codex/worktrees/capture-metadata-contract/20260830_足球记录 |
| attachment / 创建时间 | 01a14146-0a22-74b2-95ee-d681aeb0cda4 / 2026-10-15T20:34:31Z |
| 所有权 | CaptureMetadata.swift、CaptureMetadataTests.swift、本卡、子计划、验证记录；完整路径见子计划 |
| 不修改 | 其他 Core 文件、Package.swift、MatchStore、脚本、native/README、Xcode、UI、原型、产品、AGENTS / 治理 / 母计划 |
| 依赖与并行 | 基于已审核心；与 NATIVE-003 Store 无依赖及文件相交，不改其 worktree |
| 验证 | 待保存 Core 测试与双端无签名 SDK 构建实际证据；真机不适用 |
| 集成 / 清理 | 作者不推进长期分支或 push；主代理登记审阅与实际 merge，再安全归档并删除临时分支 |

[实施子计划](../../superpowers/plans/2026-10-16-capture-metadata-contract.md)。只定义非健康关联及观测窗口；实际 HealthKit / 恢复 / 元数据落盘接线留 M2，不使用随机 ID 伪造存在的 Workout，不制造缺口内的采样或比赛时长。
