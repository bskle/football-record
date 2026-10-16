# NATIVE-009 原生记录 UI 验证

作者 `/root/m2_recording_ui`；创建base为已验证dev `0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`。任务分支 `feat/native-recording-ui`，目标dev。主代理把已验证011组合 `f26d60de81fb5afa90e2f16044a09675d71ee834` 普通合入本树，最终冻结源码为 `117c4c42744a96fd5fa695671accee7a843d08df`；009产品/UITest此前冻结于 `86203bfe77553d1df41ea575b9264ee4158a7ecb`。主代理确认117源码根审及规格增量审均PASS；最终文档审阅与主代理集成待决，本文不宣称已合并或推送。

## 最终组合实跑

以下完整组合均对冻结117源码执行，三个命令exit0；73项编译/测试输入在执行前后逐文件SHA256比对无变化。

| 验证 | 实际结果 |
|---|---|
| Core / Store / Session宿主 | 144 XCTest零失败：44 Core + 64 Store + 36 Session |
| MatchPresentation宿主 | 14 XCTest零失败；真实临时SQLite、稳定请求重试及故障注入 |
| 最低部署SDK | Store / Session / Presentation各iOS17 + watch10，六项显式Simulator SDK构建通过 |
| 双App | iPhone / Watch无签名Simulator构建通过，新增源文件实际编译 |
| 45mm Series9 / watchOS27 | 完整七项XCUI零失败，120.65秒；实际launch/tap/swipe及已保存显示效果 |
| 390pt iPhone13 / iOS27 | 完整七项XCUI零失败，144.88秒；含最大辅助字号、四tabs及长结束状态 |
| 375pt iPhone13 mini / iOS27，深色、最大辅助字号 | 保留此前稳定布局定点绿：比分57.3pt、双clock69.3pt单行且屏宽内；结束“已结束 / 待同步”116.7pt两行，场下独立。011未改布局，按主代理安排未重复矩阵 |

组合脚本：`NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE009/verify-combined-117 scripts/native/verify.sh`。实际stage目录 `logs/20261016T035121Z/`。

两端实际交互：`NATIVE_UI_BUILD_ROOT=/tmp/football-record-NATIVE009/ui-combined-117 scripts/native/ui-test.sh Watch 9E47C372-0445-4B7D-9280-01FA43DDC981`，随后同一脚本 `iOS 3094D821-E635-477D-B735-3B6F85039A24`。实际目录分别为 `20261016T035129Z-Watch/`、`20261016T035421Z-iOS/`。脚本失败返回非零，成功导出xcresult附件；不创建/重配/删除设备。

## 持久证据与截图

