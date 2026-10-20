# NATIVE-051 Debug material and Phone inbox

状态：已登记，独立树 API/发布规则计划 checkpoint，产品/测试尚未写入；待 root 确认具体规则后 TDD。见 [计划](../../superpowers/plans/2026-10-20-m4-debug-material-inbox.md) 与 [验证卡](../validation/NATIVE-051.md)。

base `2cab4640ee3a375da39fdabf0f5a317600b0c263` + accepted043 `cfeefe85b1489227664a3bc19b9c6c78367e581e`，effective `ddb659f37cfdaf3a154a59859b63649c46818ec2`。只合 held026（登记 `eb05eaf2c4521ccd0406a1d3e1bb599952ec9609`）；作者 m2，非作者 root/cloud，六路径如计划。

新增 DEBUG-only opaque signer/vault 材料入口和原 protocolClients typed Phone inbox。材料只验 M4 已保留的原 namespace/deviceID；全材料与全部业务/日志均无才首次发布，初空 vault 先落盘，部分/缺坏文件一律保全拒绝。原 Runtime/普通 make 行为保留。inbox 共用原 wire/mailbox，业务 stop cancel/join 保留 HTTP/Cloud-delete，finalclose 后才整体关闭；026负责每请求 fresh 双身份和原服务装配。

没有新 Runtime、Session、DB/协议、SDK/工程或真实账号调用。source/final 须 root/cloud 双审；实现/验证未完成，不自行 merge/push/archive。
