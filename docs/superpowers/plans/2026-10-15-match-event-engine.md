# NATIVE-002 共享比赛事件引擎实施子计划

**Goal:** 为后续仓储提供可编码、确定性、可追溯的纯 Swift 比赛事实与回放契约。
**Architecture:** MatchDescriptor 固定单场与记录设备、稳定 StartIntent 和调用方已验证开始许可；MatchEvent 使用追加式 revision / correctionOfEventID。MatchReplay 纯函数解析事实、诊断冲突并重算双轴区间、比分、出场与生涯；LiveMatchRecorder / PostMatchEditor 只产生待保存事实，不声称持久化成功。
**Tech Stack:** Swift 6、Foundation、XCTest；iOS 17 / watchOS 10 / macOS 14，无第三方依赖。

已获按母计划本地实施授权，本子计划执行已确定规则；不重复产品设计审批。作者 `/root/match_engine` 仅写本任务受管 worktree；其他协作者的文件不覆盖。

## 文件与步骤

- [x] `native/Packages/MatchCore/Sources/MatchCore/MatchModels.swift`：公共 Codable / Sendable 事实与许可边界；`ReplayResult.swift`：输出与诊断；`EventResolver.swift`：重传、冲突、修订链；`MatchReplay.swift`：区间与统计；`MatchCommands.swift`：单写入者与快捷记录/撤销；`PostMatchEditor.swift`：赛后编辑；`MatchTimeMapping.swift`：暂停歧义；`CompletionEvidence.swift`：完整保存证据边界。
- [x] 先在 `Tests/MatchCoreTests/` 写首发/替补、暂停/上下场/跨日、比分和事件完整性行为测试；运行 `swift test` 记录预期失败，再逐组实现并验证绿色。
- [x] 第二组先测追加更正/删除、结束改早/越界、异常终结/迟到包、许可/单写入者、四快记 1000ms / 撤销；再实现相应行为，保留红绿摘要。
- [x] 将 `scripts/native/verify.sh` 的 SwiftPM 步骤升级为 `swift test`，保留两个无签名 SDK 构建；同步 `native/README.md` 当前边界。
- [x] 执行完整 `scripts/native/verify.sh`、`git diff --check`，写 `docs/native/validation/NATIVE-002.md`。以明确路径暂存，Conventional Commit，交主代理双审 / 合并；作者不推进长期分支或推送。

## 行为裁决与仓储接口

sequence按sourceDeviceID作用域校验；同实际时间按根事实sequence、根sourceDeviceID和根eventID保证稳定业务顺序，修订自身sequence只作追加审计。同一来源/sequence的不同事实另诊断。修订必须引用前一版本且 revision + 1，分支、循环、同 ID 不同 payload 不静默择一。暂停中比分允许记录：matchElapsed 冻结，球员保留场上状态，按事件序列计算在场进失球；出场时长仅累加与运行区间交集。结束后事实保留并标越界但不统计；预览结果可供保存前确认。只有 completed 且实际出场才有胜率 / 体能资格；健康值未提供则 nil。后台锁释放不由本地结束推定。

NATIVE-003 接收原始 descriptor / events 并事务保存，再运行同一回放；StartIntent 必须先持久化。所有命令返回待保存事件，调用方只能在事务提交后反馈成功；outbox / ACK / SQLite 不在本任务范围。开发许可有明确 simulation 标记，不能作为真实网络锁证据。核心要求明确 occurredAt；仅比赛时间落在暂停边界时返回需明确真实时间。

## 实际验证与审阅回归

源码提交 e92c52f2ad13244e904201fc57ce22819c972957 已通过33个独立XCTest方法和双端无签名SDK构建，规格/质量两位非作者均绑定源码PASS。根事实同刻排序、endedPendingSync/当前版本完成凭据、生命周期不可删除或颠倒、跨来源序号、完全缺start异常终结/nil计时及终结后禁止start已补红绿回归。sequence按sourceDeviceID作用域，修订追加序号不移动根事实边界；后台锁独立。未知计时保持nil，迟到事实只恢复计算，不自动completed。具体证据见 ../../native/validation/NATIVE-002.md。上方勾选表示作者完成实施；最终文档复审、实际合并与清理由主代理登记，不宣称已合入dev或完成整个M1。
