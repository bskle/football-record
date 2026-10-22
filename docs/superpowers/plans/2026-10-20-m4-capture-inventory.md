# NATIVE-046 — 原 Store 完整采集枚举

原 base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，普通合入已双审045 final `acd5ab1717fc5eb979c1f13cba083c36c06a8c55` 后 effective base `c75c0c7442f0145142d49cd90db5ec81ecd0496c`。作者 `/root/m2_review`，非作者审阅 root + cloud；独立分支 `fix/m4-capture-inventory`，仅供026 held候选。

现有 matchIDs 只从 matches 发现父行，逐场 snapshot 的反向 registry/history 校验不能发现未知 orphan。新增 concrete `MatchStore.captureInventoryV4()` 与原 `SQLiteSessionRepository` 转发，返回最小 Sendable、非 Codable、internal-init `CaptureInventoryMatchV4`（binding、完整 captureRevisions、所有状态 captureOperations）；内部重验全部历史，不复制 business snapshot，也不是可长期缓存的删除授权。

## 实施与真实 TDD

1. 提交本计划与两卡后，先记录 API 编译红。用真实 Session/原 SQLite 生成 linked canonical facts，再只删 matches 父行；证明原查询遗漏，最小枚举实现实际运行红。原证据保留。
2. 同一原 Store 无 await SQL 事务复用045精确布局 admission、原 loadSnapshot/loadCaptureRevisions/loadOperations、command/outbox 校验。全库 raw UTF8 集合核每个 operation/revision 的父、history 所属 operation、已知五种 registry 与原 metadata 闭包；未知 kind/孤儿/缺事实/损坏/任何 blocking diagnostic 均明确 throw，不跳过或假空。
3. 所有文本归属按原 UTF8 bytes；共享 metadata 同 ID 同 bytes 可重复引用，异 bytes 拒绝。原 command/outbox 尚存但 canonical capture/registry 同时缺失也不能漏过。失败只映射已有 typed StoreError，不新增 diagnostic 或修复原件。
4. 覆盖所有状态/历史/异常/非当前UI/空 intent、原 wrapper、重开、raw Unicode、未知/未来布局与只读保全；完整 Core host、两 fresh 最低 iOS17/watch10 Session sim SDK，固定 before/post Git输入。编译不等于真实SDK操作，无本人账号/设备调用。

## 所有权与使用边界

仅 CapturePersistence.swift、SQLite.swift（只复用045只读布局 helper，不改 schema/迁移/decoder）、SessionDependencies.swift、新 CaptureInventoryTests.swift、本计划/任务卡/验证卡七路径。不改 generic protocol、Package、工程、SDK或026/045旧树，不自行合并/推送/归档，不覆盖其他作者成果。

026必须先成功排空原 Session 及所有 owned 写入者，再比较当前完整投影与原041 raw；晚到 linked 或原范围变化挡 first erase。Store 已擦后只能沿原 retained mapping 与045 current-zero 恢复，空 inventory 不能重建空选择。本接口不证明 HK source、remote/multi-Store provenance、永久零或跨叶节点原子。source/final 均须 root + cloud 双审。
