# NATIVE-051 Debug material and Phone inbox

状态：source `183601ac74af3ab7565932eb4a952a41ea7d5097` 已 root/cloud 两位非作者精确审阅 PASS；本提交只收尾任务卡与验证卡，最终文档审阅待完成。见 [计划](../../superpowers/plans/2026-10-20-m4-debug-material-inbox.md)、[验证卡](../validation/NATIVE-051.md) 与 [M4合同](../contracts/m4-account-lock-cloud.md)。

base `2cab4640ee3a375da39fdabf0f5a317600b0c263` + accepted043 `cfeefe85b1489227664a3bc19b9c6c78367e581e`，effective `ddb659f37cfdaf3a154a59859b63649c46818ec2`。只合 held026（登记 `eb05eaf2c4521ccd0406a1d3e1bb599952ec9609`）；作者 m2，非作者 root/cloud，严格六路径。

已交付 DEBUG-only opaque signer/vault 材料入口及原 protocolClients 的 typed Phone inbox。原 M4 device.identity/namespace 先于材料和业务 DB；三材料与 DB/精确 sidecars 全无才首发，初空 vault 先持久化，缺坏或部分文件保全拒绝。同进程 gate 绑定原 namespace 实际 dev/inode，held vault 每次 fresh 读取和 generation CAS；不重建原身份或 cached empty state。原 Runtime make/privateWrite 与 migration dispatch 保留。

inbox 共用原 wire/mailbox，永久业务 stop cancel/join，不关闭原 HTTP/Cloud-delete；finalclose 再整体 join。handler success/error 返回均重查原 request/目录身份与 stop/lifetime，替换输入保留 undrained。026注入每请求 fresh 双身份及原服务 wrapper，不能用静态 subject/保留 credential 当当前身份。

最终同源单轮 Presentation **105/0**（原88 + 新 material10/inbox7），四 fresh 最低 iOS17/watch10 Debug/Release simulator 产品通过；普通 Swift6 消费者 Debug两项通过，Release两项因缺 DEBUG 类型预期失败。241 runtime 输入在9个命令 before/post/Git逐字相同；7Git、107 source evidence、84实际 module artifacts 已绑定树外 manifest。focused/历史失败不叠加到105。

原 Node loopback + 两原 SQLite facade/Session 经现有 mailbox 实测 registerWatch COMMIT丢响应、Watch原ID/canonical重开 recover、Phone凭据不被Watch覆盖；这是本机受控软件证明。无新 Runtime、Session、DB/协议、Package/工程或 SDK 调用。

候选继续 held026；无 dev/release/main 合入、推送、归档或发布声明。真实 Apple/Keychain/CloudKit/WC/Health、独立SDK身份、账号/设备/签名/掉电/部署、App/UI及 whole026 仍未验证，production默认Unavailable。source双审不替代最终两卡审阅及026组合验收。
