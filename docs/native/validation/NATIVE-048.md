# NATIVE-048 validation

依据 [任务卡](../tasks/NATIVE-048.md) 与 [计划](../../superpowers/plans/2026-10-20-m4-account-context-retirement.md)。source `649338d439c61f7e41b5bdee8948c959af7a4bbf` 已双审PASS，仅两卡final待窄审，不预填merge。

证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-048`。`source-aggregate-manifest.json` SHA256 `efdb085a33fa6c725f125729100b76e9ffd3ce069774b08934f9b50532a1a6e2`，73原证据、5Git对象、5owned文件、242保守runtime输入、9命令before/post零差异、15编译模块artifact与6本地链接。

- TDD分层：`api-red`含缺API和XCTest fixture编译错误；`api-compiler-red`独立缺API；历史名`runtime-red`实际为helper编译诊断。均保留且不计runtime红。`runtime-behavior-red.log`实际7项/14失败/0unexpected；同原SQLite facade/具体Session在真实intent commit或snapshot回复挂起时允许迟到firstpermit/GW，修后focused7/0，补旧trailing-close调用后8/0。
- 新8项覆盖public context早期原Session退役、0 firstpermit/0GW且原intent/command保留、nil原Model→close顺序、并发shared owner join、正向capture持久化再关DB、真实SQL失败无fallback且原owner显式SQL-only retry，以及错facade不执行callback。
- 最终同源完整 `swift test --package-path native/Modules/MatchPresentation` 单轮88/0（原80+新8），不与focused累计。四fresh `xcrun swift build` 产品：arm64 iOS17/watch10 simulator，Debug/Release各两端，均exit0。实际argv/log SHA见`source-commands.json`。
- 四普通import `swiftc -typecheck -swift-version 6` 消费者对相应Debug/Release模块编译通过，覆盖默认App调用、旧checked trailing close及新增owner；未执行消费者代码。原App两处调用未改、默认factory及同facade校验body逐字未变。旧四次默认language-mode消费者警告日志保留，未混入最终9命令；Core原unused repository警告保留。

source双审：`review-source-root.json` SHA256 `1e4976cb54b121a16666f7af2c402f9a1ea18ee4753d268a328da6aadf18bdad`；`review-source-m2.json` SHA256 `c34650ceaf43fb952641dab23da554b528b44ed9afa827231cfab098f3d59bb0`。两位非作者均核输入、原日志、源码与边界，无阻断。本次只两卡收尾，source产品/测试/plan、73原证据、242输入和15modules不变，不重复测试；final exact SHA与增量清单放树外避免自SHA回写。

真机不适用：只本机生命周期软件/查询装配，无真实账号/CloudKit/Health/WC/签名/设备/部署或026全部owned完成声明。nil保留旧行为；owner需先gate原Session、join Model再关资源，不得反调Context。Void结果不是durability proof，失败不自动fallback/retry，实际026 throwing close、持久状态和显式重试仍属integration。026后续负责完整App构建与接线验收。
