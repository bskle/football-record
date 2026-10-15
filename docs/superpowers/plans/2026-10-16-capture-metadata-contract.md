# NATIVE-004：采集片段元数据契约

> 执行者：/root/capture_contract；统筹：/root。独立规格审阅 /root/environment_check，质量审阅 /root。

目标：补齐 M1 的非健康采集片段值类型，为 M2 保留原比赛、原记录设备、多 Workout 关联和未知缺口。只定义 Foundation 契约，不接 HealthKit、MatchStore、UI 或网络。

## 契约决策

- `CaptureBinding` 固定 `matchID` 和 `recordingDeviceID`；标识不可为空或纯空白。
- `CaptureWindow` 保存可空的实际观测起止时刻；nil 代表未知。已知时间必须有限；两端都已知时不得颠倒。不提供把未知变为零的派生时长。
- `CaptureSegment` 由调用方提供稳定片段 ID、原绑定、真实 Workout 的非健康关联 ID 和观测窗口；不生成默认 ID。
- `CaptureGap` 显式保留缺失窗口和原绑定，不补数据。`CaptureMetadata` 验证所有片段/缺口与容器绑定相同、片段/缺口 ID 不重复；不拼接窗口，不要求缺失数据具有完整边界。
- 所有类型 Codable / Sendable / Equatable、不可变。自定义解码复用构造验证；损坏输入不能绕过不变量。
- M2 在恢复成功后继续关联原 Workout；失败后可在原绑定下追加另一 Workout 片段和中间缺口。比赛计时仍由事件引擎决定。本任务不声称完成恢复、采集或持久化。

## 实施与验收

1. 提交本计划及任务卡，锁定所有权和实际 base。
2. 先写高价值 XCTest：多 Workout + gap 保持身份、跨比赛/设备拒绝、未知边界往返保留、非法标识/时间/损坏 JSON 解码拒绝。运行红灯并保存日志；再实现最少契约，运行绿灯。
3. 使用独立 `/tmp` 构建目录执行现有 verify 脚本；确认 Core 原有 33 项 + 新测试及无签名 iOS/Watch 构建通过。持久保存日志与 SHA256 / 构建输入，不宣称实际设备验收。
4. 先交源码 SHA 双审，再提交实际验证文档。仅明确路径暂存；Conventional Commits 分开计划、功能和证据。主代理负责最终双审、合并、归档和分支删除。

## 路径与边界

只允许修改：`native/Packages/MatchCore/Sources/MatchCore/CaptureMetadata.swift`、`native/Packages/MatchCore/Tests/MatchCoreTests/CaptureMetadataTests.swift`、本计划、`docs/native/tasks/NATIVE-004.md`、`docs/native/validation/NATIVE-004.md`。

没有设备依赖；不修改现有事件引擎、Package.swift、MatchStore、脚本、Xcode 工程、原型、产品或治理。源码控制在 200–250 行内；不扩展成采集框架。
