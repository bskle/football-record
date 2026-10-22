# M4 原验证脚本矩阵对齐 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本任务唯一作者直接执行；root 先审本计划放行，source/final 各须两位非作者审阅。

**Goal:** 将原 verify.sh 对齐既有 026 最终自动合同：9 条完整 host 命令、10 产品×4 最低 SDK=40 次编译、六个显式配置无签名 App 构建。

**Architecture:** 保留原 repo_root、NATIVE_BUILD_ROOT/build_root、log_dir、NATIVE_NODE_BINARY/node_binary 约定；用内置 Bash 兼容的 literal here-doc 表驱动三组既有命令。每项有独立 log、真实退出记录及 scratch/DerivedData，不增加框架、依赖或 dry-run/mock 执行模式。UI、Release 实际进程隔离、产品与工程均由 026 原作者继续负责。

**Tech Stack:** macOS /bin/bash、原 Node/Swift/xcrun/xcodebuild/tee；最低 iOS17/watchOS10 不变。

---

## 1. 实际登记和边界

- NATIVE-054 作者 `/root/m4_auth_evidence`；非作者审阅 `/root`、`/root/m4_recovery_audit`。
- base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；分支 `test/m4-validation-matrix`。
- 独立树 `/Users/liam/.codex/worktrees/m4-validation-matrix/20260830_足球记录`；attachment `01a16172-cfe4-7eb0-b3a7-5b576fadf2fe`；创建操作 `8930dcea-7e17-499c-9cec-a16c41869650`。作者已实际核 HEAD/base/branch/clean；不覆盖他人成果。
- 唯一四路径：`scripts/native/verify.sh`、本计划、`docs/native/tasks/NATIVE-054.md`、`docs/native/validation/NATIVE-054.md`。root 与 026 作者已确认 verify.sh 暂归本作者；其他 UI/scripts/project/provider/Package 不写。
- 只交付 held026，实际 merge target 由 root 重读；作者不 merge/push/archive 或推进 dev/release/main。
- 当前 dev 基线仅含 Core/Cloud/Account/Presentation 的包布局。WorkoutCapture、DeviceSync、HealthKitDeletion、AppIntegration 位于 held026；本任务不得在缺包 base 伪跑或宣称整包通过。

合同依据：026 的 local-acceptance-handoff-m2.json finalLocalMatrix、2026-10-20-m4-local-integration 计划和 final-matrix-readiness-20261022.json。这里只落实既有 9/40/6 数量及准确平台组合，不新增验收要求。

## 2. 原脚本的具体变更

### 2.1 运行和失败语义

- 保留 `#!/bin/bash`、`set -euo pipefail`、原 repo/build/node 环境约定；指定 Node 路径时继续 export 其目录到 PATH，让 Swift 启动的 Node fixture 使用相同 Node。
- log_dir 沿原 UTC 时间布局加入本进程 PID，避免同秒覆盖。令 run_root 位于同 build_root/runs 下，对应该次 log 标识；所有 scratch/DerivedData 按该次运行和阶段独立。
- 一个 `run_logged` 函数仅包装原工具命令：记录 quoted argv，原输出 tee 到独立 log，立即保存 PIPESTATUS，记录真实工具 exit；工具失败优先原 exit，工具成功而 tee 失败则失败。不使用 `|| true`、重试隐藏失败或跳过缺失包。
- Bash 只用 indexed arrays、while/read、here-doc、local；不使用 associative arrays、mapfile/readarray 或外部新增依赖。

### 2.2 9 条完整 host 命令

Node 仍为原 `node --test backend/test/*.test.mjs`；八个 Swift 包每包完整一次，不加 filter：

| 包 | 原相对路径 |
| --- | --- |
| MatchCore | native/Packages/MatchCore |
| CloudSync | native/Modules/CloudSync |
| AccountKit | native/Modules/AccountKit |
| MatchPresentation | native/Modules/MatchPresentation |
| WorkoutCapture | native/Modules/WorkoutCapture |
| DeviceSync | native/Modules/DeviceSync |
| HealthKitDeletion | native/Modules/HealthKitDeletion |
| AppIntegration | native/Apps/iOS/Integration |

每包调用 `swift test --package-path "$repo_root/$relative" --scratch-path "$run_root/host-$name"`，独立 host-$name log。Node 与八包合计九条，不预设内部测试数。

