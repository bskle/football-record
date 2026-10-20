# NATIVE-047 Existing cloud erasure reopen

依据 [M4](2026-10-18-native-m4.md) 与 [Git治理](../../git-workflow.md)。仅修复026恢复时 Cloud ledger 的已存文件准入与原receipt重放，不替026拥有目录/catalog或完成全部本地删除。

## 登记和所有权

作者 cloud；非作者 root、m2。登记base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，accepted044 final `60a1a7c37df3b49925534d0fcd5d6db6ea93c485` 已由root普通合入，effectiveBase/初始HEAD `4cd9cc376e84318061d5aab447b59b94ded26db3`，parents为2cab+60a；held026登记target `ae66e20581198ababe67cb87d73398ad49514d7b`。树 `/Users/liam/.codex/worktrees/m4-cloud-erasure-reopen/20260830_足球记录`，分支 `fix/m4-cloud-erasure-reopen`，attachment `01a1575c-3c2e-7ff0-a155-7326be806f9d`，created1792467024；已自行核对HEAD/branch/clean含ignored。

唯一六路径：SQLiteCloudLedger.swift、CloudLocalTransportErasure.swift、新CloudLocalTransportReopenTests.swift、本计划、047任务/验证卡。不得改通用协议、schema、receipt/canonical/digest格式、026、旧044、Package或工程。不派helper、不merge/push/archive。

## 已批准具体API和算法

- 具体 `SQLiteCloudLedger.init(existingLocalErasureURL:fault:)` 只重开既存exact当前v4。lstat regular/no-symlink并记原dev/inode；internal CloudSQL access mode默认仍原RW|CREATE，新路径先RO existing。RO只查quick_check/currentversion/shared044strictlayout/canonical/control，绝不CREATE、迁移或journal_mode赋值。known WAL/SHM按原SQLite协议恢复协调允许；不承诺它们恒定bytes/inode。未知/不支持或无法分类typed拒绝。
- 关闭RO并核原inode，再RW existing不含CREATE；重新核原inode、strictlayout/canonical/control与原WAL模式，确认后仅设connection synchronous FULL。缺文件、空文件、v0-v3、future/unknown不修复/新建/迁移。catalog原ownership及原inode权威仍由026承担。
- private erasure-only mode在共同事务入口拒绝全部普通write；专用fresh erase与expected receipt replay可走原fault事务。原普通init/migration与CloudLedger required API保持原行为。
- 具体 `replayLocalTransportErasure(_:expectedReceipt:)` 先绑定原requestID UTF8 bytes、原requestDigest、stableZoneKey。单事务复用strictlayout，必须查到原内部receipt且逐字段与expected一致、原fence存在、全inventory严格可归属且目标stablezone所有epoch当前零。缺任一proof/恢复target/malformed/unknown保全并throw；绝不插入receipt/fence或落入fresh erase。返回内部原receipt；原COMMIT丢响应可重开重放。
- 026已有catalog firstreceipt必须选择expected-receipt replay-only，不能用fresh erase重建。尚无firstreceipt时才用既存v4专用opener进行既定first erase。leaf不新增026SQL解释器或泛型协议。

## TDD和验证

1. 先测试公开API编译红，再最小兼容委托产生真实运行红：同inode恢复target并删除原controls、旧v3控制缺失、ordinary enqueue/stage等错误准入。明确upstream026的2tests/6assertions只是原输入反证，不计本任务测试通过。
2. 最小实现RO→RW准入、ordinary write gate及expected replay-only。真实SQLite回归覆盖缺receipt/fence、错expected、重开/原receipt、beforeCommit与COMMITlost、合法foreign原bytes、live unknown/malformed保全，missing/empty/legacy/future/unknown originalfile/schema/inode不改。正常init/migrations由全部原Cloud回归保持。
3. 冻结source后完整Cloud host单轮、四fresh最低 iOS17/watch10 simulator/device SDK产品。每命令inputs before/post、实际计数/原logs/Git source及hash进树外NATIVE-047。root+m2 source双审后只两卡final，随后final再双审，held026不自行晋dev。

无实际CloudKit、账号、签名安装或设备操作；本任务数据库控制软件与无签名产品编译不证明真实SDK/掉电/整个owned本地删除。production默认Unavailable不变。
