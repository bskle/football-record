# NATIVE-024：Apple 与 CloudKit SDK 候选

状态：唯一作者实现中。SDK 执行默认关闭；受控 host 与最低 SDK 编译后仍留独立候选待026真实验收，不合dev、不push、不archive。

- 作者 `/root/m4_sdk_preflight`，审阅 root + m2。
- base `17f2e39adcdbc633682992d5e5e2f348dbc940e6`；已审023候选 `f7f7a3bceb3000fd6d655d4724089601870eeb4d`；实际依赖merge `e0997c6b09791e423d224dd04cbf26da32f2a3c2`，开工clean。
- 分支 `feat/m4-apple-cloud-adapters`；树 `/Users/liam/.codex/worktrees/m4-apple-cloud-adapters/20260830_足球记录`；attachment `01a150ab-aca9-7a30-8a48-90a49f98300e`，创建 `1792354790`。
- 仅登记的12新adapter/test路径、两模块README、本卡及验证卡；不写Core/Package/工程/App/后台/脚本/028。现Watch submit/recover、strict knownAbandoned语义保持原样，WC归026。

## 切片

1. 单item设备Ed25519 key、generation与credential，跨实例同步gate/owner，已有DB缺key拒绝；实际受控文件故障与重开红绿。
2. Apple nonce/state/cancel/late与真实cloud identity SDK边界；显式admission，默认关闭。
3. owned staging同步callback内copy/hash、身份/取消/永久erase围栏、跨epoch原scope恢复。
4. private稳定zone、opaque token、conditional save与完整回读；最后两包全host与八最低SDK编译。

每slice提交实际证据，最终root+m2 exact source/final双审。真实AS、Keychain、CloudKit、账号、签名/设备行为留026，不提前声称已验。
