# NATIVE-025 账号与生命周期 UI 实施计划

依据已批准 M4 §9、原型与 57-input 接口准备；无新增产品决定。唯一作者 /root/m3_ui，唯一工作树 m4-account-ui，base `17f2e39adcdbc633682992d5e5e2f348dbc940e6`，已审 023 `f7f7a3bceb3000fd6d655d4724089601870eeb4d` 普通依赖 merge `ba01e83c861f2daa7d0733258097da13390243c6`。root 后续通知同步实际验证 dev。

1. **状态与同 facade 装配**：先红测 AccountStatus / LifecycleStatus 的 unavailable、身份/role gate、未知清旧成功、持久重开、默认统计关及删除本地双分项聚合。新增两个投影模型，扩展原组合根，仅一个 SQLiteSessionRepository / MatchSession；保留旧 bootstrap/recovery/sync 回归。
2. **受控开发纵向**：Debug 独立 namespace、稳定 identity/key、私有控制文件和有界 typed mailbox；Mac ui-test.sh 监督原 Node executable，App 无 Process。实际原 auth / Watch submit-recover / HTTP acquire、文件 owned cloud 保存回读、原正常释放双 proof、原 ID 丢响应恢复。生产 unavailable，Release 忽略所有开发输入。
3. **Phone / Watch UI**：保留原 SwiftUI 四 tab / 四快捷入口；账号 gate、waitingMigration、持久云/后台状态，Phone 正常/丢失迁移及七天警示、异常确认、删除四组独立结果、统计默认关；Watch 紧凑账号/登记状态。Health 真实能力 unavailable，开发范围始终标明。
4. **唯一工程与验证**：登记源码到两个 target；AccountKit / CloudSync 真实依赖；不写 reserved entitlements、不编造真实配置。宿主 focused 红绿后完整 Presentation，最低17/10编译、两端 Debug / Release unsigned App，双端 UI 与375pt深色最大字体实际按钮可达。保存逐命令 exit/log/xcresult/PNG/AX/输入哈希。
5. 分 slice Conventional 提交；冻结 source manifest 后 root + m2 两位非作者源码 / 最终双审。root 负责 no-ff merge、实际复验、同步、归档/安全删支，作者不推进长期分支。

不得改 Core/AccountKit/CloudSync/HealthKitDeletion/backend/verify.sh，SDK024并行仅接受已审接口，不读取 WIP。所有网络/任务/观察者换环境时先取消并 join 再停旧 context，不复用 stopped model。SDK、账号、签名、容器、设备、真人 VO/触觉验收保持026门槛。
