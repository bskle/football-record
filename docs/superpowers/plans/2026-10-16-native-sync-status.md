# NATIVE-017 同步状态与工程装配

执行依据为已批准的[M3子计划 §8](2026-10-16-native-m3.md)，协议以[持久同步合同](../../native/contracts/m3-durable-sync.md)为准。唯一作者 `/root/m3_ui`；base/target dev `a5d70759b1ff7c67b92f2082244fd189c119418d`；临时分支 `feat/native-sync-status`。受管树 attachment `01a143d6-081f-73b2-90e3-b3b70c3d1380`、创建 HEAD/clean 和范围详见[任务卡](../../native/tasks/NATIVE-017.md)。

- [x] 状态投影先红测；严格要求真实 ACK、无未路由/待确认/缺口；typed unavailable 清除旧成功结论并使计数未知。
- [x] 同一 SQLiteSessionRepository facade 装配具体 Session/MatchSync；公开 AppComposition 供018注入适配器，生产许可/信任保持 unavailable。
- [x] 双端工程注册实际 MatchSync product；保留 Phone/Watch 既有布局、四快捷键和记录反馈边界。
- [x] Debug 两隔离 SQLite、两个持久身份及真实落盘 ACK，验证重开身份稳定；身份丢失且已有记录时 fail-closed。UI 同步重试不推进比赛时钟。
- [x] 记录恢复与同步 start 解耦；切场/替换取消旧订阅，停启代次与观察代次守卫阻止迟到结果。已识别的忽略取消晚激活在旧 shutdown join 前补 stop，新生命周期不被旧清理误停。
- [x] 完成本机自动/模拟器验证并保存本轮截图、可达性树、xcresult、SDK/命令日志及源输入 hash；分层范围见[验证记录](../../native/validation/NATIVE-017.md)。
- [x] 源 `1790722ac99c9346f6279715161349103cde69af` 经 root / m2_review 两位非作者审阅 PASS；仅自己的三篇文档与证据收尾后停写。
- [ ] root/m2 对最终文档 head 审阅，root普通合并并对实际 merge 全量/定点 UI 复验、推送、按治理安全归档。

无本人设备、账号或环境前置事项。无新增设备能力，真机不适用本任务的模块/API范围；真实通信、签名安装、最低 iOS17/watchOS10 运行、真人 VoiceOver 与触觉仍由后续设备验收完成。生产 M4 Apple 登录、可信peer、开赛锁及 CloudKit 不在本任务实现；ACK 不释放后台锁、不制造 completed。
