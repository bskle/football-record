# NATIVE-050 validation

依据 [任务卡](../tasks/NATIVE-050.md) 与 [计划](../../superpowers/plans/2026-10-20-m4-session-registration-retirement.md)。source `60b78241ba20dbc91cdea50280f3db5d6d33b8ce` 已root+m2双审PASS，当前仅两卡final待窄审，不预填合入。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-050`。`source-aggregate-manifest.json` SHA256 `d9b083292cecd5420117ff470788853103ac9924e583fb725f6129885549e752`，绑定40原证据、6Git对象、6owned文件、242保守runtime输入、3命令before/post/Git bytes-mode-blob-working零差和6本地链接。

- 稳定runtime RED为`runtime-canonical-red.log`：8项/76失败/0unexpected；原两协调器与测试copy按该轮inputs哈希保存。修后同8/0。历史`runtime-red.log`仅actor URL读取编译诊断；`runtime-behavior-red.log`为早期夹具8/10/5unexpected（独立RO快照遇missing-WAL、重造签名而非保留firstbytes），单独保留，不充作稳定产品红。最终快照和真实失败trigger均经原MatchStore actor/同连接，无造业务行掩盖诊断。
- 新8项循环覆盖五mutation及Phone nil-binding/Watch首次binding：退役后entry零SQL；原namespace读取与实际authority mutex排队跨gate后零写；每类真实COMMIT后hold reply，退役必须join，原canonical事实close/reopen不变。实际SQLite RAISE(ABORT)失败和COMMIT后responseLost均保留原caller错误，不替换成retired，不重复SQL/HTTP。active原写、identity generation CAS及terminal Auth/knownAbandoned closure、原reauth-ID/capability Saga/control仍可用。每夹具只有同一原SQLite facade和具体Session，proxy只延迟原回复/转发原identity，不替代coordinator。
- source fresh完整 `swift test --package-path native/Packages/MatchCore` 单命令276/0：44Core+149Store+66Session+17Sync（原Session58+新8），不与focused累计。source-core-host.log SHA256 `27b681940c56db5e14f7530b40e2fa66a60c8ea10f0c80c81f2bb18f5ea42cba`。
- 两fresh `xcrun swift build --target MatchSession` 最低arm64 iOS17/watch10 simulator产品均exit0/Build complete；实际argv、scratch、SDK和log SHA见`source-commands.json`。原LifecycleInboundCoordinator.swift23/33 unused repository警告保留，不改共享控制路径。

source审阅：`review-source-root.json` SHA256 `7ccf816ec973ff1791afcc72d337c1c8f22a1515acc4190ccf12118f96b1d19f`；`review-source-m2.json` SHA256 `b4107b76ddcdcb4c7bdc30e679b25c16be275b2ca6e75d700eeabfa1b88f7752`。两位非作者核原输入、实际日志和五入口/完整await边界，无阻断。本次仅两卡收尾，原产品/测试/计划四路径、40原证据、242输入均不变，不重测；最终SHA及增量清单留树外避免自SHA回写。

真机不适用：本任务只原协调器持久化软件，未执行AccountKit HTTP/service/vault整体路径或真实Apple/CloudKit/Health/WC/Keychain/账号/设备/签名部署，不称whole026。Session计数仅覆盖原SQL await，026必须join整个owned服务任务和vault尾部才可freeze/换factory/关DB。未新增纯post-retire reauth能力，原Saga与已有reauth控制保持；schema/generation/协议、生产默认Unavailable及其他任务成果未改。
