# NATIVE-059：Watch setup 的原只读快照证据

状态：source `42fb3b1a688a7efa7ec0854b4f0fe4090a5ef21b` 已获 root 与 `/root/m4_simulator_diagnosis` 两位非作者 whole-source PASS，无未解决 finding。root 已放行仅任务/验证两卡元数据收尾；作者提交后停写，exact final 双审及 held026 接入仍由 root 安排，尚未完成消费修复或合并。

- 唯一作者 `/root/m4_watch_setup_evidence`；original verified dev base `2cab4640ee3a375da39fdabf0f5a317600b0c263`。
- root 普通 no-ff 接收 accepted055 final `b355b5c6e93fd811cba959d5257836de1d47bca5`，effective base `1a72c21b5b44b6f436006a4d50273c0e27dc22fb` 全树同055 final。
- 分支 `fix/m4-watch-setup-evidence`；原生工作树 `/Users/liam/.codex/worktrees/m4-watch-setup-evidence/20260830_足球记录`；attachment `01a16211-394f-7a81-9e14-6e2e24f3a1f6`，初始与冻结source均clean含ignored。
- 旧计划 `de7b9c357e789825be04429c28dc3dbdb830365f` 因R59-P1未准实现，修订计划 `519ff83ad145ef54e543375f8b43a9916fcbe663` 已双审PASS并获root实施放行。两计划及其证据分层保留，计划现bytes保持519不改。
- Store实现/测试提交 `0474aeeb4c150861dedde55e1d12d4e035b5c7d0`，原facade转发/测试source `42fb3b1a688a7efa7ec0854b4f0fe4090a5ef21b`。本次仅两卡收尾；final完整SHA由提交后树外新checkpoint绑定，不在文档自指。
- 唯一接收目标held026 `test/m4-e2e-integration`；登记原R26-W1测试checkpoint `2bb9842867b10d6bb3013f537dcb2a1df4c592b4`仅为固定参考，root实际接入前重核clean/stopped combined目标。059不入dev/release/main，作者不擅自merge依赖或推进长期分支。

[实施计划](../../superpowers/plans/2026-10-22-m4-watch-setup-evidence.md)的四个实现/测试路径已交付：新Store `WatchRegistrationSetupEvidence.swift`、原facade `WatchEvidenceReader.swift`、新Store测试 `WatchRegistrationSetupEvidenceTests.swift`、原facade测试 `WatchEvidenceReaderTests.swift`。source相对批准计划仅四路径548+/1-；不改055 current factory、原repository协议/服务/持久化顺序/schema、AccountKit、026/058、Package/lock或共享工程配置。本次元数据只写本卡和[验证卡](../validation/NATIVE-059.md)，四实现路径和计划原bytes保持source。

optional `WatchRegistrationSetupEvidenceReadingV4` 仅收expected generation/deviceID/publicKey，由原facade转发原Store。factory-only、非Codable projection区分empty（admittedContext=nil）与唯一原admission（完整受检storedcontext）。同一个同步actor的BEGIN DEFERRED内核原fixedtrust/环境、generation、原device/key、bounded exact lifecycle allowlist及全部38张非lifecycle原表presence零；成功和拒绝均无SQL修复、网络、signer或vault操作。真实原facade、独立identity文件、原MatchSession coordinator、关闭重开和两个真实SQLite连接均有本机测试。

它只证明当前本地snapshot，不是055 current proof、credential、permit、fresh Phone观察或ready。admission没有历史generation/challenge/requestID；不推断首次generation、旧epoch仍有效或历史从未commit/antirollback，不开放closed/abandoned后的新登记。055对纯admission继续unavailable，原receipt/history getter保留原义。

[验证卡](../validation/NATIVE-059.md)记实际单次fresh完整Core **381/0/0**（44 Core +249 Store +71 Session +17 Sync），focused **43/0/0** 已含其中，不再相加；最低iOS17/watchOS10 MatchSession（含Store）sim/device四SDK均exit0。实际Xcode27.1 / Swift6.4，iPhoneSDK27.1 / WatchSDK27.0；SDK只证明编译。早期Store scaffold RED2/2/0、typed-error scaffold RED3/4/0、facade RED3/2/0与Role编译诊断分别保留，不声称38个guard各自独立RED。初版runner错误取末个0-test product的原result保留，单独raw审计更正2/2/0。

source冻结407份实际输入/Git/mode/blob/hash、11个执行层及4984份证据。每层407份实际执行前副本包含完整Core/Fixtures/backend fixture的保守输入superset，执行后逐hash比对零漂移；没有独立after输入副本。runner有before副本及after hash比对记录，tools有before/after。完整source双审仅只读审原日志/证据，没有冒称审阅者重跑。元数据收尾不重复运行矩阵；final与source407项对照为405项原bytes加两卡元数据delta，全部产品/运行源未变，独立final checkpoint记录。

root与第二位source报告位于E059/reviews/source-review-root-42fb3b1.json、source-review-diagnosis-42fb3b1.json，SHA256分别 `7e73718f9dbee0eb6843eefa30596c8bc2a3bb6511a5d42e20f70db0b9289695`、`ddb58cb0cb544332933a0eae5eb54fb143ad6a584eb18c644dc94d54ff575457`。旧source checkpoint/manifest/log不覆盖。

026仍须仅对显式registerWatch且无binding/Watchpending先用本地preflight拒legacy，再fresh独立identity/Phone RPC、原admission全context比对、samegen/lifetime全projection复读，最后原WatchService。Phone pending auth和已有Watch pending的原IDrecover不替换。059尚未消费修复026；其injected503是原AuthorityClient/WatchService处理relay-backed `AuthorityHTTPResponse(status:503)`，不是本叶子Node/socket/真实HTTP端点。后续同owner/051重开GREEN、fresh full Integration和root相关SDK由026另验。

本叶子本机Store/reader与纯文档收尾不需用户接设备；真机不适用该叶子的本地行为验证。未做真实Apple/Keychain/iCloud/CloudKit/Health/WC、账号、签名配对安装、App/UI、部署或协议E2E，不等于整包026/M4；production保持Unavailable，无原生冻结/发布，main/release/tag不动。

作者提交两卡后clean停写，等待exact final双非作者审。root才可no-ff接入clean/stopped held026并复验；活跃消费/验收依赖期间保留树和分支。目标全部接收且依赖结束、所有成果安全保存后，由root原生archive，确认实际完成再safe branch-d；queued请求不盲重试。作者不merge/push/archive/delete/rebase。
