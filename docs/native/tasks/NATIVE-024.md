# NATIVE-024：Apple 与 CloudKit SDK 候选

状态：本机软件实现与验证完成，作者 clean 停写待 root + m2 整项源码 / 最终双审。SDK 执行默认关闭；受控 host 与最低 SDK 编译后仍留独立候选待026真实验收，不合dev、不push、不archive。

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

## 冻结与交付

源码冻结 `06ce54634dbf96c6c29fcaa8339dad05079ddb93`。四片提交为 f5c3fab（单item vault）、ed7c2ab（Apple/identity）、cc7c56d（codec/staging）、53a7db6（SDK driver）；其后普通合入最新已验证 `fcf530ada01a7cbf87bbfde598f611d8a35705b2`，仅接收7份治理文档，产品依赖与已审023保持一致。53a7db6 的提交 body 含字面量\n\n，原历史保留，后续 body 使用文件与真实换行。

此 source 同输入完整 AccountKit72/0、CloudSync106/0；两产品各四项最低 iOS17/watch10 sim/device 编译均 exit0。不是App装配验证，不与023的591或各slice累计。207项产品/测试/依赖输入及23项SDK header/interface哈希保留在树外 final-06ce546；运行后207项无差异。实际命令、exit、原红绿与限制见[验证卡](../validation/NATIVE-024.md)。

025 只消费两模块 README 的显式配置清单：container/environment、scene presentation anchor、本机installationID/keychain service/account/accessGroup、稳定且保留的owner controlDirectory、业务DBURL、asset root/control pair、当前generation与双身份显式admission。不得由候选推导Team/container/Bundle或自动启用SDK。026保留真实授权、Keychain可用性、CloudKit account/asset/token/partial/quota/删除与设备门槛，组合全部owned catalog，保护live owner inode及其父目录。

作者不合dev、不push、不archive；后续实际审阅结论由两位非作者独立登记，当前不能把阶段局部PASS视为整项通过。
