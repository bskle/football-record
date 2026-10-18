# NATIVE-037 验证

作者本机软件验证完成；source `66c800f69f329492860a3fd80255c2e4c3592b43`，final仅收尾两卡，actual final SHA/审阅结果记录树外。当前仍 held026，等待 root、m2 exact source/final 双审，不声称任务整体 PASS。输入、工作树和依赖见[任务卡](../tasks/NATIVE-037.md)，设计见[实施计划](../../superpowers/plans/2026-10-19-m4-device-sync-erasure.md)。

证据根：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-037`。本轮独立目录 `assembly-reopen-final/`，含六 Git 输入、22 source 文件 SHA256/Git blob、72 conservative build 输入、80 host 输入、原始命令/日志/工具版本及 SDK header hash。`source-whole-manifest.json` SHA256 为 `e79078eb1ed4281f30bbc1f4951b945d35befb2023dd7ce5d6f3eea91c3cb0a9`；最终两卡及聚合 manifest 另层绑定，不改旧 source 清单。

## 固定 source 的 fresh 完整验证

Swift6.4 / Xcode27.0；最低部署版本不升级。一次 `xcrun swift test --package-path native/Modules/DeviceSync --scratch-path <revision>/build-host`：**69项/0失败**。分项为 ErasureDriver22、Erasure14、StorageFence12、FileInbox5、Message2、Pairing2、TransportLifecycle12；原21项及44a3的62项均在本轮覆盖。真实 child process 是同一 storage gate 用例的子执行，不额外累计测试数；没有重跑018整包331或主线591。

| 产品 target | 最低 triple | 结果 |
|---|---|---|
| DeviceSync | arm64-apple-ios17.0-simulator | fresh Build complete / exit0 |
| DeviceSync | arm64-apple-ios17.0 | fresh Build complete / exit0 |
| DeviceSync | arm64-apple-watchos10.0-simulator | fresh Build complete / exit0 |
| DeviceSync | arm64-apple-watchos10.0 | fresh Build complete / exit0 |

四项实际命令均为 `xcrun swift build --package-path native/Modules/DeviceSync --target DeviceSync --triple <triple> --sdk <actual SDK path> --scratch-path <fresh revision path>`。完整路径、时间、exit及逐输入 hash在各 `*-command.json`；五份日志均无 warning/error。

| 本轮原日志 | SHA256 |
|---|---|
| assembly-reopen-final/host.log | a8ce21cb1c65b12c09417f3429a2e161bdcdd6c2cdfe169cb790a6bc0087b659 |
| assembly-reopen-final/ios-sim.log | 40ad2b60799a159fee843fe649c4b822fb115aa18939d47c16847f5b28edc35a |
| assembly-reopen-final/ios-device.log | eb850e16d8d0d837f7a38d8b7233b28bd8e318abf0c1a4cc38fd00c409504c22 |
| assembly-reopen-final/watch-sim.log | 2056654443e9d31ba6e2c053c3faba0613dd8ed0cc04f49a59cd09ff071e26da |
| assembly-reopen-final/watch-device.log | 99f459f1189a1871154d58d90496f727364b656996e1e86cb70e9bcb7b0e6203 |

current target `e3e4b09d79c1f2556b8648c214f6c3c148ca8cd1` 与 original base `fcf530ada01a7cbf87bbfde598f611d8a35705b2` 的 Core/AccountKit/CloudSync tree 相同，DeviceSync相关 target delta 空；兼容证明不等于已将025 App/工程合入本候选。accepted018及起始普通 merge 层保留，root决定026组合。

## TDD与审阅修复轨迹

原 late-file 实际红1→绿1；初始缺 API编译红明确保留。实现过程中系统 `/var` 别名、目录尾斜线及 control 已存在兼容错误的原日志均保留。durable checkpoint 后 owner/schema 实际红6项/2失败→完整36/0；native dispatch红6/4→绿6/0，shared inventory红8/4，drain/schema红49/8，FD释放及未知 control各红1/1→完整52/0。

| Finding | 实际红 | 修后实际绿 |
|---|---|---|
| S37-replay-inventory-1 | 2项/5失败 | 2项/0；两 receipt入口重验 strict inventory/zero |
| S37-control-budget-1 | 3项/11失败 | 3项/0；编码/解码同64KiB，进度前拒绝 |
| S37-managed-alias-1 | 1项/3失败 | 1项/0；本机支持卷实际同inode别名，非跳过 |
| S37-native-ownership-1 | 3项/9失败 | 3项/0；本root/原transfer与foreign tag矛盾不跳过 |
| S37-assembly-gate-1 | 4项/7失败 | 完整driver suite19项/0；同root正确装配保留 |
| S37-erasure-only-reopen-1 | 缺API编译红后，共享旧native行为runtime红3项/10失败 | 完整driver suite22项/0；原request重开、readiness及实际排空 |

红日志中的 unexpected 分别来自实际误删后读原文件失败或原 fence 确实拒绝重开，原始结果不改记。后两项证据分别在 `S37-assembly-gate-1/`、`S37-erasure-only-reopen-1/`；runtime红前提取的 native active-only/no-readiness行为快照也保留，未伪称在宿主执行真实 SDK。`S37-conflicting-native-owner-1` 是 native-ownership 的旧别名，不另算 finding。

19a durable BLOCK、b0及44a3的预审、所有旧 raw logs 与 manifest 原样保留。44a3旧完整62/0+四 SDK仍是历史输入层，五日志 hash已逐一复核未改；本轮不覆盖旧 `source-input-manifest.json` / `source-git-proof.json`。最终两卡提交不改变 source 产品/测试/计划输入，另由 final manifest 证明。

## SDK与验收边界

四端官方 `WCSession.h` L26–28/L45 明确 delegate+activate 后属性才正确，完成回调存在时 activation异步；L129–130为当前 outstanding 队列。`WCSessionFile.h` L23–27的 cancel为Void，无完成回执。headers实际文件路径/hash列于 `assembly-reopen-final/sdk-readiness-inputs.json`。

native与host共用原request准入、归属分类、activation readiness和取消后重查 helper。永久 fence 后显式 erasure-only constructor只开放保留 control与排空；创建 pairing、普通 install/activate/send/adopt仍受 active gate拒绝。未收到本owner成功回调、当前未activated、未知或矛盾inventory、owned仍未排空，均不能生成完成receipt。取消不是业务ACK或对端召回。

本轮未运行真实 WCSession/授权/账号/设备；四SDK仅产品编译，真实配对重开后的队列可见性、后台回调/精确取消时序仍需本人设备验收。旧未升级执行进程必须由026先失效。一个 namespace receipt不证明全owned catalog、033/024/023组合、备份/物理擦除或远端删除；026仍保护saga/capability/028 selection。生产 provider/trust/bootstrap及App/工程能力均未启用，本候选不合 dev、不发布。
