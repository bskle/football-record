# NATIVE-020：M4 工程子计划与冻结合同

## 登记

| 字段 | 记录 |
|---|---|
| 目标 | 将已批准母计划 M4 拆成可执行工程任务，冻结账号、权威锁、私有云与设备生命周期接口；本任务仅文档 |
| 主代理 / 唯一作者 | `/root` / `/root/m4_plan` |
| 两位非作者审阅者 | `/root`、`/root/m2_review`；源提交后按 exact SHA 审阅 |
| base_ref / base_sha | `dev` / `33c5664da5e8c6fbae78891cf15035768c6d6b56` |
| 合并目标 / 登记时目标 SHA | `dev` / `33c5664da5e8c6fbae78891cf15035768c6d6b56` |
| 临时分支 | `docs/native-m4-plan` |
| 受管 worktree 标识 | `01a14f6f-0040-7da1-9ee8-634ecfd5a574`；createdAt `1792334037` |
| 绝对路径 | `/Users/liam/.codex/worktrees/native-m4-plan/20260830_足球记录` |
| 创建后实际 HEAD / 状态 | `33c5664da5e8c6fbae78891cf15035768c6d6b56` / clean；作者开始写入前复核一致 |
| 唯一写入范围 | 本卡、`docs/superpowers/plans/2026-10-18-native-m4.md`、`docs/native/contracts/m4-account-lock-cloud.md`、根 `AGENTS.md`、`docs/development-readiness.md`、母计划 `docs/superpowers/plans/2026-10-15-native-development.md` |
| 禁止范围 | 产品、工程配置、脚本、历史任务卡；不触碰 008/010/016/018 候选，不处理 queued 旧树 |
| 前置 | 已批准母计划；用户 2026-10-18 明确继续无需本人协助的 M4 工程工作 |
| 外部证据目录 | `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-020` |

## 执行记录

- [x] 创建后核对分支、完整 HEAD 与 clean 状态，再开始六路径写入。
- [x] 核对产品 0.10 / 0.11 / 0.12 / 0.17、母计划 M4 与 M3 合同，写子计划和冻结合同；覆盖021～026的接口、路径、依赖、红绿故障与真实门槛。
- [x] 核对六文件 diff、58项相对链接、产品/配置/脚本/原型零差异；保存六项 Git 输入、`checks.log`及`manifest.json`，提交前对最终暂存版本再核。
- [ ] 作者提交后停写，交两位非作者审阅；按反馈仅由作者修正文档并重新冻结 SHA。

## 验证与限制

纯文档任务，真机不适用；不将已有测试证据改称本任务运行，不宣称 M4 功能、真实 Apple 登录、CloudKit、生产锁或原生发布已经完成。实际提交、双审、合并、同步与生命周期由完成该动作的负责人补录。

检查证据为树外 `01-status.log`、`02-head.log`、`03-base.log`、`04-target.log`、`05-diff.patch`、`06-worktrees.log`，以及本次文档校验日志和六文档SHA256 manifest。内容检查包括`git diff --cached --check`、精确六路径暂存、无额外未提交/未跟踪来源、58项本地Markdown链接、任务/关键合同覆盖与无占位词，以及`native/ scripts/ backend/ prototype/`、原型入口、产品方案零差异。产品测试/构建未运行且不作声称。

作者先闭环非作者预审的双证据completion顺序、旧acquire当前状态、lost-recovery窄grant、auth/delete失响应恢复、云parent-token/reset-generation CAS、stable zone/epoch fence和完整PoP签名。源提交SHA保存在树外提交输入，避免文档自引用；源提交后作者停写，正式双审/合并/同步尚未发生，不预填通过。
