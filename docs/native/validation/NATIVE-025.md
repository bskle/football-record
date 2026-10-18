# NATIVE-025 验证记录

冻结 source：`4ec78e879cd8a7cef981540bdeebac39e5e82b95`；目标：`fcf530ada01a7cbf87bbfde598f611d8a35705b2`。证据根为 `/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-025`。构建独占 `/private/tmp/football-record-NATIVE025-build`。

## 实际验证与输入层次

| 输入 / 命令组 | 实际结果 | 证据 |
|---|---|---|
| `68cc384…` 宿主批次 | Node161 + Core257 + Cloud80 + Account54 + Presentation63 = 615，0失败 | `final-host-sdk-results.json`、`final-host-counts.json`，各 raw log |
| 同输入最低 SDK | 6产品 × iOS17 / watch10 simulator arm64，共12项编译通过 | 同一17命令记录；最低版本未运行 |
| clean `4ec78e8…` App | 两端各 Debug / Release arm64 simulator，共4；另两端 Debug arm64 generic device SDK，共2，无签名构建全通过 | `final-app-build-results.json`，6 raw log |
| Phone 账号 / 生命周期 | `455914a…` 两项，0失败 | `phone-455914a/` |
| Watch 账号 / 生命周期 | `68cc384…` 产品 + 当时未提交的 helper，两项，0失败 | `watch-product68cc-uihelper/` |
| Phone 身份变化 / 重新载入 | 已提交 `d0776cd…` 一项，0失败 | `phone-recovery-d077/` |
| 375pt 深色最大字体 | `d0776cd…` + 1行加载锚点修正，随后原样提交 `4ec78e8…`，一项，0失败 | `ui-runs/20261018T224333Z-iOS/` |
| 原录制持久同步 spot | clean `4ec78e8…` 两端各一项，0失败 | `final-legacy-ui-results.json`、对应 `ui-runs/` |

宿主与 SDK 各命令 exit0；所有列出的 UI 测试和附件导出均 exit0。Core257来自该包4个独立 xctest executable，非只读最后一个汇总。`host-to-final-input-delta.json` 比对244输入，68cc至4ec仅 UITest 文件改变；产品、包与宿主测试字节相同。以上分层不称为 final4ec 同 source 一轮全包，也不与旧M3/M4结果相加。

`ui-provenance.json`、`68cc-to-d077-uitest.patch`、`d077-to-4ec-uitest.patch` 明确保留：Watch 当轮没有独立捕获完整 UITest 文件的执行时副本 / hash，后续 d077 将其两个 Watch helper hunk 入史，另含 iOS Recovery 查询改动；不能追称 Watch 当轮 exact d077 / 4ec。375首次失败为 lazy Form 未实例化首屏下方登录按钮，改等可见状态锚点后仍真实滚动并点击。旧失败日志、xcresult、AX、PNG / 视频均保留。

Xcode27.0 / Swift6.4；本轮 UI runtime 为 iOS27 / watchOS27。iPhone13 390pt `3094D821-E635-477D-B735-3B6F85039A24`；Series9 45mm `9E47C372-0445-4B7D-9280-01FA43DDC981`；13mini 375pt `BCF44456-964D-40C7-B810-AE9C369C1CDD`。后者实际 dark + accessibility-extra-extra-extra-large，设置记录 `environment-and-small-screen.json`；按钮可达是自动 UI 验证，不代表真人 VoiceOver。

## 行为与红绿

受控真实 SQLite / HTTP 回归覆盖同 facade、持久 query / reopen、默认统计关、离线和错误不阻本机事实、正常双 proof 后 completed、cloud-only / peer ACK / held 不放锁、正常 / 异常释放后新 StartIntent 仍走 Core fresh authority。迁移使用原签名 checkpoint；删除使用原 saga / scope，本地 Store 与 transport 聚合，Health 独立确认且当前实际 unavailable；开发云只含已登记的一份 ledger，界面明确演练范围。

已关闭的实际问题包括 S25-model-1 迟到 action / query 覆盖新观察、identityVerified 未被根视图观察、existing SQLite 即使空库缺原 key / identity / pin 仍必须失败关闭、Node fixture 时钟实际流逝、lifecycle 错误独立显示，以及 S25-context-reload-1 旧 stopped 模型不能因 renew 再放行。每项原红测 / 故障及对应绿测保留，不用重复成功掩盖初始失败。

两端 Release 还实际安装并带全部 Debug 参数与故意无效0600私有控制文件启动，均显示“账号服务尚未接通”。6组 Debug 专属类型 / 控制文件 / flag 字节未进入 Release binary，Release Info 无开发本地网络例外；临时控制文件已移除。见 `release-isolation-results.json`、两张 `release-*-ignores-development-input.png`。源码由 `#if DEBUG` 保持边界，App 无 Process。`git diff --check`、bash语法、工程 / Debug Info plist检查通过。

## 审阅、冻结与移交

root 质量、m2 规格对 exact4ec / fcf530 正式源码 PASS，记录 `source-review-root.json`、`source-review-m2.json`；scope为本机软件，真实环境不据此通过。root已目视 Phone / Watch / 375截图。最终仅3docs增量，另行双审。

Source manifest `source-4ec78e8/manifest.json`：245 Git输入、8585冻结证据，SHA-256 `34539b2be18622aaf409ed52d391101d04ea1f624e8f0178931e0d3b6a0350a3`。`inputs[].path` 相对该 source目录的 `inputs/`；`evidence[].path` 相对上述 NATIVE-025证据根，**不相对 source目录**。原始字节不回写。final manifest另存 `final-<最终提交短SHA>/manifest.json`，复制3docs并逐项对照原245输入；只允许 task / plan 文档变化，另新增validation，其余243输入不变。

作者最终提交 clean 后停止全部源码 / 工程 / UI写入和模拟器操作；三个任务模拟器保留，375仍为深色最大字体，390 / Watch最后展示 Release unavailable页面。fixture broker / Node已按本任务退出流程关闭；移交主代理在 actual merge输入冻结后复验当前账号 UI，无需作者重跑宿主。无真实账号、SDK024装配、entitlements、签名安装、GPS / 后台 / 锁屏、真实 Apple / CloudKit / WatchConnectivity / Health、真人 VO / 触觉或最低17/10 runtime验收；按用户授权继续后续任务，不需要当前用户协助。