根目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-009/`。

最终组合在 `final-117c4c4/`：`inputs-117c4c4.json`记录完整源码/tree、依赖与73项输入，文件SHA256为 `e0b987698320966e07c1920397bc1e908dd1b5348253c630fc4ceb89f8fa01f9`；`environment-117c4c4.json`记录工具链/runtime/设备/scheme；`host-sdk-apps/`保留完整阶段日志；`Watch/acceptance.xcresult`、`iOS/acceptance.xcresult`及各自`attachments/manifest.json`保留测试结果、截图和AX树。`evidence-index.json`关联source、结果及所有截图；`evidence-sha256.json`保存证据文件hash。文档后续提交不改变这些编译/测试输入。

最终截图路径以下均相对上述根目录：

| 内容 | PNG |
|---|---|
| 45mm主页，双clock/缺失采集/控制 | `final-117c4c4/Watch/attachments/ACA61E9D-4C40-4E05-9A37-575C19218118.png` |
| 45mm四快记/个人统计/撤销 | `final-117c4c4/Watch/attachments/52B99090-3170-48DA-B29C-9FBDD7BF2D31.png` |
| 390pt正常主页 | `final-117c4c4/iOS/attachments/57D98083-8387-4214-B323-57437A1B7E3F.png` |
| 390pt最大字号结束状态 | `final-117c4c4/iOS/attachments/A9A0997B-1653-4EF9-8393-BFAEA493B938.png` |
| 375pt深色最大字号比分/双clock | `phone-375-status-green2-attachments/D00E2CD4-7B43-4090-A6BF-EA643080B00C.png` |
| 375pt深色最大字号结束长状态 | `phone-375-status-green2-attachments/120B0779-5C1B-46F2-83A1-4088954870EA.png` |

主代理已对冻结布局的45mm两页、390pt正常主页、375pt深色最大字号比分/clock和长终态做实际视觉检查并确认PASS。该结论对应稳定布局：原45mm图 `watch-fourth-attachments/6A978213-5E4F-4AA5-BDB9-6364711B642D.png`、`watch-fourth-attachments/D678BCCC-E07C-4B93-A991-A7DB76ABBCE7.png`；原390pt图 `historical-rounds/phone-390-d9230cf/attachments/802DC641-BAC9-409A-8D46-B3D96C1DC80C.png`；375pt为上表两图。作者另实际查看最终117的Watch两页和390pt正常/结束图，布局一致。

## 回归与边界

Watch两页横滑，四快记与撤销完整触控区均至少44×44pt且避开页指示器，实际AX四按钮91×45pt、撤销44×44pt。快记测试逐次核对“我进球/我助攻/进球/失球”精确标签、比分和个人统计；1000ms跨按钮guard保留原值，撤销必须真实消失后立即纠正。只确认hittable不等于点击有效；测试还要求完整frame进入可用视口与提交后显示变化。Watch系统确认按实际53pt AX Cell点击。首发/替补选择取消不创建match，首发确认自动场上、替补场下；暂停/继续、bench、结束取消与结束待同步均真实操作。

Presentation的14项回归覆盖事实派生暂停/bench双时钟、结束待同步、缺失不是零、首发选择取消、首次保存失败、响应丢失保留原完整请求、明确stale且查无提交才新command、重建后debounced清pending、已到达的新generation不被失败旧快照覆盖、错误设备只读、正式许可不可用不造第二意图、gateway注入不能绕开许可、采集缺口可见。成功触觉仅在首次确认receipt后触发，物理手感未验。

Debug测试入口显式隔离dataset、canonical namespace、实际SQLite及持续“开发模拟锁”，没有随机Workout UUID、健康样本或假peer。错误设备/采集缺口来自真实独立事实；多候选/身份/诊断UI错误是明确展示fixture，服务实际判定由Session回归验证，不能当真实恢复/采集证据。两App链接UnavailableWorkoutGateway，不连接008；010以后才能按设备门禁装配适配器。生产许可M4前明确不可用，无静默fixture降级。

真实HealthKit、定位、后台、锁屏、Workout恢复、系统授权、跨设备传输和生产锁均未接入本任务。最低iOS17/watch10仅编译，实际UI只证明已安装iOS27/watchOS27 runtime。VoiceOver仅检查AX文本、语义及触控区，未执行真实朗读；触觉手感及真机设备能力未验。纯UI任务的真实采集验收不适用，不冒称设备通过。

## 历史轮次与资源交接

ee0750f组合当时145项（131+14）、六SDK、双App通过；390pt的d9230cf整轮七项绿，以及375pt比分/clock/长终态的实际红绿均保留原来源。ee0750f Watch最初六绿一红是系统确认查询失败，改用实际AX Cell后定点绿；最终117完整七项已覆盖该修复。早期仅hittable的探索绿不作为最终效果证据。历史完整结果在`historical-rounds/`，原日志及红绿证据保留，不把旧轮次改称新SHA通过。

本任务自有三个Simulator保留供010串行接手：45mm Watch `9E47C372-0445-4B7D-9280-01FA43DDC981`、390pt iPhone13 `3094D821-E635-477D-B735-3B6F85039A24`、375pt mini `BCF44456-964D-40C7-B810-AE9C369C1CDD`。资源类型/runtime/状态见`simulator-resources.json`与最终环境记录；375pt任务设备为深色。未改用户既有配对、未下载runtime、未删除设备，不随Git工作树清理删除这些活跃依赖资源。

作者仅写本任务所有权路径，未自行合并长期分支、推送、归档或删除分支；最终文档与证据交主代理独立审阅集成。
