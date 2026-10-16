# NATIVE-012 恢复只读状态修复计划

> **For agentic workers:** 已由主代理派给 `/root/m2_recovery_state` 在独立工作树逐项执行；以 TDD 和完成前验证落实此窄修。

**Goal:** 同一 RecordingModel 在读取或恢复瞬时失败后，经完整成功重新验证可解除陈旧只读状态并恢复操作。

**Architecture:** 保留 `refreshHistory → recover → selection` 的验证顺序，只在成功分支完成后重置恢复错误与只读状态。失败、错误设备、多候选、身份和阻塞诊断继续关闭写入；任何异步等待前都不提前解锁。保留未确定 `pendingRequest` 的完整值，未许可意图保留专属提示，结束场次继续保持 held / endedPendingSync。

**Tech Stack:** Swift 6、MatchPresentation、真实临时 SQLiteSessionRepository、可控单次读取与恢复故障、XCTest。

- 原始 base / 合并目标 `dev` = `7ae65db8f662c4afcdd053f63da6462bbed57262`；临时分支 `fix/recovery-read-only-state`。
- 受管树 `/Users/liam/.codex/worktrees/recovery-read-only-state/20260830_足球记录`，attachment `01a142f0-f5a5-72f0-bd7a-cdfd8937cadc`，createdAt `1792124450`；开始时实际 HEAD 与 base 相同且 clean。
- 作者 `/root/m2_recovery_state`；非作者审阅主代理 `/root` 与主代理安排的规格审阅者；仅主代理可合并、同步、归档和清理。
- 唯一可写：`native/Modules/MatchPresentation/**` 中的恢复逻辑与必要回归、本计划、`docs/native/tasks/NATIVE-012.md`、`docs/native/validation/NATIVE-012.md`。不改公开 API、Core、WorkoutCapture、Apps、工程或脚本；其他作者在自己的树工作，不覆盖其成果。

## 执行

- [x] 先提交本计划和任务卡；精确路径暂存。
- [x] 在 `RecordingModelTests.swift` 或独立恢复测试文件用真实 SQLite + 受控 wrapper 复现：读取/恢复一次失败，同实例下次成功恢复原场或空库仍无法操作；先实跑并保存预期红测。
- [x] 补充守卫：恢复期间仍 busy / readOnly，wrong-device / 多候选 / identity / blocked 失败持续只读；未确定原请求在恢复后原值重试；未许可意图提示保留；held 终态不新开、不释放锁、不增加反馈。
- [x] 在 `RecordingModel.load()` 成功验证结束处做最小状态修复，不在任何 await 前解锁，不清除或重建已有未确定请求。
- [x] 实跑 MatchPresentation 全部宿主测试并独立提交源码；及时通知主代理 source SHA，供双审及 010 普通同步。
- [x] 实跑 `NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE012 scripts/native/verify.sh`：全部宿主、Store / Session / Presentation 的 iOS17 + watch10 六项 SDK、两 App 无签名构建。
- [x] 树外保存红绿日志、输入 SHA256、工具链、完整验证日志；最终文档单独提交，核对 clean 后停止写入交主代理。

## 验收与限制

新测试必须首先因陈旧 `readOnly` / `issue` 失败，再在窄修后通过。允许成功空库重新开赛，允许拥有的原场重新记录；仅快照读取成功不足以绕过仍失败的 recover。恢复不确认未确定命令、不制造 receipt / feedback、不释放后台锁。纯展示控制逻辑不涉及新设备能力，真机不适用；真实 HealthKit、GPS、后台和签名仍属于 008 / 010 门槛。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-012/`。提交顺序：`docs: plan recovery read-only state repair`、`fix: restore recording access after successful recovery`、`docs: record recovery read-only state validation`。

## 实际执行结果

计划提交 `4f313246dc042f241fd2cabae50fbef513027a09`，首版源码 `8d38fcb2d137c4e3a763e4a53a725b1b150df099`。主审发现原请求仍待确认时清空 issue 会隐藏现有 retry-save 按钮；加真实红测后以 `e35b05ac1f7db3ea4203a4cbbcace71da716fcb4` 仅补有效待确认提示，保留原请求和未许可专用提示。最终源码由 `/root` 和 `/root/m2_review` 两非作者精确审阅 PASS。

最终完整脚本 exit0：166 宿主（44 Core + 64 Store + 36 Session + 22 Presentation）、六 SDK、两 App。75 个原生与验证文件前后 SHA256 无变化；两轮红绿与完整日志见 [验证记录](../../native/validation/NATIVE-012.md)。最终文档待独立审阅，主代理集成/同步/归档仍待执行；作者不推进长期分支。
