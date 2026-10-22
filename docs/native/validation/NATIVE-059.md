# NATIVE-059 验证记录

状态：source `42fb3b1a688a7efa7ec0854b4f0fe4090a5ef21b` 已获root与第二位非作者whole-source PASS。本次按root的final metadata release仅收尾两卡，完整final SHA由提交后树外checkpoint绑定；exact final双审、held026消费和整合尚未完成。[计划](../../superpowers/plans/2026-10-22-m4-watch-setup-evidence.md)保持批准519 bytes，[任务卡](../tasks/NATIVE-059.md)记录所有权及后续治理。

证据根 `E059 = /Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-059`。下列各层原件、失败、runner及source checkpoint均保留，不覆盖或重标。

## 基线、计划与输入来源

- original verified dev `2cab4640ee3a375da39fdabf0f5a317600b0c263`；accepted055 final `b355b5c6e93fd811cba959d5257836de1d47bca5`；root普通no-ff后的effective base `1a72c21b5b44b6f436006a4d50273c0e27dc22fb`全树同055 final。
- own worktree `/Users/liam/.codex/worktrees/m4-watch-setup-evidence/20260830_足球记录`；branch `fix/m4-watch-setup-evidence`，attachment `01a16211-394f-7a81-9e14-6e2e24f3a1f6`。初始、冻结source的HEAD/clean含ignored已核。
- 旧de7计划因R59-P1 mandatory context会在本地拒legacy前触发实际relay context exchange而未准实现；修订 `519ff83ad145ef54e543375f8b43a9916fcbe663` 移除context输入、返回optional原storedcontext，双审PASS后root明确放行Task1-4至source冻结。
- planning层最初402个own-base实际副本manifest SHA256 `452d3f65251e7830ce946a69cbb739dab29f6bcb315600cb957cd86ac68353f5`；planning-v2编辑前405个de7实际副本manifest SHA256 `0fc88ce5af64b9f9a1ca5faf9acd853a4dc2deb28d144ac69cd305bd66202e5f`。旧计划、R59-P1报告与checkpoint原件保留。
- source相对519只四登记源/测试路径548+/1-。055 factory、服务/required协议、原存储顺序/schema、其他模块、026/058、工程配置均未改；计划与两卡在source冻结前仍保持519。当前只补两卡元数据，未重跑矩阵。

## 实际TDD与执行分层

每层完整argv/cwd/开始结束时间/exit/原log及SHA256位于 `execution/<layer>/execution-before.json`、`result.json`、`raw.log`；汇总索引 `source-42fb3b1/execution-layer-index.json` 保留历史层与source差异。表中数字为实际“测试/失败/非预期”，loop里的38表等矩阵是测试内分支，不冒称额外XCTest项。

| 独立层 | 实际结果 | 解释 |
| --- | --- | --- |
| initial-store-runtime-red | **2/2/0，exit1** | 可编译fail-closed scaffold使真实empty/admission两个正例断言失败；055纯admission仍拒绝 |
| store-boundary-red | **无runtime，exit1** | `AccountDeviceRole`错误类型名的编译诊断；修正为实际`AccountBindingV4.Role`，不充作RED |
| store-boundary-runtime-red | **3/4/0，exit1** | 同一fail-closed scaffold的正例与typed-error期望失败，不证明每个history/table guard都曾独立移除并RED |
| store-full-focused-green | **15/0/0，exit0** | 新Store类完整正负矩阵；此历史层原facade尚未修改 |
| facade-runtime-red | **3/2/0，exit1** | 原055 facade测试仍过，两个新增capability断言失败；不靠强unwrap制造unexpected |
| complete-focused-green | **43/0/0，exit0** | 25个原055 Store +15个setup Store +3个facade；全407输入bytes与source相等 |
| frozen-core-full | **381/0/0，exit0** | 单个fresh完整Core命令；407输入bytes与source相等 |

初runner错误把最后一个0-test product当总数，`initial-store-runtime-red/result.json`原计数0/0/0及原runner/rawlog全部保留；该层独立`count-audit.json`及两位审阅者逐raw product计数确认实际2/2/0。后续使用版本化`run-layer-v2.py`按各`.xctest`product汇总，不改旧层。

本任务取得上述实质scaffold/能力RED；最终负例矩阵通过但不声称38个guard逐个独立RED。执行中所有失败/编译诊断如实保留，未把它们算进GREEN或预期测试总数。

