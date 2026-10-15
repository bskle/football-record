# Frontend Implementation Plan: 球历 UI 原型

中文正式名：球历；英文正式名：`football-record`。英文名称不代表已设定 Bundle ID。

## 技术环境

| 项 | 值 |
|---|---|
| runtime | Browser ES2022 |
| framework | Vanilla JavaScript |
| build_tool | None |
| ui_library | None |
| package_manager | None |

## 文件变更

| 路径 | 操作 | 关联需求 | 关联组件 |
|---|---|---|---|
| prototype/index.html | create | UI-01 | app shell |
| prototype/styles.css | create | UI-01/UI-02 | phone/watch surfaces |
| prototype/app.js | create | MATCH-01..06 | state, tabs, modals, live clocks |

## 组件实现

| 组件 | 输入 | 状态 | API 调用 | 测试 |
|---|---|---|---|---|
| PhoneTabs | tab | active | mock | click tab |
| WatchHomeActions | action | running/paused/onField | mock state | two visible action slots: 上场/下场、比赛控制 |
| LiveClock | match state | running/paused/onField | local timestamps | match clock and appearance clock tick independently |
| QuickScore | mine/assist/for/against | instant record, 1000ms duplicate guard | none | direct save, attribution, history isolation |
| QuickRecordFeedback | last quick event | saved/idle | none | undo original event and recompute score |
| ScoreModal | impact/kind/note | 赛后补录 open/closed | none | save/cancel |
| Timeline | events | sorted | none | edit/delete |

## 路由与权限

| 路由 | 页面 | 权限 | 未授权处理 |
|---|---|---|---|
| / | 单页原型 | mock | 不涉及 |

## 平台适配

| 项 | 值 |
|---|---|
| target_platform | browser preview for Apple app UI |
| app_config_file | prototype/index.html |
| page_config_files | none |
| local_storage_api | deferred; in-memory state |
| navigation_api | data-tab state |
| component_model | semantic HTML |
| style_language | CSS3 |
| device_canvas | Apple Watch 45mm 396×484; iPhone preview 390×844 |
| unsupported_web_api_replacements | Apple Watch/HealthKit replaced with mock data |
| unsupported_css_replacements | none |
| template_expression_policy | none |

## API 对接

| 接口 | 请求类型 | 状态处理 | 错误处理 |
|---|---|---|---|
| mock event reducer | local | immediate rerender | toast feedback |

## 前端测试

| 测试 | 类型 | 覆盖验收标准 | 命令 |
|---|---|---|---|
| JavaScript parse | static | executable frontend | node --check prototype/app.js |
| Quick score behavior | Node built-in tests | 单击、归属、撤销、防重复、计时与历史隔离 | node --test tests/quick-record.test.cjs |
| UI smoke | manual browser | primary click paths | open http://127.0.0.1:4174 |

## 信息缺口登记

| 编号 | 字段 | 当前值 | 状态 | deferred_until_step | must_resolve_before | 解除条件 |
|---|---|---|---|---|---|---|
| GAP-001 | Native implementation | deferred | deferred | technical design | native V1 | Apple target created |

## 能力触发登记

| 能力 | 状态 | 触发依据 | 注入角色 | 影响产物 |
|---|---|---|---|---|
| product-ownership | active | complex state and scope | product-manager | UI scope |
| test-architecture | active | multi-state interaction | qa-engineer | smoke checklist |

## 阻塞项

| 编号 | 阻塞项 | 需要谁确认 | 截止条件 |
|---|---|---|---|
| BLOCK-001 | 无 | 无 | browser prototype runs |

## 审计状态

audit_status: passed
