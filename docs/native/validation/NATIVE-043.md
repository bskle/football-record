# NATIVE-043 验证

source `83508a49e912dc1395b1f84a251b6e509e2c6227` 已root+m2双非作者审PASS，held026；final仅两卡，复用同源验证，不重测。见 [任务卡](../tasks/NATIVE-043.md) 与 [计划](../../superpowers/plans/2026-10-20-m4-debug-protocol-clients.md)。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-043`。`source-aggregate-manifest-v2.json` SHA `f1ada0b95574a67ec6d27ac992a38a21532ea5d10b322ae8e8339cf4aecc139b`；100 evidence、4Git、5owned、239runtime、9commands、15consumer模块文件与6本地链接已核。

| 实际层次 | 结果 |
|---|---|
| 原API编译红/原lifecycle运行红绿 | 缺API红；4tests/7预期断言红→4/0，分别保留 |
| typed协议扩展/辅助失败 | HTTP fixture端口read挂起有sample及只终止自有Python child证据；改bounded poll/read后11/0，非产品RED |
| 只读drain门控 | 缺drain API编译红；临时目录URL别名辅助断言单独保留；相对路径清单后2tests/5预期断言红→13/0 |
| published inventory身份 | root/child挪走后换空目录或缺失四变体，1test/8预期断言红→14/0，原pending bytes保留 |
| 新source完整宿主 | 一次fresh Presentation 88/0，0unexpected；logSHA `366e6da6bcbc60fa418d60cff563f824625c900c9230c008aa739bf4a8844353` |
| 最低产品 | iOS17/watch10 simulator各Debug/Release，共4fresh Cloud依赖内Presentation产品，均exit0 |
| public API隔离 | 普通import consumer不使用@testable，两端Debug exit0；两端Release exit1仅缺DEBUG类型，非构建故障 |

`S43-inventory/source-commands.json`保留9实际argv/SDK路径/logSHA和逐命令239inputs before/post0。原39e的87/0+4SDK作为历史输入层保留且hash未变。新source logs仅原LifecycleInboundCoordinator:23/33 unused repository警告和原NATIVE-035控制注入诊断；v1 notes误称capture警告已用独立correction/v2纠正，不覆盖原证据。

source review：root `review-source-root.json` SHA `ee9b223ce908e05bceb7130621c28e6e2495ece0d35008aedca3dde212948404`；m2 `review-source-m2.json` SHA `aed32b3419b74421567e7e60f2a8c0848ce97be0ad98f3f10eb9085f6ccb4ec0`。两者均限typed held026组件。final仍待同HEAD窄审，不预填已合并。

无App/Package/工程改动或新App调用；模块与public consumer编译为本任务相应边界。没有真实Apple/CloudKit/Health/WC、账号/签名/安装/本人设备/部署执行。drain只是点时原四目录+本实例调用状态，026需先gate所有业务写者；不证明持久跨进程ownership、原生SDK排空或全部owned删除。finalclose不能代替业务quiesce，原Saga客户端须保留到最终关闭。
