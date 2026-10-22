# NATIVE-046 验证

source `5c6098ac119e8373aef323256c536f904f74c336` 已root+cloud双非作者exact PASS，held026；final仅本卡与[任务卡](../tasks/NATIVE-046.md)，产品/测试/[计划](../../superpowers/plans/2026-10-20-m4-capture-inventory.md)保持source bytes，无最终重测或已合入声明。

## 实际红绿

| 层次 | 原证据与结论 |
|---|---|
| 初稿编译诊断 | `api-red.log` 包含测试夹具API调用错误及缺inventory API；不是运行红。纠正夹具后 `api-compiler-red.log` 实际仅缺API及依赖其类型推断的编译红 |
| 原枚举运行反例 | `runtime-red.log` 以最小旧matchIDs+逐snapshot投影执行 **12项30失败、0unexpected**；包含真实Session生成完整linked canonical后只删matches父行，原matchIDs遗漏且其他正常snapshot成功 |
| 首次完整闭包 | `focused-green-attempt.log` **12/0**，属于中间source |
| raw关联边界 | `raw-binding-red.log` **15项2失败、0unexpected**，原intent与operation associated-command的NFC/NFD原bytes不得被Swift等价比较串接；最小修后 `focused-green-final.log` **15/0** |
| 中间语法错误 | `focused-green.log` 为新helper的throwing表达式编译错误，单独保留；不当通过或运行反例 |

15新增项覆盖全部operation状态、祖先与相同metadata复用、terminal/abnormal/空intent、孤儿history/operation/revision/registry、未知kind与extra segment/gap、原command/outbox缺事实、孤儿blocking/非法diagnostic、checksum/canonical/raw绑定、未知/未来布局保全、非法UTF8、原wrapper/写fault只读及冻结v1迁移。读取失败前后所有表内容/原bytes保持，不新增diagnostic；原红绿源码副本和输入均保留。

## exact source 完整相关验证

`native-validation/NATIVE-046/source-aggregate-manifest.json` SHA256 `d5e491148a5a060a8c3f336b59a423698c9da0299d5e466c0e340de59a05bdf4` 绑定69证据、5Git、七allowed/六changed、240runtime及4本地链接。`source-commands.json` 记三个真实argv/exit/logSHA；每命令before/post0且与source Git bytes/mode/blob吻合。

| 命令 | 实际结果 |
|---|---|
| 完整 `swift test --package-path native/Packages/MatchCore` | 单命令四executable **286/0** =44 Core+178 Store+47 Session+17 Sync |
| MatchSession arm64-apple-ios17.0-simulator | fresh，exit0/Build complete |
| MatchSession arm64-apple-watchos10.0-simulator | fresh，exit0/Build complete |

178 Store=原163+新15；本基线不含042新增Session测试，不相加成历史整包数。保留原LifecycleInboundCoordinator:23/33 unused repository警告，不称零诊断。最低SDK只编译，未启动Simulator或实际SDK/provider/账号/Health/WC/设备操作。

source review：root `review-source-root.json` SHA256 `097820fc503394b0d985dacb48399aea09483194fe1e3ec64bd8fc7ea411b75c`；cloud `review-source-cloud.json` SHA256 `0847891040c475ad0ef2af683ffd9c231eda0ae82ba83fd5a081b916a69575fa`。final aggregate独立核两卡与原69证据/240runtime及产品测试计划零差异，不覆盖source清单。

只表示原Store一次SQL快照；026须先成功drain原Session和全部owned写入者，再比原raw/fullseal。多Store/remote无原provenance仍unsupported；Store已擦后本API为空不补回历史Health选择，需原保留mapping与045current-zero。无新canonical domain/receipt、通用protocol/存储/SDK或业务写；未证明永久零、跨叶原子或全部owned擦除，held026及真实环境门槛保留。
