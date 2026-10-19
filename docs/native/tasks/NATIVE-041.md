# NATIVE-041 retained Health artifacts

状态：独立 held026 实现中，未验收、未合入长期分支。作者 m4_cloud，审阅 root+m2。

原base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，已双审039依赖 `7547c048b8f8f640e920d17ffc1e09b6c4f335a3` 普通合入得到初始 `dadb60ee7fc366c5b7d8c754855b126384093e7a`。树 `/Users/liam/.codex/worktrees/m4-health-artifact-store/20260830_足球记录`，branch `feat/m4-health-artifact-store`，attachment `01a15653-597c-7211-92d9-23196ca76f55`，created1792449665；作者已核 HEAD/branch/clean。登记target held026 `27e83a50dcb0c08f7c5b3688e6fb86d5c9045b60`。

唯一五路径为新 retained store、新同名测试、本卡、[验证卡](../validation/NATIVE-041.md)、[具体计划](../../superpowers/plans/2026-10-20-m4-health-artifact-store.md)。不改Package/工程或039/040/026 catalog，不派代理，不merge/push/archive。

目标是实现039五函数：原 raw/prepared canonical bytes 与 digest 在独立 retained SQLite 保存；full seal 仅由026注入provider读回。固定单体16MiB/单parent32MiB/64parents/128rows/总256MiB/owner64KiB，所有写入预算在事务前置校验。原owner/DB/父链及原namespace/scope不可重置，目录在所有可删根之外；未来/损坏/未知保留失败。实际验证结果待日志完成后填写，不把依赖53/0+4SDK算作041运行。
