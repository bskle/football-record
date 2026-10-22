# NATIVE-059 验证记录

状态：**planning-v2-only；零runtime**。旧de7计划因R59-P1未获实现放行，旧证据全部保留。本卡不宣称产品实现、测试通过或SDK构建通过。[计划](../../superpowers/plans/2026-10-22-m4-watch-setup-evidence.md)与[任务卡](../tasks/NATIVE-059.md)待新的exact planning commit双非作者重审，作者提交后停止写入。

## 本轮实际输入与静态检查

- own worktree `/Users/liam/.codex/worktrees/m4-watch-setup-evidence/20260830_足球记录`；branch `fix/m4-watch-setup-evidence`，attachment `01a16211-394f-7a81-9e14-6e2e24f3a1f6`。
- original base latest verified dev `2cab4640ee3a375da39fdabf0f5a317600b0c263`；root接入accepted055 final `b355b5c6e93fd811cba959d5257836de1d47bca5`；effective actual HEAD `1a72c21b5b44b6f436006a4d50273c0e27dc22fb`，全树同055 final。
- 开始写入前 `git status --short --branch` / `git status --short --ignored`、`git rev-parse HEAD`、`git show -s --format=fuller HEAD`已核：指定分支/HEAD，clean含ignored。
- 仅读own base源码/Git与root指定四份固定026 JSON；未读活跃026/058或其他writer工作目录。只读helper inventory子任务亦只读同一base，已停读，无并行writer。
- 读AGENTS、Git治理、M4合同、writing-plans/receiving-code-review/commit-conventions；静态核API可见性、初始化、schema、原服务次序。部分最初猜测路径的rg/sed不存在诊断已通过`rg --files`定位纠正；它们不是测试或运行证据。

证据目录 `E059 = /Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-059/planning`。

`effective-base-inputs/files/` 是开始写入前从**自己的实际worktree**直接保存的全402份tracked输入；manifest同时记录mode、Git blob、SHA256、size，每份直接bytes与effective base Git blob相等。`effective-base-input-manifest.json` SHA256为 `452d3f65251e7830ce946a69cbb739dab29f6bcb315600cb957cd86ac68353f5`；`effective-base-git.txt`保留当次HEAD/status。文件复制、hash与Git静态读取没有运行任何业务SQL或探针。

| 固定外部引用（均已直接复制到E059/fixed-reference-inputs） | SHA256 |
| --- | --- |
| NATIVE-026/source-review-diagnosis-04d9948.json | `af71febe1322d14fe752b65979fe46fc00ca8a9b5b40ae3ba25f2bf12cd76136` |
| NATIVE-026/active-watch-scope-20261022/source-review-root-04d9948.json | `2ef52ce4e50a516b1333ddf6f817f45f87902a39d6aeb6b72c8c356bcae35a06` |
| NATIVE-026/active-watch-scope-r26-w1-20261022/red-checkpoint.json | `0758859bdc8cf84f33588230160b0089fbcab8d527457d5cf66c23f7ff4f0666` |
| NATIVE-026/active-watch-scope-r26-w1-20261022/minimal-setup-read-contract.json | `ffd76965c971abee6925f4c7e394d0b9d019eb69aa684aea40cd0ce0783dc5e1` |

外部RED source `2bb9842867b10d6bb3013f537dcb2a1df4c592b4`的1项/5assertfails/0unexpected，是原026作者实际首次HTTP503后纯admission重试失败。该checkpoint的输入/结果由原作者留证，本轮仅校验上述固定JSON及hash，没有重执行或把旧269/0重新归属给新测试。

静态结果：只准三文档；完整tree差异、文件hash/链接存在性、计划API一致性和placeholder检查、`git diff --check`与exact提交/clean含ignored记录在`planning-checkpoint.json`及其引用文件。planning SHA只能在提交后由该树外checkpoint绑定，三文档不自指尚不存在的commit。原base所有402个tracked输入在文档添加后仍逐bytes相等；无产品、测试或配置改动。

## R59-P1 三文档修订的独立证据

旧计划`de7b9c357e789825be04429c28dc3dbdb830365f`要求Phonecontext作为reader参数，026重开owner必须先调用实际`watchRelay.registrationContext()` exchange才能本地排除legacy，违反四入口零dispatch。root固定报告`E059/plan-review-root-de7b9c3.json` SHA256 `f01396a9472b636a915689ac57340f47b227e32e9c6f0dd8a3f01f001b96c827`，本次只处理该已明确finding，不自行扩写其他发现。

修订目录`E059v2 = /Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-059/planning-v2`。编辑前直接复制de7全部405份tracked实际输入并逐Gitblob核对；`base-plan-input-manifest.json` SHA256 `0fc88ce5af64b9f9a1ca5faf9acd853a4dc2deb28d144ac69cd305bd66202e5f`。R59-P1报告与旧checkpoint固定副本放独立references；旧计划层原件/manifest/checkpoint不覆盖。

