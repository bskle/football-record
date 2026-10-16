# NATIVE-009 原生记录 UI 验证

作者 `/root/m2_recording_ui`。创建 base 为已验证 `dev=0676727a6c1b1d25d37e39fbd2f68edbfc8c7905`。任务分支 `feat/native-recording-ui`；本记录不宣称已合并、已推送或真实采集通过。最终组合基线/双审状态由主代理集成前核对。

当前产品源码为 `ee0750f`，后续 `86203bfe77553d1df41ea575b9264ee4158a7ecb` 仅补 Watch 系统确认行测试定位。完整组合复验和最终输入 manifest 正在固化；下表保留每轮实际来源，不把旧轮次改称新 SHA 通过。

| 验证 | 实际结果与来源 |
|---|---|
| Core / Store / Session 宿主 | ee0750f 下 131 XCTest：44 Core + 55 Store + 32 Session，零失败 |
| MatchPresentation 宿主 | ee0750f 下 14 XCTest，零失败；真实临时 SQLite、稳定请求重试及故障注入，不是 HealthKit 证据 |
| 最低部署 SDK | ee0750f 下 Store / Session / Presentation 各 iOS17 + watch10，六项显式 Simulator SDK 构建通过 |
| 双 App | ee0750f 下 iPhone / Watch 无签名 Simulator 构建通过，新增源文件均实际编译 |
| 390pt iPhone13 / iOS27 | d9230cf 的七项完整 XCUI 通过；后续辅助字号变化另在375pt实测 |
| 375pt iPhone13 mini / iOS27，深色、最大辅助字号 | 比分57.3pt、双clock69.3pt保持单行且在屏宽内；实际结束后的“已结束 / 待同步”116.7pt两行且场下独立，目标流程通过 |
| 45mm Series9 / watchOS27 | ee0750f 六项通过，原生确认查询一项失败；随后改为AX中真实53pt确认Cell行，暂停/bench/取消/结束目标流程复验通过。最终整轮正在固化 |

持久证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-009/`。ee0750f 的71项编译/测试输入清单 `inputs-ee0750f.json` SHA256为 `0294b7d0d6ed26d683df4582e5dbdac1fea04309d3daf02a72b9e397cbcd4230`。该轮完整脚本日志为 `host-sdk-rounds/20261016T033405Z/`，未把后续测试定位改动倒写为此前输入。

## 交互与边界

Watch 原型两页、四按钮和撤销完整触控区均至少44×44pt且避开页指示器。快记测试逐次核对精确标签、比分、个人进球和助攻，撤销必须真实消失并能立即纠正。只确认 hittable 不足以证明点击，定位也要求完整frame进入可用视口；Watch系统确认使用实际AX Cell，不依赖未保留的SwiftUI标识。

控制器14项回归覆盖：事实派生暂停/bench双时钟、结束待同步、缺失值不是零、首发选择取消不落库、首次保存失败、响应丢失原完整请求、stale查无提交才分配新command、重建后debounced清pending、较新已提交更新不被失败回滚、错误设备只读、正式许可不可用不造第二意图、gateway注入不能绕开生产许可、采集缺口可见。成功触觉仅在receipt确认后触发，物理手感未验。

Debug测试入口必须显式参数并使用独立canonical namespace、实际SQLite与持续开发模拟锁标识；无随机Workout UUID、健康样本或假peer。多候选/身份/诊断UI错误场景为明确的展示fixture，服务实际错误判定由独立Session回归验证，不把fixture当真实恢复。

真实HealthKit、定位、后台、锁屏、Workout恢复、系统授权、跨设备传输与生产开赛锁均未接入本任务。009链接UnavailableWorkoutGateway，010才能按设备门禁装配已审适配器。最低iOS17/watch10只有编译证据，当前安装runtime仅iOS27/watch27的实际UI执行不能证明最低系统运行。VoiceOver仅核查AX文本、语义与触控区域，未声称真机朗读/触觉体验。

## 复现与资源交接

运行 `NATIVE_BUILD_ROOT=/tmp/独立目录 scripts/native/verify.sh`。实际UI用 `NATIVE_UI_BUILD_ROOT=/tmp/独立目录 scripts/native/ui-test.sh Watch|iOS UDID`，失败返回非零，成功导出xcresult附件；脚本不创建/重配/删除设备。

本任务创建并保留给010：45mm Watch `9E47C372-0445-4B7D-9280-01FA43DDC981`、390pt iPhone13 `3094D821-E635-477D-B735-3B6F85039A24`、375pt mini `BCF44456-964D-40C7-B810-AE9C369C1CDD`。未修改用户既有配对、未下载runtime或删除设备。资源类型/runtime/状态观察见外部 `simulator-resources.json`；375pt任务设备设为深色，既有用户设备外观未改。
