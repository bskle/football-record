# NATIVE-013 — M3 持久设备同步规划

状态：规划文档完成，待两位非作者审阅；未开始 M3 产品实现。纯文档任务，不改原生源码、工程或验证脚本。

| 登记项 | 本任务事实 |
|---|---|
| 作者 / 主代理 | `/root/m3_plan` 唯一写入；`/root` 统筹、质量审阅与合并 |
| 第二位非作者审阅者 | `/root/m2_review`，规格与边界审阅；作者自审不计双审 |
| 原始基线 / 合并目标 | `dev` / `dev`，完整 SHA 均为 `505449279d6461436a051b5e6bc43324d805e3e0` |
| 临时分支 | `docs/native-m3-plan` |
| 受管 worktree | attachment `01a14365-7c3b-7f72-816e-ebf0d0aec976`；createdAt `1792132086` |
| 实际目录 / 初始 HEAD | `/Users/liam/.codex/worktrees/native-m3-plan/20260830_足球记录`；实际 HEAD 与上述基线一致，写入前 clean |
| 唯一写入范围 | 本卡、`docs/superpowers/plans/2026-10-16-native-m3.md`、`docs/native/contracts/m3-durable-sync.md`、`AGENTS.md` 当前事实、`docs/development-readiness.md` 当前事实、母计划 `docs/superpowers/plans/2026-10-15-native-development.md` 的 M3 状态及用户测试延期指令 |
| 禁止写入 | `native/**`、`scripts/**`、Git 工作流、原型、旧任务卡；不撤销其他代理修改 |

用户已明确“先跳过需要我协助部分，往下推，后续再做相关测试”。据已批准母计划，继续 M3 不依赖本人设备、账号或环境的规划和自动验证工作；涉及真实设备的合入门槛保留为待验，不能记为通过。NATIVE-008 / 010 仍保留设备验收依赖，不因本计划解除门槛或提前入 `dev`。

交付为 [M3 子计划](../../superpowers/plans/2026-10-16-native-m3.md) 和 [冻结合同](../contracts/m3-durable-sync.md)，拆分 014 仓储协议、015 同步服务、016 WatchConnectivity 适配、017 状态 UI / 工程装配、018 临时真机集成。未来任务未创建，不填写虚构 SHA、路径或验证结果。

验收：六路径 diff / 链接 / 当前事实检查；`native/**` 与 `scripts/**` 相对原始基线完全不变。纯文档不重跑已有 166 项产品测试；真机不适用，因为本任务没有设备代码或能力改动。提交、双审、实际 merge 验证与归档结果只在动作完成后登记；作者不 merge、push、archive 或删除分支。

作者检查（2026-10-16）：实际运行六文件本地Markdown链接检查，45处引用均存在；`git diff --check`与基线相比native/scripts/prototype隔离检查exit0。未执行产品测试，原因是只有文档变化。最终精确scope/暂存差异与commit后clean由下次Git检查核对，提交SHA由root审阅记录绑定，避免把本提交自引用写入文件。作者交付后停止写入，双审/合并/归档仍待root执行。
