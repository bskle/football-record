# Prototype Smoke Checks

2026-10-15 原型在本记录限定范围内通过验收。语法检查与 `node --test tests/quick-record.test.cjs tests/routes.test.cjs` 共 41/41（路线 30、快记 11）通过，含物理比例、水平精度/首点漂移/异常跳点、断采、按采样真实时间计算上场×运行时长、混合事件回放、缺事件时间不猜 0、校准持久化及附近复用/远处隔离。浏览器验证了 8 张真实 OSM 瓦片与署名、未校准无假球场、统一淡黄橙红热图，以及四角点击/1 米微调/地图缩放/保存/刷新保留/清除/重复角点禁存。

375px 页面 scrollWidth=375；手机 335×844，main clientWidth=scrollWidth=335，内容 949>810 可内滚；两页 Watch 均为 198×242 且内容高 242。校准页宽 335 无横向溢出、834 高内容在 804 高区域内滚动，角点/缩放/微调高 44、保存高 46.8。已实操暂停双钟 `53:34/44:34` 冻结且心率仍显示，继续/结束保存后路线两图与模拟标签保持，Watch 可再次开赛。第二场一张 GPS 图且明确热力图未生成，第三场无 SVG 且路线未记录/暂无热力图，均能返回同场详情和历史。截图：[桌面路线](../docs/screenshots/routes-quality-2026-10-15.png)、[路线](../docs/screenshots/routes-mobile-2026-10-15.png)、[校准](../docs/screenshots/route-calibration-mobile-2026-10-15.png)。

检查 28–36 不作统一浏览器通过声明：29 的瓦片 error/全部 load、9999ms 等待/10000ms 提示、旧断开瓦片不更新现页均通过自动 DOM 检查，但未在真实浏览器手动断网；35 的跨实例同场地复用和远处隔离为自动检查，浏览器验证刷新持久化。缺数据状态与回流已通过浏览器检查。真实 HealthKit、MapKit 和实地场地准确性未验证。

2026-10-14 打磨版已通过浏览器原型验收。桌面 1280px：手机 390×844，Watch 两页各 198×242、scrollHeight=clientHeight=242，六个操作按钮 87×44，撤销 44×44。窄窗口 375px：页面 scrollWidth=375，手机响应为 335×844，Watch 保持 198×242；手机以 390 为桌面基准，窄窗口仅调整宽度，不缩放控件或文字。截图：[桌面](../docs/screenshots/ui-polish-2026-10-14.jpg)、[窄窗口](../docs/screenshots/ui-polish-mobile-2026-10-14.jpg)。

已点击验证四项快捷记录均无弹窗、个人归属与撤销正确；下场时比赛时间从 52:34 到 52:52、上场时间保持 43:33，暂停时 53:09/43:33 持续冻结；继续、结束保存、开始页、替补开赛 0:0/个人 0/双时钟 00:00 及手动上场正常。真实二维码完整加载为 1284×2289，图片下载与 mailto 属性保持。语法检查和现有 11 项行为测试通过；实际 QQ 入群、原生健康采集与正式同步不在本次通过范围内。

本轮历史详情格式与路线页浏览器检查（22–27）已通过。第一场 `01:08`、距离(km) `6.8`、路线按钮 314×64；路线页两张 SVG 及图例同时显示，390×844 手机内容 clientHeight=scrollHeight=810，375px 页面 scrollWidth=375、手机 335×844 且无图表溢出。返回原详情保持标题与指标；第二场仅一张 GPS 图并显示热力图未生成，第三场无图并显示路线未记录/暂无热力图。在历史路线页操作 Watch 快捷记录只改实时比赛，撤销正常，历史图库不变。新增 10 项路线检查与原 11 项快记测试共 21/21 通过，控制台 error/warn 为空；缺采样时间不补造停留热度。截图：[详情](../docs/screenshots/history-detail-2026-10-14.jpg)、[路线](../docs/screenshots/history-routes-2026-10-14.jpg)、[窄窗口路线](../docs/screenshots/history-routes-mobile-2026-10-14.jpg)。原生采集与球场校准仍未验证。

