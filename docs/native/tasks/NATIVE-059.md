# NATIVE-059：Watch setup 的原只读快照证据

状态：**仅计划阶段**。三文档已编制，产品/测试尚未写入；等待 root 与第二位非作者对 exact planning commit 双审。用户已选子代理开发，不另问执行模式；双审与root放行之前不开始实现。

- 唯一作者 `/root/m4_watch_setup_evidence`；original verified dev base `2cab4640ee3a375da39fdabf0f5a317600b0c263`。
- root 已普通 no-ff 接收 accepted055 final `b355b5c6e93fd811cba959d5257836de1d47bca5`；effective actual base `1a72c21b5b44b6f436006a4d50273c0e27dc22fb`，全树等055 final，初始branch/HEAD/clean含ignored已核。
- 分支 `fix/m4-watch-setup-evidence`；原生工作树 `/Users/liam/.codex/worktrees/m4-watch-setup-evidence/20260830_足球记录`；attachment `01a16211-394f-7a81-9e14-6e2e24f3a1f6`。
- 唯一接收目标 held026 `test/m4-e2e-integration`，登记测试checkpoint `2bb9842867b10d6bb3013f537dcb2a1df4c592b4`；root接入前重核clean/stopped目标。作者不推进长期分支，不擅自merge依赖。

[实施计划](../../superpowers/plans/2026-10-22-m4-watch-setup-evidence.md)定义独立 optional `WatchRegistrationSetupEvidenceReadingV4` 与 factory-only、非Codable `CheckedLocalWatchRegistrationSetupEvidenceV4`。同原Store单BEGIN DEFERRED内核expected generation、原固定trust、原device/publickey/keyID和完整context，严格区分empty与唯一exact admission；全lifecycle有界allowlist和38张非lifecycle原表presence检查拒绝全部attempt/receipt/current（包括closed/legacy/partial）、binding、Phone/auth/control/deletion/migration或未知事实。它只准原协议setup，不是055 current proof、credential、permit或ready。

R26-W1背景：原admission COMMIT先于首次challenge/sign和saveAttempt；firstHTTP503后没有持久注册requestID，055按既有语义正确拒绝纯admission，使026下次入口无法继续。原作者固定真实RED为1项/5断言失败/0unexpected，仅证明旧026缺陷，不是本叶子运行。本任务不改055 factory、原服务/协议/持久化时序或026/058源，不catch055当fresh，不清admission/造marker或placeholder attempt/猜ID/切Phone/回填旧证明。一旦有attempt/unknown仍只能原ID recover。仅显式registerWatch且无绑定/无Watchpending能用此setup能力；不替换全动作055 pre-gate，signIn/无attempt recover不能因此变fresh，Phone pending auth recover和已有Watch pending原IDrecover保留原路径。

admission实际仅存context/publicKey，deviceID在row key，没有历史generation/challenge/requestID。本projection只能证明当前受检快照，不宣称首次准入generation或历史从未commit。原Session/Store无application默认SQL行；PersistentDeviceIdentityProvider写独立identity文件，本reader不读改该文件。原facade+provider+coordinator真实正例纳入后续TDD；未声称026实际make的全部表已在本轮运行核验。

本轮唯三owned路径：

- `docs/superpowers/plans/2026-10-22-m4-watch-setup-evidence.md`
- `docs/native/tasks/NATIVE-059.md`
- `docs/native/validation/NATIVE-059.md`

后续仅准四源/测试路径（当前仍禁止写）：

- `native/Packages/MatchCore/Sources/MatchStore/WatchRegistrationSetupEvidence.swift`（新）
- `native/Packages/MatchCore/Sources/MatchSession/WatchEvidenceReader.swift`（追加原facade forwarding）
- `native/Packages/MatchCore/Tests/MatchStoreTests/WatchRegistrationSetupEvidenceTests.swift`（新）
- `native/Packages/MatchCore/Tests/MatchSessionTests/WatchEvidenceReaderTests.swift`（追加）

Package/lock、project/scheme/target/capability/entitlements及共享配置不动；不覆盖其他作者改动。055已接收接口为唯一前置；未审依赖不能消费。

[验证说明](../validation/NATIVE-059.md)记录本轮402份own-base实际输入副本/Git/hash、固定四份026证据副本、完整三文档diff、链接及checkpoint。已执行仅静态检查；**未运行Swift、Node、HTTP、SQL、测试、构建、设备或模拟器探针**。本轮真机不适用（文档规划）；后续预期真实Store/facade runtime RED/GREEN、fresh full Core、四最低iOS17/watch10 MatchSession SDK，全部尚未执行，不预填测试数量。

计划双审后由root放行唯一作者。后续完整source与final分别双非作者审查；通过后root no-ff接入clean/stopped026，原026作者消费并取得真实R26-W1同owner/重开GREEN、fresh full Integration及SDK。059不实现composition、不等于整包M4或真实Apple/设备/协议E2E验收；production保持Unavailable，无原生冻结/发布，main/release/tag不动。

本planning commit完成后作者停止所有写入等待计划审。活跃依赖期间保留工作树；目标接收且依赖结束、所有成果安全保存后，由root原生archive并确认实际完成，再safe branch-d；queued归档不盲重试。作者不自行merge/push/archive/delete/rebase。
