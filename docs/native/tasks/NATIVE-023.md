# NATIVE-023：schema4、原 Session 与 HTTP 纵向

状态：执行中；审阅、合并均待主代理安排。

- 作者：m4_session；唯一 worktree `/Users/liam/.codex/worktrees/m4-session-authority/20260830_足球记录`。
- 分支：`feat/m4-session-authority`；attachment `01a14fd7-5113-7dd2-8c29-c64d7f18b94a`。
- 原始 base_ref / target：dev；完整 base / 开工 target / 初始 HEAD：`8d6ec935efa060ab462b2913ab8460734871ff40`；初始 clean。
- 依赖：021 final `a55dab4d10bf2b10011c81a49a30128cd9f835ad`；022 final `b648b730fbb9929453c32a43b12bc77bd2d67faf`，均已双审合入实际 base。
- 所有权：`native/Packages/MatchCore/**`、`native/Modules/AccountKit/**`、必要 `scripts/native/verify.sh`、本卡与 `docs/native/validation/NATIVE-023.md`。其他路径只读；不改生产 Bootstrap。
- 计划：依次完成 023.1 additive schema4、023.2 验签与原 start、023.3 云与终结、023.4 独立 peer、023.5 HTTP / 生命周期 / 回归。每个 slice 红绿与独立 Conventional Commit。
- 约束：不扩大 SessionRepository 必需方法；一个 facade / Store；网络不持同场队列或 SQL；不改 legacy canonical；normal 仅原 recorder PoP；生产默认 unavailable。
- 真机：本任务仅文件 SQLite、真实 loopback HTTP 与最低 SDK 软件范围；真实 Apple / iCloud / Keychain / CloudKit / 配对设备留 024/026，不能标通过。
- 两位非作者、source / final SHA、actual merge / 清理：待主代理。
- 证据：`native-validation/NATIVE-023`，详见验证卡。

- 023.1 / 023.2 / 023.3 软件切片已提交；236 Core + 17 AccountKit 的确切单轮及限制见验证卡。023.4 独立 peer 等待已审 NATIVE030 角色签名 wire，023.5 auth/lifecycle 继续执行；未请求审阅/合并通过。
