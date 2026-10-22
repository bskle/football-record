# NATIVE-054：最终原生自动验证脚本对齐

状态：具体计划已提交候审；verify.sh 尚未修改，未运行最终矩阵。

- 作者 `/root/m4_auth_evidence`；审阅 `/root`、`/root/m4_recovery_audit`。
- base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；分支 `test/m4-validation-matrix`；独立树 `/Users/liam/.codex/worktrees/m4-validation-matrix/20260830_足球记录`。
- attachment `01a16172-cfe4-7eb0-b3a7-5b576fadf2fe`，初始 HEAD/base/branch/clean 已实际核对；只合 held026，实际目标由 root 重读。
- 仅写 verify.sh、[具体计划](../../superpowers/plans/2026-10-22-m4-validation-matrix.md)、本 task 和 [validation](../validation/NATIVE-054.md)。026 已暂停对 verify.sh 的写入，其他脚本、UI、工程、Package 和产品均不归本任务。

既有合同为 9 完整 host 命令、10产品×四 iOS17/watchOS10 sim/device triples=40 SDK 编译，以及 iOS+Watch Debug/Release genericSimulator四项和 Debug genericdevice两项无签名 App。采用内置 Bash 兼容表驱动，保持原 root/build/node/log 变量及真实失败退出，每命令独立日志/缓存。

当前 base 缺少 WorkoutCapture、DeviceSync、HealthKitDeletion 和 AppIntegration 包；本任务先做语法和静态矩阵审阅，不预跑最终整包或将清单冒称验证结果。root 计划放行后才改 script，source/final 双审后由 root 接入026、组合冻结后实际执行。作者不 merge/push/archive 或推进长期分支。