### 2.3 40 项最低 SDK 产品编译

产品表：MatchStore、MatchSession、MatchSync 共用 native/Packages/MatchCore；CloudSync、AccountKit、MatchPresentation、WorkoutCapture、DeviceSync、HealthKitDeletion 各在同名 Modules 包；AppIntegration 在 Apps/iOS/Integration。MatchCore 是依赖，不额外充作第 11 个产品。

SDK 表固定四项：

| sdk | triple |
| --- | --- |
| iphonesimulator | arm64-apple-ios17.0-simulator |
| iphoneos | arm64-apple-ios17.0 |
| watchsimulator | arm64-apple-watchos10.0-simulator |
| watchos | arm64-apple-watchos10.0 |

每产品×每表项调用原 `xcrun swift build --package-path ... --target "$target" --triple "$triple" --sdk "$sdk_path" --scratch-path "$run_root/sdk-$target-$sdk"`。sdk_path 由实际 `xcrun --sdk "$sdk" --show-sdk-path` 单独成功取得；独立 sdk-$target-$sdk log。10×4=40，不把 dry-run 或静态表展开算作编译。

### 2.4 六个无签名 App

| scheme | configuration | generic destination |
| --- | --- | --- |
| FootballRecord-iOS | Debug | iOS Simulator |
| FootballRecord-iOS | Release | iOS Simulator |
| FootballRecord-Watch | Debug | watchOS Simulator |
| FootballRecord-Watch | Release | watchOS Simulator |
| FootballRecord-iOS | Debug | iOS |
| FootballRecord-Watch | Debug | watchOS |

每项原 xcodebuild build 显式 `-configuration`、`-destination`，独立 derivedDataPath 和 log，传 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、`IPHONEOS_DEPLOYMENT_TARGET=17.0`、`WATCHOS_DEPLOYMENT_TARGET=10.0`。不添加 Team/profile/能力，不强制可能不适合真实 SDK 的设备 App 架构。设备项只是 generic SDK 无签名编译，不是物理安装。

最后成功输出明确只涵盖 host/SDK/App build 矩阵，UI、Release 实际隔离、真实账号/设备及整体发布仍单独验收。

## 3. 本任务执行和验证

- [ ] 只提交三份计划文档，检查本地链接和 diff-check，交 root exact plan SHA；未放行前不改 verify.sh。
- [ ] root 放行后仅改原 verify.sh，保持可执行 mode；不要将 026 旧追加 Workout/Device/AppIntegration 循环与新整表重复执行。
- [ ] 用真实 `/bin/bash -n scripts/native/verify.sh` 检查；记录 `/bin/bash --version`。若当前已有 shellcheck 则实际执行，不自动安装；未发现时明确记 unavailable。
- [ ] 只读静态审阅 literal 表与既有 9/40/6 合同的包路径/完整集合/四 triples/六配置，确认唯一 log/scratch、原 Node 路径、pipefail/工具 exit/tee failure 语义。可以产出静态命令清单作为证据，不运行 mock 工具或把清单叫测试通过。
- [ ] 记录当前缺失的四包事实；不在 base 执行原 host/40 SDK/六 App 最终矩阵，不新增镜像实现的单元测试，也不伪造编译结果。
- [ ] 冻结 script/source/hash/mode/输入及真实静态命令 exit，提交 `build: align native verification with the final matrix`，交两位非作者 source 审阅后停写。
- [ ] source 双 PASS 后只两张 task/validation 卡收尾，保持 script/plan 源字节；final 再双审。root 负责 held026 接入、组合冻结后的实际矩阵、相关复验和安全清理。

计划文档提交为 `docs: plan native validation matrix alignment`；source 和 final 均只按明确路径暂存。证据放在树外 NATIVE-054 目录，原旧验证层不覆盖。

## 4. 验收限制

本任务当前交付是脚本工程与静态验证，不是 9host/40build/6App 的通过证据。实际执行必须等待 026 产品、依赖与 UI/runner 其他缺口完成并冻结组合输入，逐真实命令记录 raw log/exit/count、before/post Git mode/blob/hash 和实际 App 产物。Health 等缺包时不得自动 skip 并打印成功。

不改或运行 UI、Release process/default isolation、375pt/AX，也不涉及真实 Apple/Keychain/iCloud/CloudKit/Health/WC、个人账号、签名设备、生产部署或发布晋级；不新增用户审批。
