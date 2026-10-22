# NATIVE-054：最终原生自动验证脚本对齐

状态：exact source 已经 root 与 recovery 双审 PASS（仅脚本静态工程范围）；作者最终两卡收尾并停写，待 final 双审和 root 接入 held026。

- 作者 `/root/m4_auth_evidence`；非作者审阅 `/root`、`/root/m4_recovery_audit`。
- base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；计划提交 `e1a99ae1409079c966b09cb1c61c1739318a04a8`；冻结 source `41bf5330c3e9478081ddb674b535b24c2e20b4ad`。
- 分支 `test/m4-validation-matrix`；独立树 `/Users/liam/.codex/worktrees/m4-validation-matrix/20260830_足球记录`；attachment `01a16172-cfe4-7eb0-b3a7-5b576fadf2fe`。初始 HEAD/base/branch/clean 已实际核，source 交付 clean 含 ignored。
- 只合 held026，实际 target SHA 由 root 接入前重读；本任务不推进 dev/release/main。

唯一四路径：verify.sh、[具体计划](../../superpowers/plans/2026-10-22-m4-validation-matrix.md)、本 task 和 [validation](../validation/NATIVE-054.md)。026 已暂让 verify.sh 写入权；其他 UI/scripts/project/Package/provider 均未修改。

source 相对计划只改原 `scripts/native/verify.sh`（+83/-74），保留 mode `100755`。脚本的 literal 表完整覆盖既有合同：Node+八包共九条完整 host，十产品×四 iOS17/watchOS10 sim/device triples=40 SDK，iOS+Watch 的 Debug/Release genericSimulator 四项和 Debug genericdevice 两项无签名 App。App 配置、最低系统与无签名设置显式；没有虚构 MatchCore 第十一产品或真机安装。

原 repo/build/node/log 环境接口保留。每次运行使用 UTC+PID 的 log/run 目录，每阶段独立 log/command/status/scratch 或 DerivedData。run_logged 临时关闭 errexit 仅为立即取得真实工具|tee 的两项 PIPESTATUS，然后恢复 errexit、持久两项状态；原工具非零优先返回，tee 失败亦不隐去。缺包/SDK 不 skip、不吞错或假成功；只使用内置 Bash3 支持的语法。

作者实际 `/bin/bash -n` exit0，本机 Bash3.2.57；root 也实际语法检查 exit0。静态合同集合和 55 个唯一阶段名经两位非作者独立核对；shellcheck 在 PATH/常用位置未发现，未安装。**未执行九条 host、40 SDK、六 App 的最终矩阵；这些数量仅是静态命令合同，不是测试或构建通过数。**

当前 dev 基线仍缺四个 held026 包：WorkoutCapture、DeviceSync、HealthKitDeletion、AppIntegration。source 检查点核了四项 Git 输入和十份证据；实际产品矩阵留待 026 完整组合冻结后执行。source 双审不代表 UI、Release 进程隔离、真实账号/设备、部署、whole026/M4 或发布验收。

source/plan 字节在最终两卡后保持不变。预检发现接入 026 时 verify.sh 与其旧追加循环存在冲突；新整表已包含这些原项目，不能重复保留旧循环。root 在 final 双审和 026 暂停边界后触发 no-ff，若另行交本作者唯一脚本解冲突，只机械取 exact 已审文件，不同时写两树、不改其他路径、不提交 merge；root 与第二审阅者核对后由 root 完成提交/复验。

当前作者未改 026，未 merge/push/archive 或清理分支。实际接入、组合冻结、真实执行、原生归档及 safe branch-d 由 root 统筹。
