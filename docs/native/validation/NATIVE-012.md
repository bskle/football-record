# NATIVE-012 恢复只读状态验证

作者 `/root/m2_recovery_state`，原始 base / 目标 dev `7ae65db8f662c4afcdd053f63da6462bbed57262`，分支 `fix/recovery-read-only-state`。计划先提交于 `4f313246dc042f241fd2cabae50fbef513027a09`；最终冻结源码 `e35b05ac1f7db3ea4203a4cbbcace71da716fcb4`。主代理报告 `/root` 质量审阅与 `/root/m2_review` 规格审阅均对精确 e35 PASS；最终文档待审，尚未由作者合并或同步长期分支。

## 最终完整实跑

命令 `NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE012 scripts/native/verify.sh`，最终日志目录 `/tmp/football-record-NATIVE012/logs/20261016T042856Z/`，完整脚本 exit0；使用既有缓存重新执行全部命令及宿主测试。Xcode 27.0 (27A266a)、Apple Swift 6.4、macOS 27.0.1 arm64，Simulator SDK iOS27 / watchOS27；显式最低 triple 为 iOS17 / watchOS10。

| 验证 | e35 实际结果 |
|---|---|
| Core / Store / Session 宿主 | 144 XCTest 零失败：44 + 64 + 36；Swift 6 runner 按三个 xctest 分别汇总 |
| MatchPresentation 宿主 | 22 XCTest 零失败：原 14 + 新增 8 恢复回归 |
| 最低部署 SDK 产品 | Store / Session / Presentation 各 iOS17 + watch10，六项显式 Simulator SDK 构建通过 |
| 双 App | FootballRecord-iOS / FootballRecord-Watch 无签名 Simulator 构建通过 |
| 源输入核对 | 75 个跟踪的 native / scripts/native 文件（源码、测试 fixture、工程配置、验证脚本及 README）执行前后逐文件 SHA256 一致 |

最低系统仅编译，未实际运行 iOS17/watchOS10。此轮无界面布局变更，未新增 XCUI 矩阵；没有真实设备能力验收。纯展示恢复控制逻辑的真机验证不适用，HealthKit / GPS / 后台 / 锁屏 / 签名与真实采集恢复仍受 NATIVE-008 / 010 门槛约束。

## 红绿与行为证据

初始实现源码未改前，先加入 8 项真实临时 SQLite 回归，受控 wrapper 只注入单次读取 / recover 错误、恢复等待与已提交响应丢失；命令 `swift test --package-path native/Modules/MatchPresentation --scratch-path /tmp/football-record-NATIVE012/PresentationHost --filter RecordingRecoveryTests`。实际 8 tests，6 个 case 因陈旧 readOnly / issue 失败，共 19 个预期断言失败；持续失败守卫的 2 个 case 通过。日志 `red-recovery.log`，输入 `inputs-red.json`。最小修复后全 22 项绿，日志 `green-presentation.log`。

首版源码 `8d38fcb2d137c4e3a763e4a53a725b1b150df099` 先完成 166 宿主 / 六 SDK / 两 App 的独立完整通过，75 项输入无变化；该历史日志明确存于 `host-sdk-apps-8d38fcb/`，不充当最终 e35 证明。

主审追踪 `RecordingIssueView` 的实际条件发现：有 pendingRequest 时，issue 为空会隐藏现有 retry-save 按钮。只给同一原请求回归增加精确“尚未确认保存成功，已保留原操作，请重试。”断言，先对 8d 源码实跑 1 test / 1 failure（实际 nil），日志 `red-retry-issue.log`。随后仅在完整恢复成功、仍有原 pending 且无其他有效 issue 时补现有待确认提示，全 22 项绿，日志 `green-retry-issue-presentation.log`；最终 e35 再完整运行上述脚本通过。此回归检查 UI 入口所需的模型状态，未冒称新真实点击测试。

八项回归实际覆盖：

- 空库读取失败后同实例成功 load 可新开，错误提示清除。
- 拥有的原场 recover 失败后成功重新验证可快记，恢复本身不增加反馈。
- 真实 SQLite 两候选重复恢复持续只读且不任选场次；既有错误设备测试增为重复 load，仍展示唯一快照但只读。
- 历史快照成功不能绕过仍失败的身份 / 阻塞诊断 recover；这些错误交付受控注入，真实 Session 判定仍由既有核心回归承担。
- 明确挂起 recover 时 busy / readOnly 保持，await 完成前不能写入。
- 已提交但响应丢失的原请求，在失败与成功恢复间保留全部 sorted JSON 字节、ID、时间、generation 和 action；恢复后保持有效 issue 使 retry-save 条件成立，原 receipt 重试仅计分一次，反馈仅确认一次。
- 未许可开赛意图保留专用提示和原请求，重试仍不制造第二场或虚假 receipt。
- endedPendingSync 且未释放锁的原场在成功恢复后仍 terminal，不能新开 / 快记、不释放锁、不重复反馈。

## 持久证据

根目录 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-012/`。

最终 `inputs-source-final.json` 绑定完整 source/tree 和 75 项 SHA256，文件 SHA256 `4327862b79859ed8f7e1a4a18f3c41a4900198aac729510eabfbb0e7e90e8379`；`inputs-final-after.json` 记录全部匹配。`environment.json` 记录工具链。`host-sdk-apps-final/` 保存十项分阶段日志；`verify-entrypoint-final.log` 保存完整脚本输出。`evidence-index.json` 关联两轮红绿、两次 source 与最终验证；`evidence-sha256.json` 对树外证据逐文件校验。

实现只修改 RecordingModel 的恢复收尾与必要测试，未改公开 API、组件按钮、Core、WorkoutCapture、App、工程或脚本。原始未确定请求不清除 / 改写，无条件快照成功不解锁；成功状态仅在所有 await 和对应 selection 验证完成之后生效。作者无合并、push、archive 或长期分支操作；最终文档交主代理独立审阅。
