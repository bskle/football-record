# NATIVE-054 验证记录

冻结 source：`41bf5330c3e9478081ddb674b535b24c2e20b4ad`；base：`2cab4640ee3a375da39fdabf0f5a317600b0c263`；计划提交：`e1a99ae1409079c966b09cb1c61c1739318a04a8`。source 已获 root 与 recovery 两位非作者 PASS，范围仅脚本静态工程；本次两卡收尾后还需 exact final 双审。

证据根 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-054`。

## 实际执行的检查

| 检查 | 实际结果及边界 |
| --- | --- |
| `/bin/bash -n scripts/native/verify.sh` | 作者 exit0；root 独立执行亦 exit0；只解析语法，不执行脚本 body |
| `/bin/bash --version` | GNU bash 3.2.57(1)-release，arm64-apple-darwin26 |
| shellcheck 可用性 | PATH 及 /opt/homebrew/bin、/usr/local/bin、/usr/bin 未发现；未安装、未伪称执行 |
| 静态 literal 表对照既有合同 | 8 个 Swift 包+Node=9 host；10 产品×4 triple=40；六个显式 App 配置/目的地；55 阶段名全唯一 |
| diff / 文件所有权 | 相对计划只改 verify.sh，+83/-74；mode100755；未改 UI/工程/Package/provider 或其他脚本 |
| Git/证据 | 四个 owned Git mode/blob/hash/size 与冻结副本一致，十份证据 size/hash 均核对；source clean 含 ignored |

作者 bash-n 输出为空，source-bash-n.log SHA256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；版本输出在 source-bash-version.log。source-static-validation.json SHA256 `4911c8c10eafd2b28e377a0d14780826dfca0887102c46e9f3b7aea123d3246d`。

静态命令 inventory 只是读取并比较 here-doc literal 集合，没有 source/执行脚本，没有 mock 二进制、dry-run 或拦截 Node/Swift/xcodebuild。因而它不证明任何产品测试、SDK 或 App 构建已经成功，也没有预填内部测试总数。

## 脚本语义与合同

原 repo_root、NATIVE_BUILD_ROOT/build_root、log_dir、NATIVE_NODE_BINARY/node_binary 与自定义 Node 目录 PATH 接口保留。UTC+PID 区分运行，run_root 下每阶段独立 scratch/DerivedData；quoted argv、原输出和两项退出状态各自落盘。

run_logged 保留 set-e/pipefail 的失败契约：只有执行真实工具|tee 的瞬间临时 set+e，pipeline 后立即拷贝 PIPESTATUS，中间没有其他命令重置它；随后 set-e、记录 tool/tee 状态。工具非零优先返回原 exit，工具成功而 tee 非零仍失败，命令/状态日志写入失败也在 errexit 下失败。所有调用点为普通顶层或 here-doc while body 命令，不在 if/|| 环境吞掉错误；SDK 路径赋值本身失败也终止。没有缺包自动 skip、吞错重试或无条件成功分支。上述为源码审阅结论，不是用 mock 工具运行出的失败测试。

| 既有合同组 | 静态完整集合 | 本任务实际产品执行 |
| --- | --- | --- |
| 完整 host | backend Node；MatchCore、CloudSync、AccountKit、MatchPresentation、WorkoutCapture、DeviceSync、HealthKitDeletion、AppIntegration | 未运行 |
| 最低 SDK | MatchStore、MatchSession、MatchSync、CloudSync、AccountKit、MatchPresentation、WorkoutCapture、DeviceSync、HealthKitDeletion、AppIntegration × iOS17/watchOS10 的 simulator/device 四 triple | 未运行 |
| 无签名 App | iOS 与 Watch 各 Debug/Release genericSimulator；各 Debug genericdevice；显式 minOS17/10 与 CODE_SIGNING_ALLOWED=NO | 未运行 |

MatchCore 只作为依赖，不加虚构第十一产品。App 不添加 Team/profile、能力或 provider，genericdevice 只代表 SDK 编译。成功提示明确限于 host/SDK/App builds，并保留 UI/runtime/device 验收独立。

本 dev base 缺少四个 held026 包（WorkoutCapture、DeviceSync、HealthKitDeletion、AppIntegration），所以不在此树尝试最终矩阵；脚本也不以 skip 将缺包伪装成功。实际九条 host/40 SDK/六 App 必须在 root 接入完整 026、产品及 runner 其他缺口完成并冻结后，按实际命令/log/exit/count 与 whole-input before/post 证据验收。

## 精确源码与双审

- verify.sh：mode `100755`，Git blob `ed63b465315da8482b31c41112aa47b5b4531402`，SHA256 `b6a373de94edd0a1940541cb54db3b67f1b39c59c16a555adf21592ad0d1b8fd`。
- source-checkpoint-41bf533.json SHA256 `6d343d06a7f7a32aff498bd7e5206a602bd8b54c77387e2d6be3ffdaf57e1768`，四输入/十证据；完整 source副本在 source-41bf533-inputs，原基线脚本另存 base-verify.sh。
- root：source-review-root-41bf533.json SHA256 `96fd4dc4be616b82ccd00b9d5505dfe790208691716d11cb017cbefa3a6ac3df`，PASS_SOURCE_STATIC_SCRIPT_ENGINEERING。
- recovery：source-review-recovery-41bf533.json SHA256 `3a07d179ee509944f92f47e7bda942567795fdbb0276ad81124de73d63f74d33`，PASS_SCOPED_054_SOURCE_STATIC；独立 Git/byte/合同审计，没有运行最终产品矩阵。
- 最终只修改 task/validation 两卡，verify.sh mode/blob/hash 与计划 SHA256 `9956fe2a2741cde8503893873fa80991065cb095e9308c5864370dab1f1dabd0` 保持 source 不变；exact final 对照另存树外。

root 预检只发现 verify.sh 与 026 旧追加循环的冲突，新矩阵已经覆盖其全部项目。尚未在本任务改 026 或提交 merge；最终双审后若 root 暂停 026 并授权本作者机械解脚本冲突，只取 exact 已审文件，由 root+second 核对 resolved blob/语法/集合并由 root 提交，不能重复运行旧追加循环。

没有 UI、Release 实际进程隔离、375pt/AX、真实 Apple/Keychain/iCloud/CloudKit/Health/WC、个人账号/设备、签名安装、部署或 whole026/M4/发布验收。作者未 merge/push/archive 或晋级长期分支；接入、实际组合执行及安全清理均由 root 负责，不新增用户审批。