## source的单次fresh完整Core

实际执行：

```sh
swift test --package-path native/Packages/MatchCore --scratch-path /private/tmp/football-record-NATIVE059-core-full
```

| 同一完整命令中的product | 实际测试/失败/非预期 |
| --- | --- |
| MatchCoreTests | 44/0/0 |
| MatchStoreTests | 249/0/0 |
| MatchSessionTests | 71/0/0 |
| MatchSyncTests | 17/0/0 |
| **单次完整总计** | **381/0/0，exit0** |

43 focused已包含在381中，不再相加；15 Store历史GREEN及其他RED/compile层也不累计为新source完整结果。完整Core rawlog SHA256 `b510d7848dd01d407c13234622451709d00f1f4d2f4d339ab8b90f9588ff0bcb`；focused rawlog SHA256 `0425361aed06f4e1fb3a39fa47e90596556d0ab7012f902453b6aba3c2119f05`。

## 四最低SDK：只证明编译

实际Xcode **27.1 build27A9275** / Swift **6.4**；iPhoneSimulator/iPhoneOS SDK27.1，WatchSimulator/WatchOS SDK27.0。最低iOS17/watchOS10未变。每项实际命令为`xcrun swift build --package-path native/Packages/MatchCore --target MatchSession --sdk <当次解析的实际路径> --triple <下表> --scratch-path <独立目录>`，完整实际argv与SDK路径、工具前后输出均在对应frozen-sdk目录。SDK launcher也在执行前留副本/hash；四项并行、各自scratch、同source输入，无App或签名安装。

| 层 / 最低triple | 实际结果 | rawlog SHA256 |
| --- | --- | --- |
| frozen-sdk-ios-sim / arm64-apple-ios17.0-simulator | exit0 | `295ee96f8b47ac4ba0a98d2353d26ebacf8c946ad0252a7583bc2d538f9d8b43` |
| frozen-sdk-ios-device / arm64-apple-ios17.0 | exit0 | `459f06a0fd29215fe42a68c2e86e1e1b4b0b8cb8800b4c2518ba4908ced2e82d` |
| frozen-sdk-watch-sim / arm64-apple-watchos10.0-simulator | exit0 | `24c34d50c521501a0e8c98d52d9496658f56917b5ab354f6aba884f0af47b956` |
| frozen-sdk-watch-device / arm64-apple-watchos10.0 | exit0 | `658e38406e029c649c2700035c4f2b5824c11a96cd7b5750f5675a57386c8347` |

原有LifecycleInboundCoordinator两处unused repository warning留在原日志；未借本任务修改其他路径。无新设备、simulator runtime、App/UI或真实Apple能力验收。

## 本机证明和测试边界

原Store单BEGIN DEFERRED、no-await受检snapshot核expected generation、固定trust/sync environment、canonical公钥和keyID、storedcontext initializer/epoch/环境、原deviceID与Phone不同。bounded lifecycle metadata全行allowlist只容可选identity-generation及唯一exact原admission；非法UTF8/NUL/多admission/未知/partial/type/checksum/canonical/预算拒绝。实际schema非lifecycle38表逐表presence拒绝；额外表/trigger、缺schema、错误user_version也拒绝。无catch055-as-fresh、SQL repair/清历史、网络、signer或vault操作。

测试用原save/close/accept和真签名registered/knownAbandoned构造pending、closed、receipt-only、accepted和legacy缺marker；全部不属于setup，原receipt bytes保留。055原义保持：真正空返回nil，纯admission/缺来源历史仍unavailable，真实接受才有current证据。所有拒绝前后比完整schema/全rows/user_version/原连接total_changes，正例与关闭重开也保留原facts。

两个真实SQLite连接在generation首读后的hook里提交新generation/context，旧snapshot只见完整旧值，后续旧expected拒绝，新expected可读当前storedcontext而不声称fresh；更换原key仍拒绝。持BEGIN IMMEDIATE writer时可读旧已提交snapshot；expected错与hook错误后事务释放，随后可再读，closed Store拒绝。

原SQLiteSessionRepository + PersistentDeviceIdentityProvider独立identity文件 + 原MatchSession coordinator的正例真实执行；两个namespace不混用，关闭重开保留identity bytes和完整SQL事实。此仅证明已核原生初始化允许38表严格零，不等于026真实M4 make全表初始化或其consumer已验证。

