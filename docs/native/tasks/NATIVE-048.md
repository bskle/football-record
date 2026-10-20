# NATIVE-048 Account context retirement

状态：已核独立树，按 [计划](../../superpowers/plans/2026-10-20-m4-account-context-retirement.md) 开始TDD，尚未声称验证通过。作者cloud，非作者root+m2。

base2cab+accepted042dd38，effectiveBase `3007d06e0c6b4d44f07573cfc410b6ac172fc078`，held026 target5658；完整树/attachment/branch与五路径登记见计划，HEAD/branch/clean含ignored已核。root批准默认nil完整shutdownOwner、shared task以及原close兼容顺序。

目标是公开Context先同步停UI入口，再早期委托完整owner，避开Model等待Session.execute先于Session gate的窗口。nil沿原Model.join→close，owner不能反调context.shutdown；026负责实际接线、原owner失败/重试与Session gate先于identity joins。见 [验证卡](../validation/NATIVE-048.md)。无Core/工程/SDK/026改动，不创建新Session/Runtime/DB，不自行merge/push/archive。
