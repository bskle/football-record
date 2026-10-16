# NATIVE-009 原生记录 UI 执行计划

负责人 `/root/m2_recording_ui`，任务树 `native-recording-ui`，临时分支 `feat/native-recording-ui`，base/集成目标 dev = `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`。主代理与 `/root/m2_review` 为两名非作者审阅者。用户已经批准原型与 M2，沿用森林绿/暖纸色、系统字体、等宽数字及 Watch 双页，不再次设计。

唯一所有权：Apps/iOS、Apps/Watch、Modules/MatchPresentation、FootballRecord.xcodeproj、Configuration、UITests、scripts/native、native/README 与本计划/任务卡/验证记录。并行 008 只写 WorkoutCapture，本任务不依赖其未审文件。真实设备能力不在此任务。

- [ ] 写展示回归：事实派生双时钟、缺失健康值、结束待同步、最近四事件。
- [ ] 写控制器回归：COMMIT 后更新和触觉、失败保留原快照及完整请求、明确 stale 且查无命令才重建、取消首发选择无 match、只读恢复错误。
- [ ] 实现实际共享 MatchPresentation 包，直接调用已冻结 MatchSession，健康值独立可选内存通道。
- [ ] 唯一工程作者装配 iPhone 四标签、Watch 两页四快记、首发/替补、持续撤销与控制/结束确认。正式许可 unavailable，Debug 演练用真实独立数据库及持续“开发模拟锁”。
- [ ] 显式注册所有源/产品；新增两端 XCUI target 与共享 scheme Testables；保持 iOS17/watch10、无 HealthKit entitlement。
- [ ] 保留 Core/Store/Session 131 测试、4 SDK 与双 App 验证，加入 Presentation 宿主测试及双 SDK。
- [ ] 实际模拟器 XCTest 启动/点击/滑页/截图，验证按钮 >=44pt、四快记、guard/undo、首发取消、暂停/bench、失败、结束取消与待同步。检查 iPhone 深浅色/窄屏/大字体和 Watch 缺失状态。
- [ ] 保存输入 hash、设备/runtime/命令、日志、xcresult 附件与截图至工作树外，记录实际事实与最低系统/真机未验。
- [ ] 独立源提交、双审修复与验证记录提交后交主代理合并；作者不得推进长期分支或清理工作树。

提交组：`docs: plan native recording interface`、`feat: present committed match sessions`、`feat: add native match recording screens`、`test: exercise native recording on simulators`、`docs: record native interface validation`。以实际逻辑边界拆分。