新API仅expectedGeneration/deviceID/publicKey；projection改`admittedContext: WatchRegistrationContextV4?`，empty=nil，admissionOnly来自原受检storedcontext。全部protocol/Store-hook/facade-signature/调用示例/测试矩阵/两卡同步；没有expectedPhonecontext权限保证。原固定trust与storedcontext initializer/canonical/key/环境预算、38表与全history拒绝保持；本叶子不开放closed/abandoned后新登记、不宣称已有受验证fresh后续流程，只处理未形成attempt的纯setup重试，其余保持原scope、后续另案。原402个非本任务输入逐bytes不变；修订全tree/增量diff、类型/链接检查及newSHA/clean含ignored绑定新`planning-checkpoint.json`与manifest。

## 后续必须执行的叶子矩阵（本轮未执行）

| 分层 | 后续方法与期望 |
| --- | --- |
| 有意义runtime RED | 新API先用可编译fail-closed scaffold，真实空Store/原唯一admission通过XCTFail断言失败；编译诊断另存，不能充当RED |
| Store focused GREEN | 原coordinator admission、真实registered/closed签名、legacy缺marker、receipt-only、attempt/partial/未知、异device/key、实际storedcontext identifier/epoch/环境与canonical/checksum/预算、全38表presence；empty的admittedContext=nil、admissionOnly完整原storedcontext；无expected Phonecontext参数，成功/拒绝都全rows/user_version/changes不变 |
| 第二真实SQLite connection | 旧snapshot不混新generation/原完整admittedContext；旧expected拒绝，新expected返回实际storedcontext且不称fresh；持writer时可读；失败释放snapshot |
| 原facade真实正例/回归 | 原Provider外部identity文件+原facade+实际lane/coordinator，关闭重开同identity；独立库不能混用；055空nil/纯admission拒绝/真实accepted成功原语义保持 |
| fresh full Core | 单次完整命令，记实际各suite/总数、0failure/0unexpected、exit0；focused含于full不相加 |
| 四最低SDK | MatchSession target（含Store）；iOS17 sim/device、watchOS10 sim/device，各独立scratch/实际SDK path、exit0；只证明编译 |
| whole source / exact final | root+第二位非作者各双审；全输入/证据hash/完整tree diff/current bytes/clean含ignored绑定完整SHA |

每个执行层之前直接冻结完整实际runtime输入、Git/mode/blob/hash/size、工具版本、实际argv/cwd/时间；after逐项零漂移。原始log/失败/编译或sandbox诊断保留并明确层次，不能把历史055/026结果拼作新source单轮。所有后续runtime项目当前均未执行，测试数量不预填。

## held026与真实门槛

本叶子没有验证026的真实M4 make全表默认项，且不改任何composition。root将双审final no-ff合入clean/stopped held026后，由原026作者先本地preflight排除legacy（在任何relaycontext exchange前），然后取fresh完整Phonecontext与fresh独立identity核对；若有admittedContext则原bytes全等，再samegen/lifetime复读setup比较原state/optional完整context/key，全部通过才原Service。freshPhonecontext逐字段/跨epoch不匹配及复读变化、重开无缓存和四入口零relaydispatch都归026消费回归。必须取得原R26-W1实际HTTP503同owner与关闭重开GREEN、fresh full Integration和相关SDK；如正常初始化事实与叶子契约不同，按actual差异独立收口，不能清数据或放行未知历史。

055纯admission继续unavailable；legacyregistered缺marker/receipt-only/closed或unknown/partial异常仍零网络、vault和SQL修复。setup只返回当前受检快照，不证明历史从未commit；仅显式registerWatch且无绑定/无Watchpending可消费，signIn/无attempt recover不得借此变fresh，Phone pending auth和已有Watch pending原IDrecover仍保留原路径。存在attempt/unknown仍用原IDrecover。真正registered后仍需055、原scope/pairseal、credentialTTL与commongate才ready。

本轮零Swift/Node/HTTP/SQL/tests/build/device/simulator探针。纯文档真机不适用；后续本地Store/reader可自动验证，不需用户接设备。四SDK也不证明真实Apple/Keychain/iCloud/CloudKit/Health/WC、账号/配对/签名安装/部署、协议E2E、App/UI或整包026/M4。production保持Unavailable，main/release与原型tag不动，无冻结或发布。

作者不merge/push/archive/delete/rebase，planning commit后停写等待root和第二位非作者计划审。活跃依赖保留，后续完整接收和安全保存结束后由root nativearchive+safe branch-d；不重复queued请求。
