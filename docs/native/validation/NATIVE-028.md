# NATIVE-028 验证记录

日期：2026-10-19，上海。候选仍在实现，尚未双审，未做真实 HealthKit 操作。

完整 base / 登记目标：`204ea7a8c2b0d6f514fc6d4653aec9b6379a2a15`。作者树 `feat/m4-healthkit-deletion`，attachment `01a14ff9-ea8d-7db2-9b92-43f615b27a92`。

树外证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-028`。开工六项 Git 输入、Xcode/Swift 版本及原始日志均在该目录。

| 切片 | 实际证据 |
|---|---|
| 请求模型 runtime 红 | `028-1-models-red.log`，2 tests / 13 assertions，缺校验与摘要实际失败 |
| 文件台账 runtime 红 | `028-1-ledger-red.log`，8 tests / 9 failures，确认/持久化/owner/坏库保护未实现实际失败；不是编译错误 |
| 第一切片绿 | `028-1-ledger-green.log`，`swift test --package-path native/Modules/HealthKitDeletion --scratch-path /private/tmp/football-m4-028-host --filter HealthDeletionLedgerTests`，8/8、0 failures、exit0 |

第一切片覆盖完整范围摘要、metadata原值、非空/重复/坏ID/时间拒绝、独立Health确认、原请求重开、普通业务目录擦除后控制事实保留、独占owner、COMMIT前回滚/后失响应及未来版本/损坏文件保留。此轮不包含后续服务、predicate或SDK编译证据，不与历史App或其他模块测试累加。

未验：SDK执行、实际 Phone/Watch source、签名/entitlements、HealthKit权限与本人明确确认后的对象删除。默认SDK执行关闭，无App接线；设备敏感候选保留独立树待026，不提前合dev。