结果不可公开构造、非Codable，仅当前本地snapshot：empty=nil，admissionOnly=原受检storedcontext；没有fresh Phone/context、首次admission generation、requestID、历史从未commit或antirollback保证，也不是055/current/credential/permit/ready。合法不同account/epoch的storedcontext可作为本地事实返回，必须由026另做fresh独立身份/Phonecontext精确比对；closed/abandoned历史仍拒绝，不开放新登记。

## 输入、runner、source和双审

- source `42fb3b1a688a7efa7ec0854b4f0fe4090a5ef21b` 的`source-42fb3b1/source-checkpoint.json` SHA256 **`f788780f06339870fa538770a58da343788fa14bf46c205436cd9c51853f4b69`**。
- `source-42fb3b1/source-input-manifest.json`含 **407** 份own-worktree直接副本及mode/Git blob/SHA256/size，Git/current/copy全等，SHA256 **`9bdf2da12eb64e836dbaf862364d3e7442a8fc5ecaeab5b4fc2f0407e8600299`**。
- `source-42fb3b1/evidence-manifest.json`冻结 **4984** 份证据，SHA256 **`0aab7c335523118474716ca22558257a8f3178fff58857359a195797848d7b5b`**；完整source/task diff、11层及coverage/static检查都在原目录，原件不覆盖。
- 每层执行前直接复制 **407** 个实际仓库输入，包含完整Core/Fixtures/backend receipt fixture的保守superset，不宣称每份文件均被runtime读取。执行后runner逐项hash比对并记录零drift，**没有独立after输入副本**。runner有执行前副本/SHA256及执行后hash比对记录；tools有before/after文件。不是事后重建输入或仅在运行后记runnerhash。
- complete-focused、fresh full Core与四SDK这6个层的407实际before bytes全等source；另5层保留实际历史源差异，不重标覆盖当前source。实际argv/cwd/time/log/exit、每product计数及before/post检查均保留。
- root source报告`reviews/source-review-root-42fb3b1.json` SHA256 **`7e73718f9dbee0eb6843eefa30596c8bc2a3bb6511a5d42e20f70db0b9289695`**；second `reviews/source-review-diagnosis-42fb3b1.json` SHA256 **`ddb58cb0cb544332933a0eae5eb54fb143ad6a584eb18c644dc94d54ff575457`**。双方whole-source无finding，并核407输入、4984证据与原日志实际计数；两位仅只读审证据，未冒称他们重跑矩阵。
- 本次只收尾任务/验证两卡，计划/四实现路径及其他产品/运行输入保持source。final静态检查以source407项对照 **405项原bytes+两卡metadata delta**，新全tree/current copies/mode/blob/hash/完整及增量diff/links/clean含ignored绑定树外独立final checkpoint；final SHA不自指于两卡。元数据不重复运行测试/构建，等待exact final双审。

## 026消费与真实环境保留门槛

059未改或消费修复026。原R26-W1 source `2bb9842867b10d6bb3013f537dcb2a1df4c592b4` 的1/5/0是原AuthorityClient/WatchService处理**injected、relay-backed `AuthorityHTTPResponse(status:503)`**后同owner重试失败，非本叶子Node/socket/真实HTTP端点，也未在本叶子转GREEN。旧04d269/0及root旧四SDK保持各自历史，不用于新consumer。

root须在059 exact final双审后no-ff接入clean/stopped held026，再由原026作者仅对explicit registerWatch且unbound/noWatchpending：本地preflight零relay拒legacy → fresh独立identity/Phone RPC → 原admission全context精确比对 → samegen/lifetime全projection复读 → 原Service。Phone pending auth/已有Watch pending的原IDrecover、055、TTL/fullpairseal/common gate和close join均保留。freshPhonecontext mismatch、samegen swap、051重开/原503 GREEN、fresh full Integration及root相关SDK归026另验；实际初始化差异须保全并按actual收口，不能清数据或放宽未知history。

本叶子无需用户连接设备；本机Store/reader及文档收尾不涉及真人设备操作。SDK仅编译；没有真实Apple/Keychain/iCloud/CloudKit/Health/WC、账号、签名配对安装、App/UI、部署或协议E2E验证，不证明whole026/M4。production仍Unavailable，无原生冻结/发布，main/release/原型tag不动。作者两卡提交后停写，不merge/push/archive/delete/rebase；活跃消费依赖保留树，后续root确认接收和安全保存结束后才nativearchive+safe branch-d，不盲重试queued归档。
