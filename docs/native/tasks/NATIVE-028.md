# NATIVE-028：独立 HealthKitDeletion SDK 候选

状态：软件候选自动验证通过，作者交付前停写；待 root + m2 对 exact SHA 双审。设备敏感候选，不合 dev、不推送、不归档。执行冻结 M4 子计划 §13 / 合同 §7.2。

- 作者：`/root/m4_sdk_preflight`；审阅：root + m2，两位非作者 exact SHA 审阅尚待进行。
- 完整 base / 登记目标：`204ea7a8c2b0d6f514fc6d4653aec9b6379a2a15`。
- 临时分支：`feat/m4-healthkit-deletion`；目标仅后续026集成候选，真实验收前不合长期分支。
- worktree：`/Users/liam/.codex/worktrees/m4-healthkit-deletion/20260830_足球记录`。
- attachment：`01a14ff9-ea8d-7db2-9b92-43f615b27a92`；创建时间 `1792343141`；作者开工核对 HEAD 等于 base、工作树 clean。
- 唯一写入范围：新 `native/Modules/HealthKitDeletion/**`、本卡与 `docs/native/validation/NATIVE-028.md`。不写 Core/AccountKit/CloudSync、008/018、Apps/project/scheme/entitlements、脚本或其他文档。027与023另作者并行，不撤销他人成果。

## 交付切片

- [x] 显式范围、canonical domain digest、独立 Health 确认；独立文件 SQLite 控制台账、独占 owner、业务擦除后重开、COMMIT 故障、未来版本/损坏保留。首轮8项 ledger host 测试通过，原红绿见验证卡。
- [x] 回调 driver / 服务：先持久 attempt、未确认零调用、timeout/late/duplicate、重开原 scope、0条和权限分项。
- [x] 当前 App source 与逐目标 UUID/三 metadata 精确 predicate；SDK默认关闭，host只受控 driver。
- [x] 最终单轮26项 host（14 Ledger + 10 Service + 2 Driver）及四个最低 SDK target 编译通过；原始日志无 warning。
- [ ] root + m2 source/final 双审；026真实门槛。作者交接时保持clean，完整HEAD与manifest在树外，不把提交自身SHA写进自身。

## 真实门槛

本任务不访问用户 HealthStore、不查询或删除对象、不请求授权。编译与受控 driver 不代替026的真实 Phone/Watch source、权限、本人明确确认和目标删除验收。控制 ledger 位于业务擦除目录外；026映射 request/selectionDigest/confirmation/本机 scope receipt 到 healthProgress，不推进账号、CloudKit或本地分项。

## 作者交付说明

第一切片 `8d8e8e7e1184968e9511d228bd81dafe4352db61`；第二切片与最终HEAD见树外 `input-manifest.json`。本轮最终验证只针对该模块的12份产品输入，SHA256在 `product-inputs-before-final.json`，不包含023/027或历史App测试。SDK执行默认关闭，无App接线；全部host只用受控driver和本地SQLite。实际 Phone/Watch source、本人明确确认后的SDK删除、sharing权限、签名/entitlements及设备同步后验。未调用用户HealthStore、未读取健康数据、未请求权限、未作真实删除。
