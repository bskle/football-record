# NATIVE-042 — 会话与展示退役

状态：source 已 root + cloud 两位非作者 exact PASS；final 仅两卡收尾，作者 clean 停写后交同 HEAD 窄审。仅供026本地候选，不由作者合并、推送或归档，不代表026整包或真实设备验收。

- 原 base：`2cab4640ee3a375da39fdabf0f5a317600b0c263`；登记 held026 target：`1e522821309c47e77400a61883d44468d521c2f8`。后续实际接收 target 由 root 核验。
- 分支：`fix/m4-session-retirement`；树：`/Users/liam/.codex/worktrees/m4-session-retirement/20260830_足球记录`；attachment `01a15661-ee43-7053-94a3-f585b6a66575`，createdAt1792450620。
- 作者：`/root/m2_review`；非作者审阅：root、cloud。source `fd4f0a94ca2b7a338e595fd7bbb32dfe4c1e196d`，产品/测试/[实施计划](../../superpowers/plans/2026-10-20-m4-session-retirement.md)在 final 保持原 bytes。
- 20 条实际变更路径均在登记所有权：MatchSession source/tests、两个 Presentation 模型、登记测试与本任务三文档。未改 Store、MatchSync、AccountKit、Package、工程、SDK、038工厂或通用协议要求。

已交付三个可组合边界：先同步 `RecordingModel.beginRetirement()` 永久停 UI 新业务入口，再 `try await originalSession.retireBusiness()` 排空原采集/业务工作，最后 `await model.shutdown()` 排空自有操作/观察/反馈任务并清除旧 snapshot/history/pending/metrics。原 repository 和 Lifecycle/Saga 继续可用，由组合所有者另行关闭；Model 不隐式关闭借用 Session。

Session 不取消已经派发的 gateway perform/reconcile，不制造 finish/notCreated，不在退役后新发 permit/SDK 工作。原观测写失败会阻断退役；后续只经 SQL 重试原事实。COMMIT 丢响应须 canonical 原请求读回，其他 settled、savedAwaitingLink 或 stopped 结果不能替代未提交的原 A。无法证明时保留 A 并抛错，不伪造完成。

本轮 source 实际完整相关验证：Core 包 **268/0**（44 Core +149 Store +58 Session +17 Sync）、Presentation **80/0**，两条宿主命令同一轮合计 **348/0**；4 项 fresh 最低模拟器 SDK（Session/Presentation 各 iOS17/watch10）、2 个无签名 generic simulator App 全部 exit0。每命令241个运行输入 before/post 零差异。原红、旧检查点与过时调用计数断言的失败完整保留，详见[验证卡](../validation/NATIVE-042.md)。

source 两审均 PASS_SOURCE_HELD_026_ONLY；source manifest SHA256 `94b4267f2263e72a37b66319693606efa6f5b432fcd1ec7641e7c7d4e28a3d3e`。最终两卡增量仍需同 HEAD 独立审阅，不预填已接收/已合并。

最低 SDK 与无签名 App 只证明编译，没有启动 Simulator、执行真实 SDK/采集回调、访问账号/HealthStore/WC 或使用本人设备。042 退役不是所有本地数据擦除，也不证明数据库写失败后的回调具备崩溃持久性；026仍承担原 owned catalog、保留控制、全部叶节点 current-zero 及真实环境组合门槛。M4未完成、未发布。
