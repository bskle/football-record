# NATIVE-040：Watch 登记类型化中继

状态：本机软件 source 已 root + cloud 双审通过；final 两卡待同 HEAD 审阅。仅 held026，不晋级 dev/release/main，不代表真实 WC 或账号验收。

作者 `/root/m2_review`，非作者审阅 root + cloud。原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，普通合入稳定026-1 `40417c61058d7653737ceb23b821f11ba75e53c8` 后初始 `7007d7b68167659da6a44e759126a39cd6af0b58`。树 `/Users/liam/.codex/worktrees/m4-watch-registration-relay/20260830_足球记录`，branch `feat/m4-watch-registration-relay`，attachment `01a1563d-003f-7251-97cd-2a18776a3513`，createdAt1792448200。登记目标仅 held026 `fb6eb0e4f85da87bef3b42f144ec126eef9bbd55`，不消费后续 catalog WIP。

[具体计划](../../superpowers/plans/2026-10-20-m4-watch-registration-relay.md) 与 source/test/两卡共五路径；不改 Package、工程、Core、AccountKit 或 SDK。计划提交 `663bba0649dd7131f6e7110aeebda417be41dd1a` 的完整 Git 对象保留在树外 source-git-proof；执行 source `ea3d57e2bf84f1d2848b2fb632f0a2d98e66c9a4`。final 只补本卡与验证卡，不回写自身 SHA。

已交付 `M4WatchRegistrationRequest/Response`、`M4WatchRegistrationChannel`、默认 unavailable adapter、`M4WatchRegistrationRelay` 和 `M4PhoneWatchRegistrationEndpoint`。Watch relay实现既有 `WatchRegistrationAuthorizing`；Phone endpoint注入原 facade 的已 admission `PhoneWatchRegistrationService`，不建立第二Store或替代签名/身份权限。请求保留原 attempt/canonical body、requestID/digest及显式 submit/recover；响应校验 correlation、原绑定和65536字节界限。凭据响应只在内存传递，不打印、持久化或安装到Phone vault。

实例关闭单向封闭并合并同次close，取消/join本实例owned Task；取消与迟到结果不会发布给旧调用。只关闭登记专用通道，不关闭借用的 Session、facade、vault或全局business transport。026装配仍须先join登记桥，再关闭原资源；channel的cancel/close须结算本实例未决exchange。

完整 AppIntegration 同 source 单轮 **42/0**（原28+新14）及 arm64 iOS17/watch10 sim/device 四项最低SDK编译均通过；329 conservative native/backend/scripts 输入前后逐Git/hash零差异。红绿、实际Node HTTP+两SQLite、诊断和限制见[验证卡](../validation/NATIVE-040.md)。

026只负责本地controlled typed通道装配；真实WC控制RPC适配、配对设备行为、本人账号、Keychain和签名配置均后验。默认unavailable，不因本组件编译成功启用生产。作者不merge/push/archive，M4未完成。
