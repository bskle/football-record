# NATIVE-017 本机验证记录

源 `1790722ac99c9346f6279715161349103cde69af`，base/target dev `a5d70759b1ff7c67b92f2082244fd189c119418d`。作者本机自验完成；root质量与m2_review规格两位非作者已对该源/目标 PASS，最终文档和实际merge检查由root记录。

## 实现与回归

- 同 facade 的公开 AppComposition 返回 repository、具体 MatchSession、MatchSyncService 和 model；普通 import（非@testable）的两项测试证明外部可见与 identity 一致。production 强制 unavailable trust/permit；真实设备模块不在 App 依赖中。
- SyncStatusProjection 分开本机保存、未路由/待持久ACK/缺口/已确认、错误、云未接通、后台待终结。0/0/nil 不是对端已保存；typed unavailable 清掉旧 ACK 结论与计数。同步状态不改变合法本机记录或 feedbackCount。
- 两个真正隔离 SQLite/持久 identity fixture 先仅传输 callback 成功仍pending，再以真实 Session/Store收包和ACK收敛；重开身份不变，身份丢失且已有记录时不接管。真实 SQLite 临时不可读后订阅收到 unknown，修复后经新本机事实/真实ACK恢复。
- 生命周期红绿覆盖：悬挂同步启动不挡本机 recover/记录；shutdown 收束旧启动，晚本机 recover 不重装观察；retry 同match重启、startup A→B→A 的旧成功和旧错误均失效；忽略取消的晚激活须在旧 shutdown join 前补 stop，新生命周期仍可正常激活。
- UI retry 仅恢复 Debug 传输并 wake，不改 Session wallclock 或持久退避预算；host 显式注入的同步 clock 与交互 UI 分开。

## 实际命令与分层

所有列出的验证命令均 exit0；红测失败按预期单独保存。不能将不同源层的数量相加为一次最终运行。

| 范围 | 结果 | 日志（相对源证据目录） |
|---|---|---|
| 完整 `NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE017-build bash scripts/native/verify.sh` | 251 XCTest=44 Core+106 Store+46 Session+17 Sync+38 Presentation；8最低SDK产品；2无签名Simulator App | `logs/verify-final.log`、`logs/20261016T090222Z/` |
| 最后取消/迟到激活守卫后 Presentation 全回归 | 39=原22+2 Composition+15 SyncStatus；0失败 | `logs/presentation-final-incremental.log` |
| 最后守卫后 iOS17/watchOS10 Presentation SDK及双App增量编译 | 2 SDK+2无签名App；均通过 | `logs/final-incremental/` |
| iOS27 / iPhone13 390pt | 完整9项XCUI；194.240秒；本机/对端/错误/重试/重开/终结/旧UI全覆盖 | `ui/20261016T085300Z-iOS/`、`logs/ui-ios-first.log` |
| watchOS27 / Series9 45mm | 完整9项XCUI，含四快记/撤销/反馈边界/新同步状态 | `ui/20261016T085705Z-Watch/`、`logs/ui-watch-first.log` |
| iOS27 / mini375pt，dark+最大DynamicType | 既有同步/错误/重试/后台终结用例1项；57.443秒 | `ui/20261016T090342Z-iOS/`、`logs/ui-mini-dark-max.log` |

完整251的时间点在最后“忽略取消晚激活”修复之前；最后源只改生命周期守卫及相关回归，并重验39 Presentation、两最低SDK和双App。其余213核心测试及六核心SDK产品的输入未变，证据属于前述完整运行；不得称一次最终252。root的实际merge全量会产生新的单轮证据。

iOS9和Watch9均在最后 startup 观察generation/取消守卫之前；真实编译输入58项已保存在 `ui-before-startup-generation-guard/inputs/`。与最终源的App/UI输入差异仅 `SyncStatusModel.swift` 的生命周期守卫，无布局/交互delta。375pt定点已包含观察generation守卫、尚未包含最后取消守卫。不能写为最终源一次全19项UI；root实际merge按既定定点复验。

## 模拟器、截图与边界

从本次实际 simctl 清单核验：

- 390pt：`3094D821-E635-477D-B735-3B6F85039A24`，iOS27。
- 45mm：`9E47C372-0445-4B7D-9280-01FA43DDC981`，watchOS27。
- 375pt：`BCF44456-964D-40C7-B810-AE9C369C1CDD`，iOS27；定点 `content_size=accessibility-extra-extra-extra-large`、dark，结束后恢复原 large/dark。

`visual-ios-390pt/` 有42个文件、`visual-watch-45mm/`48个、`visual-ios-375pt-dark-max/`8个，共49张本轮截图及49份可达性文本；完整清单 `visual-inventory.json`。作者目视了两端pending/ACK/terminal与375pt大字错误/后台状态：可滚动访问，长文换行，没有把缺失运动值或云状态伪装为成功。自动属性与截图不等于真人VoiceOver朗读或触觉手感。

## 树外证据

固定目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-017/source-1790722/`。

源 manifest 180项完整Git blob输入、672项证据，SHA256 `de707f9cb9833093101dbd87a0a6ec1076828f217665dfae55d62a2af99d0e31`。`manifest.json`逐项记录模式/Git blob/SHA256/大小；`result.json`列出命令exit与分层，含UI前58输入和最终delta。各xcresult与导出原manifest均保留，命名截图另外保存；不依赖树内ignored构建产物。早期中间失败日志也保留，正式红绿以result中的边界用例及最终39绿测为准。

`git diff --check`、pbxproj plutil lint与Core包相对base无差异均通过。无真实WatchConnectivity、签名/安装/授权/GPS/后台/锁屏/真人恢复/最低系统运行证据；无设备能力新增，真机不适用本任务合入范围。生产provider及M4许可/云/后台未接通；普通结束 endedPendingSync，对端ACK不完成比赛或释放后台锁。不推进release/main，不发布。
