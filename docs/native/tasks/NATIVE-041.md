# NATIVE-041 retained Health artifacts

状态：本机软件 source 已 root+m2 双审 PASS，final 仅两卡收尾后作者 clean 停写，待同 HEAD 最终窄审。仅 held026，不晋 dev/release/main，不代表真实 Health 或026整包验收。

原base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，已双审039依赖 `7547c048b8f8f640e920d17ffc1e09b6c4f335a3` 普通合入得到初始 `dadb60ee7fc366c5b7d8c754855b126384093e7a`。树 `/Users/liam/.codex/worktrees/m4-health-artifact-store/20260830_足球记录`，branch `feat/m4-health-artifact-store`，attachment `01a15653-597c-7211-92d9-23196ca76f55`，created1792449665。登记target held026 `27e83a50dcb0c08f7c5b3688e6fb86d5c9045b60`；后续接受最新026组合由root统筹，不消费未审WIP，不由作者 merge/push/archive。

三个实现提交为 `03e09c40f416af86a3f8fa4471f76720e723cf2a`、`a2ffb25c9a31699963b1aaa3c3aa324e61ac5cc5`、source `ff5075d41d29bd9e675bd6327f9208c5d7a956d5`。root与m2 source审均 PASS_SOURCE_HELD_026_ONLY；final 仅本卡与[验证卡](../validation/NATIVE-041.md)，新store、新同名测试和[计划](../../superpowers/plans/2026-10-20-m4-health-artifact-store.md)保持 source 原bytes。五路径所有权不含039/040/026 catalog、Package、工程、SDK或其他模块。

已交付内部 actor `M4RetainedHealthArtifactStore` 实现039五函数：raw/prepared canonical bytes与SHA256在 retained SQLite保存，原parent UTF-8 BLOB为key；prepared只从已存原raw+提供的parentDigest重算自洽，实际saga权威仍由039 parent/checked验证。首bytes不可替换，重开及COMMIT丢响应复用原artifact，不新建业务DB或Session。

原installation/namespace/raw scope、owner/DB/root/父链dev+inode绑定，所有可删根外的真实祖先与casealias检查，非阻塞原owner lifetime lease跨进程排他。完整空候选目录EXCL发布，validated reopen先校身份，再fsync本/父目录并复核；缺原owner/DB、未知文件、替换inode、未来/不支持schema、坏canonical均失败保全，不重置。WAL+FULL先RO完整preflight，关闭RO再核身份，RW无CREATE；允许SQLite重建已知SHM/恢复WAL协调控制，不承诺其bytes/inode恒定。未发布私有候选仅空schema/owner控制，原样保留、不采用或删除，未写业务artifact。

固定每artifact16MiB、每parent合计32MiB、64parents/128rows/总payload256MiB与owner64KiB；写入在同一BEGIN IMMEDIATE内前置验预算，测试预算只能收紧。full seal只委托026只读provider，默认 unavailable；await无SQL事务，返回前复核closed与原owner，不自产seal或verified标记。

实际完整AppIntegration单轮 **83/0**（原53+新30同轮），四fresh最低iOS17/watch10 sim/device产品编译通过，140build/148host/331conservative输入均同Git及运行前后零差异。真实16776833-byte原artifact重开、9个子进程exit86、实际SQLite039/028丢响应/unknown重开、原UUID/confirmation/latecallback已覆盖。所有原红绿及诊断保留，详见验证卡。

026仍须持有完整owned catalog，提供原owner/全部removable roots和受验收full-seal provider，并聚合全部本地删除/保留控制。测试seal是明确controlled fixture，不证明生产catalog已接入；真实Health来源/查询/删除/权限、账号设备、物理掉电与全owned验收未执行。M4未完成。
