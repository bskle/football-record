# NATIVE-058：M4 空 authority HTTP fixture 与独立身份观察

状态：本机软件 source 已经 root + 第二位非作者完整双审 PASS；本次仅两卡元数据收尾，等待 exact final 双审。唯一作者 `/root/m4_native_http_fixture`；不代替原 M4 / 051 或026组合验收。

- original base：`2cab4640ee3a375da39fdabf0f5a317600b0c263`；批准计划 `038e2c3510ae8f771e075d8bf9f03ee35fe8f90c`；固定实现 source `571bdc4d2890ed87d926747fbd7131705b97acc5`。actual final SHA只记树外 `final-checkpoint.json`，不回写自引用。
- branch：`test/m4-native-http-fixture`；tree：`/Users/liam/.codex/worktrees/m4-native-http-fixture/20260830_足球记录`；原生attachment `01a1620a-0182-7f02-a3f2-6bb32dd43d4f`。各阶段核branch/HEAD/clean含ignored，当前收尾后停写。
- merge target：held `test/m4-e2e-integration`，original登记目标 `acfd8ae569417e20be4b0b346845f03d0317ab77`。该值是历史登记，不代表当前target；root须在026作者停写且clean后重新冻结完整target SHA，普通 no-ff 接入并按实际052等已审差异复验。不读其工作目录/Watch WIP，不消费未审API。
- source所有权为 `backend/src/device-auth.mjs`、新 `scripts/native/m4-authority-fixture.mjs`、新 `backend/test/native-m4-fixture.test.mjs` 及三规划文档。final只获准修改本卡和 [验证卡](../validation/NATIVE-058.md)；[已批实施计划](../../superpowers/plans/2026-10-22-m4-http-fixture.md)和三实现文件字节不变，不扩路径。

依据 [M4合同](../contracts/m4-account-lock-cloud.md)、[M4母计划](../../superpowers/plans/2026-10-18-native-m4.md)与 [Git治理](../../git-workflow.md)推进。source双审只覆盖本任务host软件范围，final与目标merge验收各有独立门槛。

## 已交付接缝

`accountIDForAppleIdentity(accountHMACKey,identity)` 纯提取原HMAC表达式，authenticate仍在原事务、absence fence和checkChallenge之后调用。SHA256、issuer+单LF+subject原UTF8、lowercase hex以及原production/legacy development语义不变；除该纯提取与同位置调用替换外，生产文件与base可逐字节重构一致。

新sidecar直接使用createAuthority + authSetup + createHTTPServer，空file SQLite、loopback、实际自然推进Unix秒。启动不调用seed外层fixture/login/request/device，不预登录另一Phone，不导入或输出其他设备credential/privateKey，不手写accounts空行、不清activePhone/锁/epoch，不改生产HTTP endpoints、旧helper/support、Swift/UI/工程或配置。

独立观察使用内存256-bit一次性nonce、60秒生命周期、128 pending上限和genuine branded development verifier/verified identity；await前后核实际authority/config/key对象及digest/clock/fingerprint/generation/environment。用同一authority的server key和真实已验身份映射，全部SQL表的逻辑值/原bytes在成功与拒绝观察前后相同；只给currentIdentity，不给accountExists/registered/activationEpoch/start grant，不拿config.subject、客户端HMAC或binding替代观察。真实第一Phone仍经原HTTP challenge/authApple注册为active且ID与独立观察一致，第二Phone保持waitingMigration。

requestID JSONL控制面有精确字段/operation、16384字节行、4096唯一ID及有限错误；启动和观察只给公开metadata。显式apple短期development JWT/code只交调用者内存，原HTTP认证只给原设备自己的凭据。故障复用既有SQL/HTTP fault；同进程restart保留原DB/keys/clock/namespace，close/restart等待原HTTP handler、observer、revoker异步尾部，包含响应socket已断开的情况。真实Apple账号/授权码、CloudKit观察或新的CloudDriver、跨进程secret持久化均未交付。

## 固定source验证与审阅

实际 Node **v22.23.1**。最终冻结新suite单轮 **46项/0失败**；完整backend单轮 **207项/0失败**，其中已包含新46，不相加，也不累加focused或旧161。实际完整命令在仓库根为 `node --test backend/test/*.test.mjs`；计划原写backend目录npm test，但旧HTTP/ops测试按仓库根相对路径启动子进程，该cwd不适配。未改package或旧测试；实际展开argv/cwd、命令与原日志见验证卡。

最终两轮各有49份实际运行输入前后副本，涵盖全部tracked backend（含ops与receipt JSON）+新helper，均匹配固定source；runner自身有实际独立before/after副本且相同。source另存57份源码/治理副本。final为这57份当前输入中 **55份相同、2份授权卡元数据变化**，49运行输入全部相同，不称57全不变。先前38/39份focused和仅结束runner hash的历史层不升级为最终前后证据。

source双审：`reviews/source-review-root-571bdc4.json`（`SOURCE_PASS_SCOPED`）与 `reviews/source-review-http-map-571bdc4.json`（`PASS`），完整hash见验证卡。API缺失红、sandbox EPERM环境失败、ECONNRESET waiter/删除receipt预期诊断、真正安全边界与尾部行为红分别保留；Node SQLite ExperimentalWarning仍在host日志中。

勘误：旧 `source-git-proof.json` 的 `unmodifiedProductionPaths` 标签写反，其值实际表示**已修改生产路径**，仅 `backend/src/device-auth.mjs`。以完整diff和mapper逐字节重构为准；旧proof/CP原样保留，新final CP明确此更正，不据该标签声称生产零修改。

## 保留门槛与生命周期

final只改两卡且无运行输入变化，按root授权不重复运行测试；exact final双审尚待，不提前填PASS。源计划、source CP、原日志与副本均保留，新final manifest/输入比较/Git proof/CP另存树外证据根，详见验证卡。

本任务只证明受控development真实密码学与本机file SQLite/HTTP；真机、SDK/App构建对本次host fixture/纯提取不适用。真实Apple/CloudKit/Keychain/WC/Health/签名设备/部署仍未验，production trust/provider/bootstrap仍Unavailable；原051/026组合与052目标backend回归由root后续组织，无M4完成、原生冻结或发布结论。

本树为026活跃依赖保留。作者不merge/push/archive/delete/rebase或推进长期分支；全部必需目标接收、无活跃依赖且必要ignored证据妥善保存后，才由root先原生archive、核实际成功，再安全branch -d；queued/拒绝则保留，不强删。
