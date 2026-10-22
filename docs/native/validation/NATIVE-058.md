# NATIVE-058 验证

状态：实现source已双非作者PASS；final仅本卡和 [任务卡](../tasks/NATIVE-058.md) 收尾，等待exact final双审。original base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，批准 [计划](../../superpowers/plans/2026-10-22-m4-http-fixture.md) `038e2c3510ae8f771e075d8bf9f03ee35fe8f90c`，固定source `571bdc4d2890ed87d926747fbd7131705b97acc5`。actual final SHA仅记树外 `final-checkpoint.json`，避免自引用。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-058`。计划、source、final各层独立，不覆盖旧CP、proof、原日志或输入副本。

## source双审与边界

| 审阅 | 结果 | SHA256 |
|---|---|---|
| `reviews/source-review-root-571bdc4.json` | `SOURCE_PASS_SCOPED` | `e31f0f2ef0a71019fbd246060fa52a113d39c6d3e1ad07111df9c8d7d6997ef7` |
| `reviews/source-review-http-map-571bdc4.json` | `PASS`，无阻塞/代码发现 | `ddb019798427a3ce1e2b29c553e05a48269745960673ed5df29bf08ec1acf4f7` |

两位非作者完整检查唯一生产纯mapper差异、新180行helper与353行test、57份Git来源副本、49实际运行输入与两轮runner前后、全部红绿和限制。source PASS不代替final/merge/原生组合或真实环境验收。

## 最终冻结运行：Node22.23.1

实际Node入口 `/Users/liam/.local/bin/node`，记录的真实二进制 `/Users/liam/.hermes/node/bin/node`：112928848字节，SHA256 `2e3f1286a7eb3736346ed1803e458a0ff909e2b2d5bc746144dcb76970e9b99d`，版本 `v22.23.1`；未升级或下载工具链。

两轮实际cwd均为本任务仓库根 `/Users/liam/.codex/worktrees/m4-native-http-fixture/20260830_足球记录`，HEAD前后均为固定source571。完整展开argv在各 `command.json`：

| 最终冻结轮 | 实际命令 | 单轮结果 |
|---|---|---|
| `runs/source-new-full-frozen` | `node --test backend/test/native-m4-fixture.test.mjs` | **46项/0失败**；0跳过/取消 |
| `runs/source-backend-full-frozen` | `node --test backend/test/*.test.mjs`，展开全部15个test文件 | **207项/0失败**；0跳过/取消，已包含新46 |

不把46与207相加，不把focused或旧161补入。计划Task5原写在backend目录npm test；实际旧 `http.test.mjs:92`、`operational-backup.test.mjs:24/:34`、`operational-tls.test.mjs:31/:35` 用 `backend/src/server.mjs` / `backend/ops/...` 相对仓库根启动子进程，backend cwd不适配。因此root接受在仓库根运行同一Node runner和完整文件集的命令修正；`backend/package.json`、旧测试均未修改。

| 原始最终证据 | SHA256 |
|---|---|
| `runs/source-new-full-frozen/command.json` | `795b9ea6964d547b0b7e1a6596e2ba35131d02e779ef1b3563d0980fb713d361` |
| `runs/source-new-full-frozen/output.log` | `6083787b519dce55a44dbd5a75db09467a4e041440d9235923c8fa52d4e049ce` |
| `runs/source-backend-full-frozen/command.json` | `b46607c5f70d063e42d2609743525d12348f0d7ac0e4b86547ad938a15265e90` |
| `runs/source-backend-full-frozen/output.log` | `1fbfca770f0168828450eaad032caf80a878dd92726eb8a4ec22e6cb295fdc7b` |

每轮49份实际运行输入为全部tracked backend文件（src、ops、test、worker/CLI、receipt JSON、package及附加文档）+新helper，before/after副本逐份与571 Git字节/hash一致；runtime生成的临时key/token fixture不复制进证据。runner每轮均有实际 `runner-before.py` / `runner-after.py`，各3315字节，SHA256均 `308d55eee355658866ceb479c168b174cfbcfe37c0d563b098d5016e577a6205`，与 `runtime-runners/308d55eee355658866ceb479c168b174cfbcfe37c0d563b098d5016e577a6205/runner.py` 相同。

此前 `source-new-full` / `source-backend-full` 同source也通过46/207，但只记录runner结束hash，缺独立before副本；保留历史层，不代替上述最终冻结轮。更早focused捕获38/39份mjs输入、旧runner结束hash及匹配hash的重建/冻结副本，均不升级成49份完整输入或当时实际runner-before证据。

## TDD与诊断分层

| 层 | 实际记录与结论 |
|---|---|
| 缺API红 | `t1-mapper-api-red`、`t2-empty-api-red`、`t3-observer-api-red`、`t4-control-api-red`；只证明API未实现，不冒充行为红 |
| observer行为红 | `t3-observer-behavior-red`：初始happy path接受非品牌verifier和重放；加入genuine/一次nonce等门后27项observer矩阵绿 |
| stdio行为红 | `t4-stdio-behavior-red`：重复control requestID被接受；严格ID/字段/容量门后通过 |
| observer提前close红 | `t4-close-tail-behavior-red`中的observer断言确实观察到提前close；同轮HTTP子项受ECONNRESET waiter诊断影响，不计有意义HTTP红 |
| 实际HTTP尾部红绿 | 修正waiter后，`t4-http-tail-meaningful-red`只移除 `joinTasks(inflightHTTP)`，实际断言因提前关DB失败；精确恢复已保存字节后 `t4-http-tail-green`通过 |
| 环境失败 | `t1-auth-regression` 40项因sandbox loopback listen EPERM失败，非产品红；获工具级loopback放行后 `t1-auth-regression-loopback` 40/0 |
| 测试诊断 | `t4-lifecycle-green`的events.once把预期abort ECONNRESET当失败，改为等待close事件；原删除receipt result实际为`deleted`、deletion.backend为`backendDeleted`，纠正测试预期，生产wire不变 |
| fixture缺陷 | `t4-control-green`捕获坏JSON误分类及ready早于SIGTERM注册race，分别在解析边界和listener-before-ready最小修复；最终冻结轮覆盖并通过 |

最终覆盖mapper原UTF8/LF/空白/Unicode不归一与身份/key隔离；真实genuine verifier/identity、签名/JWKS/issuer/audience/nonce/exp/iat及环境/authority/config/key/clock/generation变化拒绝；全部表逻辑值和原bytes的观察零写；空库与原first-device真实HTTP注册/第二Phone等待；DB/WAL/SHM无Apple输入、Bearer或设备私钥；原请求/原key的beforeCommit回滚与缺row fence、COMMIT/drop后原session恢复、锁/epoch/request bytes重开保持；HTTP/observer/revoker尾部、restart期间close、EOF/SIGTERM完整关闭；协议秘密只在明确apple/auth调用者内存，不写metadata/错误/trace。

Node22.23.1的SQLite ExperimentalWarning仍在host日志中；新sidecar CLI只将本进程warning规范成有限 `runtimeWarning/startup` 诊断，不改变生产或其他测试的warning处理。

## source输入、副本与proof勘误

| 固定source证据 | SHA256 |
|---|---|
| `source-inputs.json`（57份Git源码/治理副本，其中49运行输入） | `f7b576c0ce9a0bd4f0dce1db358668d25f7e6267e1519e7b6f29db4cb5d5dc62` |
| `source-whole-tree.diff` | `6cc66c96805d916ebcdb68b3bcb1707c11247136c7e4090c01d6d68581719d93` |
| `source-implementation.diff` | `baf037fba6fd1a91b7884fa7a528f182a1dbdabacd0907bc33600aa41240a975` |
| `source-git-proof.json` | `eba498498b7779995fbef9bc6f0e89059d1f5c0843c33d7b85f329359a67f8b4` |
| `source-runtime-summary.json` | `ab981918120a4ea917d9aa368dfefbcdb1fc786c0bf412946fde8075905e2286` |
| `source-manifest.json` | `87a55c3814c57d13ba06c2099ba042f3a4da16e9a48866c2954e98f8b333f0e1` |
| `source-checkpoint.json` | `52f51cc9aac5d75eab590ffe8d239d5e2632e6b2209b166bf163b85287cc0663` |

**勘误：** 旧source-git-proof的字段 `unmodifiedProductionPaths` 标签语义写反，其值 `backend/src/device-auth.mjs` 实为**已修改生产路径**，不是未修改路径。完整diff和纯mapper反向重构证明该文件是唯一生产修改；新final proof使用 `modifiedProductionPaths` 并另记本勘误。旧proof、source CP和hash均保持原样，不以错标签声称生产零差异。

计划层 `planning-inputs.json` 的21份2cab输入及4份acfd研究参考继续原样保留；研究稿6新+8复用14输入不当作本次57份source或49份运行输入。未读取026工作目录或Watch WIP，不把移动ref当执行输入。

## final仅两卡的静态验证与停写点

final只改本卡和任务卡。与固定source的57份清单比较，**55份当前输入逐字节相同，2份授权卡为元数据变更**；49实际运行输入全相同，计划和三实现文件全相同，不称57全不变。按root授权不重复运行Node/HTTP/SQL/测试/构建或设备探测；只做路径范围、Markdown链接、diff-check、Git/blob/输入副本hash和clean含ignored核验。

actual final SHA、57份当前输入副本及55+2比较、完整base→final与source→final diff、新Git proof、证据清单和停止检查点由树外 `final-inputs.json`、`final-input-comparison.json`、`final-whole-tree.diff`、`final-metadata.diff`、`final-git-proof.json`、`final-manifest.json`、`final-checkpoint.json` 记录；不覆盖旧source/计划证据。exact final双审尚待，不提前填PASS，作者提交后clean停写。

本任务只证明host受控development真实密码学/file SQLite/HTTP；真机与SDK/App构建不适用此host fixture/纯提取变更。真实Apple账号/授权码、CloudKit、Keychain、WC、Health、签名设备、生产部署和原051/026完整链仍未验；同进程reopen不代表跨进程key持久化、durability或RPO。production保持Unavailable，无M4完成、release冻结或原生发布结论。

root后续须冻结停写clean026，保留052已审修改、普通no-ff合入并重跑实际target完整backend/新suite与原生组合。058保持活跃依赖；所有必需目标接收、无依赖且必要ignored证据另存后，root才原生archive核实际成功，再安全branch-d。当前作者不merge/push/archive/delete/rebase、不推进长期分支、不碰026。
