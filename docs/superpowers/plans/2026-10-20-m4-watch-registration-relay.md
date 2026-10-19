# NATIVE-040：原请求 Watch 登记中继

状态：已受派，开始 TDD；held 026，不代表真实 WC 或账号验收。

作者 `/root/m2_review`，非作者审阅 root + cloud。原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；普通合入稳定026-1 `40417c61058d7653737ceb23b821f11ba75e53c8` 后初始 HEAD `7007d7b68167659da6a44e759126a39cd6af0b58`。目标仅 NATIVE-026 当时 `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55`。本树 `feat/m4-watch-registration-relay`，attachment `01a1563d-003f-7251-97cd-2a18776a3513`。作者不 merge/push/archive。

只写五路径：本计划、[任务卡](../../native/tasks/NATIVE-040.md)、[验证卡](../../native/validation/NATIVE-040.md)、`native/Apps/iOS/Integration/Sources/AppIntegration/M4WatchRegistrationRelay.swift`、`native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4WatchRegistrationRelayTests.swift`。其他作者正在工作，不覆盖其修改；不改 Package、工程、Core、AccountKit 或 SDK。

## 实施顺序

1. 固定 typed context / authorize 请求及响应；携带 correlation UUID、原 attempt、显式 submit/recover，校验 canonical body、原 requestID/digest/action 和界限。通道默认 unavailable。Phone endpoint 注入已 admission 的 `PhoneWatchRegistrationService`；Phone fresh PoP 与签名证明继续由原 service 执行，中继不安装、记录或持久化 Watch 私密凭据。
2. 按失败测试实现 relay / endpoint 的 owned Task、generation 和关闭。关闭先拒绝新工作，取消并 join 本实例任务；只关闭登记专用通道，不关闭借用的 Session/facade/vault 或业务 transport。调用取消也请求通道结算原 correlation；迟到返回不能发布。026只负责本地 controlled typed 通道装配；真实 WC 控制 RPC 适配与配对设备行为仍后置，不因此授权额外 SDK 文件。通道必须让 cancel/close 结算本实例未决 exchange。
3. 真实 Node HTTP fixture + 独立 Phone/Watch SQLite 验证：exact 原 canonical request、submit/recover 原 ID、响应丢失重开、Phone vault 不被 Watch credential 覆盖、404/401/timeout 保持未知、可信 knownAbandoned 才封闭。测试 fixture 不能视为真实 Apple/WC。
4. 固定源输入，完整 AppIntegration host 与 arm64 iOS17/watch10 sim/device 四项最低 SDK 编译；保留 API 编译红、实际运行红绿与限制。源码 checkpoint 后交两位非作者审阅，再仅补两卡的最终事实。

## 不变边界

中继不新增身份 admission、第二 business Store、收据证明、业务 ACK、自动新 requestID 或真实 WC 调用。AccountKit 原完整签名验证及 identity generation 是权限门；网络错误不能变成 knownAbandoned。重开从原持久 pending attempt 恢复。026 装配时须先关闭/join 中继，再关闭原 facade/credential owner。
