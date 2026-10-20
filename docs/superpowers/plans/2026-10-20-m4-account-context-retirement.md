# NATIVE-048 Account context early retirement owner

依据 [M4](2026-10-18-native-m4.md) 与 [Git治理](../../git-workflow.md)。只补038 checked context公开关闭入口的早期完整owner委托，不创建Session/Runtime/DB、不修改Core或026。

## 登记

作者cloud，非作者root+m2。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；root普通合accepted042 final `dd38dc2a0f80eb5dbbf3aeac09ab515b7088796b` 后effectiveBase/实际初始HEAD `3007d06e0c6b4d44f07573cfc410b6ac172fc078`，parents2cab+dd38。held026 target `5658e4fb8b50c16026f964921c64868938b6666b`。树 `/Users/liam/.codex/worktrees/m4-account-context-retirement/20260830_足球记录`，branch `fix/account-context-retirement`，attachment `01a1577b-3fef-7bc0-9ce7-9ca1544de606`，created1792469057；已自行核HEAD/branch/clean含ignored。

唯一五路径：AppBootstrap.swift、新AccountContextRetirementTests.swift、本计划、048任务/验证卡。不改RecordingModel/Core/SDK/Package/026/App/工程或其他树，不派helper，不自行merge/push/archive。

## root已批准API与顺序

在现checked `accountContext`及internal Context init新增 `shutdownOwner: (@MainActor () async -> Void)? = nil`，放原`close:`之前，保持旧显式及trailing-close调用source兼容。同原facade/Session验证不放宽，失败不运行任何callback。

公开shutdown先检查shared task再检查closed，确保并发调用join同一关闭；同步closed/account.stop/lifecycle.stop/recording.beginRetirement。共享task若有owner立即await完整owner后return，不先Model.join、不继续legacy closeResources。nil仍严格Model.shutdown→closeResources，不前移原直接关DB回调。

owner负责原Session.retireBusiness→Model.shutdown→资源close，持久观察失败保留原facade/失败状态供explicit retry；Void不作成功proof，失败不得触发默认close。owner不得反调context.shutdown形成互等。026实际接线和将Session gate移至identity-task join前由integration作者完成；048不写该文件。

早期retire hook会把durable失败/资源关闭拆成两个协调边界，因此本任务采用已有完整owner，而不新增Core gate API、任意verified bool或另一资源所有者。

## TDD与验证

先提交计划，再缺API compile RED；最小接受但忽略owner占位后，以真实checked publicContext/同一file SQLite facade的转发proxy，仅hold原intent commit reply与其后snapshot reply，分别实际运行RED。proxy转发原connection identity、不伪造token；唯一原Session仍由caller注入。释放后首次permit/GW均应0，原intent事实保留，DB不先关。

补nil原路径、并发public关闭join/owner一次、原held正向capture落盘后再关DB、owner持久失败不fallback并由原owner explicit SQL-only retry、错装配不调用owner。保留原80 Presentation回归；计数只记实际完整单轮。source冻结后fullPresentation、四fresh最低iOS17/watch10 Debug/Release sim产品，核现默认App调用source兼容；本任务不改App调用，额外App构建仅实际签名/调用影响出现时增加，026最后做完整App。

原红绿日志、精确Git/input before-post/evidence哈希保存树外NATIVE-048。root+m2 source双审后只两卡final再审；不声称真实SDK/账号/本人设备/部署或整个026验收。生产默认Unavailable保持。
