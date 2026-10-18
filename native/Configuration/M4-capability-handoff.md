# M4 配置与装配交接（025 → 024 / 026）

025 只提供账号与生命周期 UI、同 facade 装配及本机 Debug 受控演练。生产账号、trust、云驱动、采集、健康删除仍 unavailable；本文件不授予真实服务资格。

- 026 提供本人 Team、已登记的 iOS / Watch Bundle ID、companion ID、CloudKit container、环境及适用的 App Group / Keychain access group。当前 `com.example.footballrecord` 两个 ID 保留原占位，不代表登记。
- 四个预留 entitlements 尚未写入或绑定。Sign in with Apple、iCloud / CloudKit、Keychain、HealthKit 及后台能力由实际 SDK 装配与设备验收决定，不以空 entitlement 冒充完成。
- 024 提供已审 SDK adapters 与真实身份变化 / Keychain fencing / CloudKit account availability 的调用方式；026 将它们注入同一个 SQLiteSessionRepository、具体 MatchSession 和公开 AccountKit 服务，不能另建可写连接或第二 Session。
- 本地删除必须登记全部 owned Cloud ledger catalog 与 staging，再合并 Store 与 transport 的真实分项结果。UI 聚合“本地数据”；任何遗漏或失败均不能显示全部完成。
- Health 删除只处理可证明由本 App 创建且用户独立确认的运动；真实 source / selection / 权限及028适配器验收由026完成。当前健康分项保留 unavailable 失败，可恢复原请求。
- 真实 Watch 注册必须保留 submit / recover 类型、原 request 与 challenge、knownAbandoned 关闭语义；WC transport 激活、配对失效及唯一观察者沿018约束，不从来包或连接状态推断账号身份。

Debug 仅使用 `M4-Debug-Info.plist` 的本地网络能力；Release 使用原 Info，无开发 provider / 控制文件入口。Mac `ui-test.sh` 启动仓库既有 fixture executable，通过每安装私有0600配置和 typed mailbox 交换短暂授权；App 不启动进程。该方案不能代表 Apple 登录、CloudKit、WatchConnectivity 或健康权限验收。
