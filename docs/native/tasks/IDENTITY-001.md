# IDENTITY-001：统一正式产品名称

日期：2026-10-15。作者工作完成，待主代理安排双审与集成；本记录不宣称已合并或发布。

## 派工与所有权

| 字段 | 值 |
|---|---|
| 开发子代理 | `/root/app_identity` |
| 原始 base ref / SHA | `dev` / `59edac891ee3a1cbb79a30b396ad1902d0907a62` |
| 任务分支 / 合并目标 | `feat/app-identity` / `dev` |
| 受管 worktree identityKey | `/Users/liam/.codex/worktrees/app-identity/20260830_足球记录` |
| attachment id | `01a13ed1-9f6a-7002-9a65-ec0a6108a130` |
| 实际工作目录 | `/Users/liam/.codex/worktrees/app-identity/20260830_足球记录` |
| 初始 HEAD / 状态 | `59edac891ee3a1cbb79a30b396ad1902d0907a62` / clean |
| 写入范围 | `prototype/`、`docs/0-产品方案.md`、`docs/ui-ux-spec.md`、`docs/frontend-implementation-plan.md`、`打开足球记录.html` 及本记录 |
| 前置依赖 | 无；独立产品身份文案任务 |

该 base 不含 `AGENTS.md` 或 `docs/git-workflow.md`；执行遵循会话内用户规则，并只读主工作区治理方案。未写入其他工作树。

## 变更

- 中文正式名统一为“球历”，英文正式名确定为 `football-record`，并明确英文名称不代表已设定 Bundle ID。
- 更新原型页面标题、现有品牌页眉、入口标题与链接、二维码替代文字与下载文件名，以及产品/前端规范中的当前产品名称。
- 删除产品方案中仍把正式名称列为待决定项的条目。
- 根入口文件路径仍为 `打开足球记录.html`。历史截图与日期验收事实、普通“足球记录”业务术语、存储键和业务实现均保留。

## 实际验证

- `node --check prototype/app.js`：退出码 0。
- `node --test tests/quick-record.test.cjs tests/routes.test.cjs`：41/41 通过，0 失败。
- `git diff --check`：退出码 0。
- 读取两处 HTML title 并使用 Node VM 执行原型 `render()`：原型 title 为“球历 · 记录你的每一场”，根入口 title 为“打开球历”，实际生成的 `h1.brand` 为“球历”。此项为一次性检查，未新增测试文件。
- 旧名称扫描：所拥有文件中无“踢球履历”“足球生涯记录”或名称待定表述；保留通用业务描述与原入口文件名。

## 限制与生命周期

- 真机不适用：仅产品身份文案修改，无原生工程、设备能力或采集行为变更。
- 未运行新的浏览器视觉或 QQ 客户端入群验证；不改写既有验收记录。
- 两位非作者审阅、合并 SHA、合并后验证、归档与临时分支清理由主代理绑定最终提交记录。
- 本任务未合并、推送、上传、部署或分发。