1. `node --check prototype/app.js` exits 0.
2. Start `python3 -m http.server 4174 --bind 127.0.0.1 --directory prototype`.
3. Open `http://127.0.0.1:4174`.
4. Confirm two 45mm Watch pages render simultaneously with separate titles outside the device canvases. Each logical canvas is 198×242 pt, corresponding to 396×484 physical pixels; content is laid out at this size rather than shrinking the previous page as a whole.
5. Confirm the iPhone uses a 390×844 logical canvas and the match home shows a compact score, both timers, heart rate/distance/speed/GPS, and exactly two visible actions: 上场/下场 and 比赛控制. The Watch match home follows the same content and action logic.
6. Wait two seconds and confirm both timers advance while running.
7. Pause from `比赛控制`, wait two seconds, and confirm both timers freeze while health data remains visible.
8. Toggle 上场/下场 and confirm only the appearance timer starts/stops; the match timer keeps running.
9. Confirm exactly four quick score buttons in a two-by-two grid, each 44pt high and fully visible in the Watch logical canvas. Click each once, at least one second apart. No modal opens. My goal adds a home goal and my goal; my assist adds a home goal and my assist; team goal only adds a home goal; conceded goal adds an away goal.
10. End the match, confirm it appears in History, then start a new match from the post-match start screen.
11. Click History, open a match, edit/delete an event, and return.
12. Click Career and Settings; toggle each switch.
13. At 375px width confirm device previews wrap without horizontal page overflow or clipped actions. Confirm the preview does not claim a physical 1:1 display size, and the phone content can scroll within its logical canvas.
14. Confirm the quick page displays current score and personal goal/assist totals at the top and no recent-event list. Click 撤销 and confirm score, totals and the phone timeline all restore. The undo control stays available until the next quick record, without a timeout.
15. Rapidly click quick buttons within one second and confirm only one goal is recorded; undo allows immediate correction.
16. Open a historical match on the phone and click a Watch quick button; only the current match changes.
17. `node --test tests/quick-record.test.cjs` passes.
18. In Settings click 联系作者; confirm the contact page opens inside the phone, shows japdie19450815@qq.com, and 返回设置 restores Settings.
19. Confirm the email action targets `mailto:japdie19450815@qq.com`; opening the link does not automatically send an email.
20. Confirm the author-provided QQ QR image in `prototype/assets/feedback-group-qr.png` displays with the full code and quiet zone visible. Confirm 保存二维码图片 provides the complete source image. Verify actual group entry separately in the QQ client; image display alone does not count as a successful scan.
21. Capture desktop and narrow-viewport screenshots to inspect Apple system typography, dark green status and light-phone emphasis, and acid green limited to primary actions on the dark Watch. Confirm both Watch pages fit their 198×242 pt canvases and remain legible.
22. Open historical match details and confirm appearance duration is HH:MM without a unit: 68 minutes is `01:08`, 64 minutes is `01:04`. Confirm the distance title is 距离(km), the available value is numeric only, and missing data is 未记录 rather than zero.
23. Confirm 路线 is an entire clickable button rather than a small metric. Click it to open a separate route page inside the phone, then return to the same match detail.
24. In the first seeded historical match, confirm both the GPS route diagram and dwell-duration density heatmap are visible on the same scrollable page, without a carousel. Confirm the diagrams use the supplied mock coordinates and timestamps.
25. In the second seeded historical match, confirm the GPS route is visible and the heatmap explicitly says 未生成; no synthetic heatmap fills the gap.
26. In the third seeded historical match, confirm the route says 未记录 and neither an invented route nor a zero-valued replacement is shown.
27. Confirm realtime GPS 良好 is described as positioning status; saved motion tracks are accessed through 历史→比赛详情→路线. Check narrow viewport route-page scrolling, diagrams and return action. Treat mock diagram rendering separately from real native collection or calibrated pitch verification.
28. Open the route page without saved field calibration. Confirm a real geographic basemap is used, the track stays at its source location and proportional scale, and no standard pitch lines are invented. Confirm the actual map provider attribution remains visible.
29. Make the basemap unavailable and confirm a clear missing-map state appears; no fictional pitch replaces it. Missing GPS/heatmap data must still show the explicit unavailable state rather than synthetic values. Automated DOM checks passed for tile error/all-loaded states, no timeout before 10000ms, timeout feedback at 10000ms, and detached old tiles not updating the current page. Real-browser HTTP offline failure has not been manually simulated.
30. Inspect mock samples with horizontalAccuracy and abnormal drift/jump points. Confirm low-quality samples are filtered from display while rawGPS remains unchanged, and valid nearby positions are not snapped into a field rectangle.
31. Inspect the sampling gap example. Confirm separate route segments do not connect across missing collection and no dwell duration is generated for that gap; missing timestamps also must not generate heat.
32. Confirm the heatmap uses real metric cells and distinct density levels with reduced blur. Verify density reflects elapsed eligible time rather than just point count or a normalized standard-pitch image.
33. Compare playing, bench-rest and match-pause samples. Confirm heat includes only the overlap of on-field intervals and running match intervals, excludes bench/pause/gap time, and does not stop off-field health collection or visibility.
34. In the post-match phone route page, select four map corners, zoom and adjust by one metre, then save the current field. Confirm duplicate corners disable saving and only the field boundary overlay changes; rawGPS and track positions are unchanged and outside positions stay outside. Browser selection/zoom/nudge/save/clear/duplicate-corner checks passed.
35. Reopen or reuse that field configuration and confirm the saved boundary/direction is reused. Clear calibration and confirm return to the uncalibrated map with no standard pitch lines. Confirm no pre-match calibration is required to start or record a match. Evidence: browser refresh persistence passed; cross-instance nearby reuse and distant-field isolation passed automated checks.
36. Check the route and calibration views at desktop and 375px widths, including both map/heat views, controls, attribution, unavailable states and return to the same historical match. Treat these prototype checks separately from native HealthKit collection and measured real-field calibration.
