# NATIVE-058 验证

状态：计划阶段，仅静态核准；无运行时验证结果。original base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，分支 `test/m4-native-http-fixture`。本轮只有 [实施计划](../../superpowers/plans/2026-10-22-m4-http-fixture.md)、[任务卡](../tasks/NATIVE-058.md)、本卡三文档。

## 精确输入及静态方法

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-058`。

| 证据 | SHA256 | 内容 |
|---|---|---|
| `planning-inputs.json` | `562d7da0ffdd9b3877274ee9ef756728bb871a51025bb2831cfeb8ec2310b254` | 固定2cab的21份Git blob/mode/bytes/hash与immutable copy；4份acfd参考报告副本 |
| `planning-initial-git.json` | `905ac1ddf52a34dc93514bad72ce1a1c69c6e4e4bbce516b7c5ecefbdfe31987` | 原生attachment、HEAD/base/分支、clean含ignored、登记/观察target和零runtime调用 |
| `reference-acfd-backend-delta.patch` | `294801a008474ebb4faa7caf7e4a326005f7672e8e6c85a95550c73978bf1506` | 固定Git对象2cab→acfd四个backend文件差异；非当前026目录/WIP |

只读检索用rg、Git blob/show/diff/ls-tree与静态文本读取；Python仅做文件复制、SHA256和静态JSON/链接/范围检查，不导入项目或调用Node/HTTP/SQL。最初尝试读取NATIVE-057旧卡不存在，已用本base实际文件清单修正为NATIVE-038格式参考；这不表示057接口可在本base使用。后续不以移动ref或历史卡替代实际源码。

21份当前输入包括AGENTS、Git治理、合同、原生/M4母计划，device-auth/apple-verifier/authority/config/database/http/codec/receipt，support/auth/device-auth-boundary/apple-revocation-support，旧原生authority-fixture、backend package以及038两卡。所有输入均带固定2cab来源；副本hash须逐项重核。未复制026当前工作目录、未读Watch四路径WIP。

参考层来源固定 `acfd8ae569417e20be4b0b346845f03d0317ab77`，与本次2cab执行输入分开：

| 研究参考 | SHA256 |
|---|---|
| `report.json` | `56a2575919206109062fa85506bb85c409e6a6601623897d23d8f3589fa1fe08` |
| `account-observation-addon.json` | `76b50c260e4d3510f63c82155fe77da3cb6c92b0b8b8ffae42c7a12a4097fb4e` |
| `identity-observer-decision.json` | `a4db4963bb7f622a532cd8033ecb37acef5da6250f278e2169baf2e2aded9cca` |
| `identity-observer-checkpoint.json` | `0cdb201385ffb88fbdfd3aabf36b9423d0273aecd36a2e59533feb164c1c1488` |

研究稿的6新+8复用14份输入仍属于acfd历史研究，不称本次21份当前输入或运行证据。当前base原映射在device-auth:44；纯提取计划保留原事务位置和legacy development兼容（device-auth-boundary:41–45）。2cab→acfd身份映射无变，主要为052删除控制；以后target普通merge须重新冻结并复验。

## 本轮实际静态检查与未运行项

文档提交前后执行且完整结果写树外 `planning-static-check.json`、`planning-final-git.json`、`planning-final-manifest.json`、`planning-checkpoint.json`：三文档路径范围、Markdown本地链接、无未授权实现文件、无冲突标记/空步骤/占位符、输入副本Git blob/mode/size/hash一致、whole-tree diff、`git diff --check`、实际HEAD/分支/clean（含ignored）。actual final SHA只在树外记录，不回写自引用。

| 操作层 | 本轮实际次数 / 结果 |
|---|---|
| Node执行、启动HTTP、SQL连接/查询 | 均0；无此层PASS |
| 自动测试、构建、SDK、设备/模拟器探测 | 均0；无计数/性能/TTL运行结论 |
| 产品/helper/test写入 | 0；只提交三文档 |
| 026工作目录/Watch WIP读取 | 0 |
| merge/push/archive/delete/rebase | 0 |

真机与SDK对本次纯计划文档不适用。未运行Node测试不以旧161或其他task旧计数补足；原first-device auth与观察零写均是拟验证门槛，尚未实证。

## 实现后必须取得的证据

- [ ] mapper原式逐bytes等价；同issuer/subject/key稳定，不同身份/key隔离，Unicode/空白不归一；原production、legacy-development、challenge/fence/recover/PoP回归全绿。
- [ ] 空authority除schema/metadata/epoch allocator外无业务/控制row；启动不登录、不生成或输出设备credential/privateKey，默认时钟实际Unix秒且自然推进。
- [ ] genuine verifier/identity品牌、独立nonce、audience/issuer/signature/alg/kid/kty/use、exp/iat、观察60秒/重放/容量/await时generation或authority变化均拒错；每一成功/失败观察前后所有表完整内容相等，非仅count。
- [ ] 观察不发grant、不说明accountExists/registered、不调用auth/recover/login、不写binding；原HTTP随机第一设备仍registered/active，accountID等于独立观察，epoch由原事务分配；第二Phone保持waitingMigration。
- [ ] requestID stdio严格、唯一响应、有限错误与无密metadata；显式apple token/code只在调用者内存，观察/诊断/DB/trace无秘密；fault不改SQL语义，restart原DB/keys/clock/namespace不变，close完整等待。
- [ ] 固定source新suite及原backend单次完整回归（在backend目录npm test），记录实际输入hash/计数/限制；不将focused与历史计数累加。
- [ ] root与第二位非作者whole source/final双审；026停写干净、冻结target后root no-ff合入，按实际052等已审API重跑目标backend与新suite，记录actual merge SHA/whole tree。

原051/M4 native chain由026使用原facade/Session/installation/key、独立Apple/cloud观察及既有current identity文件校验验收；058计划/host fixture不代替该链。真实Apple账号/授权码、CloudKit/Keychain/WC/签名设备/生产服务均未验；production仍Unavailable，无M4完成、release冻结或原生发布结论。

## 停写检查点与生命周期

当前checkpoint为：三文档Conventional docs提交、clean停写，等待root与第二位非作者审计划，且root明确准入精确三实现路径后才运行/写实现。现有子代理执行选择已授权，不重复问用户。所有者不推进长期分支、不push/merge/archive/delete/rebase；本树作为026活跃依赖保留。最终必需目标接收、无依赖且必要ignored证据另存后，由root先原生archive核实际成功，再安全branch -d；queued/拒绝时保留。
