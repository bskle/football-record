# NATIVE-056：账号最终投影检查

状态：本机软件实现与作者验证完成，exact source 已 root+recovery 双审 PASS；本次仅两卡 final 收尾，等待 exact final 双审及 root 接入 held026。不称 M4 完成。

## 登记与所有权

- 唯一作者 `/root/m4_presentation_publish`；两位非作者 `/root`、`/root/m4_recovery_audit`。
- original/effective base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；plan-only `d3bc96fd510c775934e1b6ec0cfcd1012806f585`；source `ee3e4fc469074f21e819c27421e9af740bd2b62e`。
- branch `fix/m4-account-final-publish`；tree `/Users/liam/.codex/worktrees/m4-account-final-publish/20260830_足球记录`；attachment `01a16197-99bc-71f0-9989-31f43c8d06d6`；creation operation `da2132a5-a435-4986-86f8-7e11836caea2`。写入前后均核实际 HEAD/分支与 clean（含 ignored）。
- 唯一五路径见 [实施计划](../../superpowers/plans/2026-10-22-m4-account-final-publish.md)：原 AccountStatusModel、原 AccountStatusTests、计划、本卡及 [验证卡](../validation/NATIVE-056.md)。产品提交仅前两路径 +143/-2，plan/cards当时不变；final只两卡。没有其他树、Apps/026、依赖包、工程、Package或脚本写入。
- target 仅 held026 `test/m4-e2e-integration`，登记 target `d155eaaeee02384187966f835d85ce94f079c983`；root 接入前重核实际 target。作者不 merge/push/archive，不推进 dev/release/main。

## 交付接口与边界

`try await account.admitIdentity(binding, expectedIdentityGeneration: generation, finalCheck: { ... })` 增加 nonescaping 同步 MainActor throwing veto。原持久 read/generation/binding UTF8 比较与 model token/stopped 检查全部保留；全部 await 完成后，先执行附加否决，再同步重核原 token/stopped，最后无 await 地发布 checkedIdentity/identityVerified 与 apply。

同步 callback 调用 pauseIdentity、stop 或 requireReload 都会让原发布失效；throw 沿原 throws 传播，不能留下本次 ready。原公开无 callback 方法和 internal read seam 源码兼容，旧方法使用 no-op 附加检查。passing veto 不绕过原 pending/waiting/production unavailable、reload/stop gates，也不授予身份认证或录制 authority。

026 自己负责原 service 身份 admission、最后独立当前身份观察、完整 current tuple、原资源 owner/pair seal 与真实 credential TTL/key tuple。本接口只提供最终同步发布检查点，不提供 external identity/SQLite/vault 全局原子或未来有效期 lease。026 尚未在本任务中消费新接口；root 实际接入和相关复验后另行放行。

## 实际验证与审阅

- 固定 source 单轮 fresh MatchPresentation host **79 tests / 0 failures**；targeted AccountStatusTests 16/0 已包含其中，不叠加。
- 四项最低 SDK MatchPresentation 产品编译均 exit0：iOS17 simulator/device、watchOS10 simulator/device。实际工具 Xcode **27.1**（27A9275）、Apple Swift **6.4**；SDK 编译不代表已连接、安装或签名设备。
- 164 runtime inputs 的 mode/blob/SHA256/bytes、直接输入副本与上述五命令 before/after/current/Git 一致，0漂移。原 API 基线与三种失败诊断独立保留，见验证卡。
- root whole source PASS：`whole-source-review-root-ee3e4fc.json` SHA256 `4b6c3a077b1afdfb1c1642408f4d71d543d172ae2d8c178fbfd119828807c14d`。
- recovery whole source PASS：`source-review-recovery-ee3e4fc.json` SHA256 `8c4d42209c3ded5719113bdb4330ae6b9181cf627ef8c1f1a25c64413f98af0f`。两者无 findings；作者不计入双审。

树外交付目录 `E/NATIVE-056`，`E=/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation`。source checkpoint `source-checkpoint-ee3e4fc.json` SHA256 `713b3c719f06ebcf61c23612f10a71ebdb183b5b2ea5577b1a7728d561da9cc9`，164-input manifest与3338-file author evidence manifest均保留。final SHA与两卡增量/输入不变证据只记树外，避免回写自 SHA。

真机不适用：本任务仅改本地查询投影的同步否决接缝。未跑其他包 host、App/XCUI、真实 Apple/iCloud/CloudKit/Health/WC、签名安装、设备或部署；生产 provider 与整包验收不由本次通过证明。现存 Core 两处 unused-binding warning 原 bytes 等 base，未跨所有权修复。
