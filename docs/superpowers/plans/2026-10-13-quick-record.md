# Quick Record Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement these tasks. Checkboxes track completion.

**Goal:** 球场上一次点击即可记录比分和个人归属，快速记录只保留四个按钮。

**Architecture:** 保留原型的内存事件模型。快捷操作只写当前比赛，比分与个人进球/助攻从事件推导；最后一条快捷记录提供撤销，不增加确认弹窗。

**Tech Stack:** Vanilla JavaScript、CSS、Node 内置 node:test + vm。

## Task 1: Behavior regression checks

**Files:** Create `tests/quick-record.test.cjs`.

- [x] 用真实点击处理函数测试四个按钮单击直接写入、个人归属、撤销、1000ms 连点保护和历史详情隔离。
- [x] Run `node --test tests/quick-record.test.cjs`，先确认旧版无法满足这些行为。

## Task 2: One-tap scoring

**Files:** Modify `prototype/app.js` and `prototype/styles.css`.

- [x] 删除快速页乌龙球按钮，四按钮按两行两列排列。
- [x] `mine` 创建我方进球且 `scorer: 'self'`；`assist` 创建我方进球且 `assister: 'self'`；`for` 不关联个人；`against` 为对方进球。所有事件都带比赛秒数。
- [x] 点击直接存入 `state.liveMatch.events`，页面保持原位，显示更新的比分、本场个人进球/助攻和带撤销的反馈行。
- [x] 1000ms 内重复快捷记录不再次计分；撤销删除原事件并清除连点保护，允许立即改正。撤销仅作用于最后一条快捷记录。
- [x] 结束或开始比赛时清除快捷反馈；从历史详情操作 Watch 时只改变当前比赛。
- [x] 保留赛后补录中的乌龙球类型，低频记录无需占快速页按钮。

## Task 3: Verification and documentation

**Files:** Modify `docs/ui-ux-spec.md`, `docs/ui-prototype-validation.md`, `tests/prototype-smoke.md` and `prototype/README.md`.

- [x] Run `node --check prototype/app.js` and `node --test tests/quick-record.test.cjs`，所有行为测试通过。
- [x] 浏览器验证四按钮均不打开弹窗、即时比分和撤销、布局没有裁切，以及手机比分同步。
- [x] 更新文档中的五按钮及弹窗流程描述，保持正在运行的预览可操作。

执行完成：11 项 Node 行为测试通过。浏览器验证 375px 和默认 1280px；两张 Watch 卡片均无内容裁切。审查发现并修复历史补录/删除不重算比分的问题，补充未详录比分基数及对应回归测试。预览入口：http://127.0.0.1:4174/?v=quick4。

本地项目没有 Git 仓库，本轮保存文件并验证，不创建提交。
