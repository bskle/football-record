# NATIVE-023 验证

执行中。原始基线 `8d6ec935efa060ab462b2913ab8460734871ff40`。

树外证据目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-023`。六项 Git 输入已保存；红绿、工具与最终输入 manifest 随实际执行补充。未经执行、双审、合并的项目不记通过。

## 023.1

- 红：MigrationV4Tests 实际运行 1 项，版本 3→4 的两个断言失败。
- 绿：迁移 / legacy / sync compatibility / recovery 过滤回归单轮 Store 36、Session 7，合计 43 项 / 0；覆盖 v0～3 三故障点 rollback/reopen、future5 和 partial4 保留文件、原 legacy blobs。
- 首轮绿发现旧 schema2 降级 fixture 未移除新增 v4 表；已仅调整 fixture，原始失败日志保留 `023-1-green-attempt1.log`。
- 未改变旧 Canonical encoder；真实设备不适用此纯 SQLite DDL 检查。
