# NATIVE-018 本机验证

源码 `72846583e503349d117dac84e42fde746d384fee`，审阅目标 `b0070c90d91bf9d7741b7a7ed24165f1ad27383d`。root质量、m2规格双审 PASS；任务登记/依赖merge边界见[小计划](../../superpowers/plans/2026-10-16-m3-device-integration.md)。本机可审整包不代表物理验收或进入长期分支。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-018`；独占构建根 `/tmp/football-record-NATIVE018-build`。`source-7284658/manifest.json`：163输入（152 native/scripts构建输入+11治理/需求/任务文档），3380证据，SHA256 `2ac89a14488cfd402f61ebe24a239d56a2d2fbd4aa941188298db379d4438f5c`；每输入有Git blob、SHA256及原字节。`final-run-inputs.json`锁定actual728的152构建输入，`command-results.json`逐命令exit，`ui-screenshots.json`索引127张命名图/AX。最终三docs提交由树外final manifest绑定，不改冻结产品。 输入的 `inputs[].path` 以 `source-7284658/inputs/` 为基准；证据的 `evidence[].path` 以 NATIVE-018 任务证据根为基准（共用 `evidence/` 与顶层JSON），不是source子目录。

## 实际完整矩阵

`NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE018-build scripts/native/verify.sh`，actual728 / clean，exit0。日志 `evidence/logs/final-verify.log` 与 `evidence/logs/20261016T100915Z/`。

| 宿主测试 | 实际通过 |
| --- | ---: |
| MatchCore | 44 |
| MatchStore | 106 |
| MatchSession | 46 |
| MatchSync | 17 |
| MatchPresentation | 39 |
| WorkoutCapture | 40 |
| DeviceSync | 21 |
| AppIntegration | 18 |
| 同一完整命令合计 | 331 |

同轮14项最低SDK产品：Store/Session/Sync/Presentation/WorkoutCapture/DeviceSync/AppIntegration各iOS17与watchOS10 simulator triple；2个generic Simulator App unsigned构建成功。Xcode27.0（27A266a）/ Swift6.4；最低系统仅编译，未运行。

`verify-device-candidate.sh` exit0，`evidence/device/20261016T100537Z/candidate-inspection.json`核2个genericdevice unsigned App、最低17/10、HealthKit配置、定位/运动说明、后台模式、bundle关系与无profile。构建在7215检查点前、019测试-only依赖前；这些App/runtime字节与actual728相同。未验证真实签名entitlements、安装、授权或设备能力。

## UI输入与分层

仅复用既有任务Simulator：iPhone13/390pt iOS27 `3094D821-E635-477D-B735-3B6F85039A24`；Series9/45mm watchOS27 `9E47C372-0445-4B7D-9280-01FA43DDC981`。375pt设备本轮仅核清单，未再运行；未删除设备、配对或下载runtime。Simulator ad-hoc signing保留，genericdevice仍unsigned。

| 运行目录（均在evidence/ui） | 实际结果与输入范围 |
| --- | --- |
| 20261016T095128Z-iOS | 两类13项，12过/1新case重复status查询失败；9 Recording与原3 Integration过 |
| 20261016T095652Z-iOS | firstMatch仅修新case查询后，环境往返/稳定UUID/fresh可用model 1/0；App/runtime无变化 |
| 20261016T095751Z-Watch | 两类13项，12过/1旧滚动helper停长页顶端失败；原视频/AX及末帧保留，9 Recording过 |
| 20261016T100426Z-Watch | 只修Watch XCTest小幅有界drag/零frame判断，新增环境case 1/0；真实滚到UUID、实际按钮可点及往返断言保留 |
| 20261016T100919Z-Watch | actual728，最终NativeIntegrationUITests整类4/0，覆盖通用helper影响的旧3与新增1 |

`ui-query-delta.json`、`watch-helper-delta.json`记录测试输入hash；无App/runtime差异。最终覆盖为iOS 9+3+1分层、Watch旧9+最终4分层，未声称任何一端最终同轮13/0。各xcresult、命名截图/AX、失败录屏和log均保存。Phone新环境UUID页和入口、Watch实际UUID两行与ready入口已由作者及root目视；自动AX/hittability和feedbackCount验证不等于真人VoiceOver或实际触觉。当前回归涵盖本机保存、未路由/待ACK/重试/对端确认、后台待终结、重开/只读与错误不伪反馈。

## 红绿与限制

- 注册挂起并发start/retry/observe实红3次→绿1次；唯一listener与stop/join回归保留。
- activation挂起的失效事件实红1秒有界超时→owned工作不堵observer，trace先invalidate再stop，含start挂起/迟到activation收束。
- 传输factory真实throw时，同SQLite旧比赛仍恢复、合法本地提交成功，未知ACK不被当成功；两隔离SQLite/稳定UUID经过实际WCSessionTransport+受控driver验证业务ACK及失效锁存，对端不伪本机反馈，ACK不解锁。
- 初次全量 `evidence/logs/full-verify.log` exit1，因继承WorkoutCapture FaultRepository缺16转发；独立019双审后由root普通merge解决。作者未修改禁写模块；最终331是actual728一次全量，不是旧数相加。

生产trust/start permit、Apple登录、CloudKit和正式开赛/解锁服务未接通。Debug account/pair/epoch是显式开发标签；未配/身份变化/配对变化/失效时fail closed，不删文件或换epoch绕过。普通结束仍endedPendingSync。

真机签名安装、HK/定位授权、GPS、后台/锁屏/系统恢复、真实WC reachable/file/离线补传/去重/丢ACK/重启/换Watch、真人VoiceOver/触觉与最低OS运行继续延期。Simulator不支持真实transferFile，受控driver不代表真实通信或生产E2E。008/010/016/018保留物理依赖，不合dev/release/main、不发布；019已由root实际安全归档并branch -d删除。
