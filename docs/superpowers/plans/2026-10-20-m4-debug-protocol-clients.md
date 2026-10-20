# NATIVE-043 Debug protocol clients

依据 [M4](2026-10-18-native-m4.md) 与 [Git 治理](../../git-workflow.md)。本任务为026已有原 Session 装配提供纯协议客户端，不创建另一业务上下文。

## 登记

作者 cloud；非作者 root、m2。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，登记 held026 target `12cb0cfabc0619ddb07784603f313623c26aa080`。分支 `feat/m4-debug-protocol-clients`；树 `/Users/liam/.codex/worktrees/m4-debug-protocol-clients/20260830_足球记录`；attachment `01a1572e-7a79-74a1-b62d-77ed2d80922f`，created1792464026。初始 HEAD / branch / clean 含 ignored 已自行核对。唯一五路径为原 DevelopmentAuthorityScenario.swift、新 DevelopmentAuthorityProtocolClientTests.swift、本计划及043两卡。

## API 与实现边界

- `DevelopmentAuthorityScenario.protocolClients(configuration:rootDirectory:)` 返回 public DEBUG actor `DevelopmentAuthorityProtocolClients`。其直接遵守 AppleSignInDriver、AuthorityHTTPRelay、CloudDriver、CloudAccountDeletionDriver、WatchRegistrationAuthorizing；公开有限 closed 错误与最终 `close()` 的 drained / undrained 当前状态。
- 验证原 canonical 非 production dataset / namespace / role、原 trust 公钥格式和 loopback HTTP 配置后，复用原私有 Apple / Cloud / Watch drivers、DevelopmentMailbox 与新建的原 URLSessionAuthorityRelay。不得调用 Scenario.make 或构建 Runtime / AccountAppContext / Session / SQLite / identity / signer / vault / permits / 实际 SDK。
- factory 复用邮箱前后只读检查原四目录，既有 pending / 未知内容 / 非预期类型保全并 typed 拒绝；不采用旧回复、不删外来文件、不另建持久邮箱协议。此检查为当前状态，不声称跨进程所有权或永久零。
- 所有协议调用走同一个内部 owned 泛型边界，登记原 Task。final close 先永久停入口、仅取消并 join 本实例任务、关闭自身创建的 relay/mailbox，返回前拒绝迟到结果。原借用上下文、别的客户端与共享目录内容不关闭或清除。close 仅为最终关闭，026业务 quiesce 必须继续保留该 relay 供原 Saga 恢复。
- close 排空后重新读取邮箱库存；有外来或未知内容返回 undrained。重复 close 仍查当前库存，不将历史 drained 缓存为当前零。有限状态不代表026全部 owned / fullseal / native 完成。
- 原 Scenario.make / fromPrivateFile / Runtime 保持原行为；Cloud 回执只沿用 controlled development fixture 语义，不能生成 production proof。全部新增 API 在 `#if DEBUG`，Release不可达。

## TDD 与验证

先缺 API 编译红，再最小实现后的真实运行红与修复。用实际文件邮箱消费者验证 Apple nonce、Watch 原 attempt/action/raw bytes、Cloud typed 原 canonical、零 DB/identity 副作用和原 namespace 文件保留。补两实例独立关闭、旧 pending/未知保全与重复 close current inventory；内部共享 owned helper 用不响应 cancellation 的门闩验证 join，无 public 测试接口。

完整 Presentation host 保留原025/038全部回归；最低 iOS17/watch10 Debug/Release 四模拟器 SDK 产品及外部 consumer Debug可达/Release缺类型负编译。没有 App/工程/Package改动或App新调用，App构建仅在实际影响出现时增加。原日志、输入前后 hash、source/final及两审结果保存在树外；只按实际结果记数。无真实账号、CloudKit、Health、WC、本人设备或部署，作者不 merge / push / archive。
