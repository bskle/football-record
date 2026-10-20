# NATIVE-048 Account context retirement

状态：source `649338d439c61f7e41b5bdee8948c959af7a4bbf` 已获root+m2双审 `PASS_SOURCE_HELD_026_ONLY`；本次仅两卡收尾，等待exact final窄审。未合入026或dev，不代表whole026验收。作者cloud，非作者root+m2。

按 [计划](../../superpowers/plans/2026-10-20-m4-account-context-retirement.md) 的五路径完成。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，accepted042 `dd38dc2a0f80eb5dbbf3aeac09ab515b7088796b`，effectiveBase `3007d06e0c6b4d44f07573cfc410b6ac172fc078`，held026 target `5658e4fb8b50c16026f964921c64868938b6666b`；树、attachment、branch见计划，实际HEAD/branch/clean含ignored已核。

checked factory及internal init新增默认nil的完整 `shutdownOwner`，保留原close trailing closure调用。公开shutdown同步停止account/lifecycle及Model入口，再以共享task委托owner；并发调用join同一task。有owner时不先Model.join、不fallback资源close，nil仍原Model.shutdown→close。原同facade/具体Session校验和默认factory逐字未变，无新Session/Runtime/DB，无Core/App/Package/工程/SDK改动。

实际同原SQLite facade的intent COMMIT与snapshot迟到回复回归，旧行为7项/14失败/0unexpected，修后7/0，补旧调用兼容后8/0。完整Presentation单轮88/0（原80+新8）、四fresh最低iOS17/watch10 Debug/Release sim产品和四普通import Swift6公开消费者编译通过。源证据及双审哈希见 [验证卡](../validation/NATIVE-048.md)。

026负责实际接线、原Session gate先于identity/task joins，以及owner失败状态和显式重试；owner不得反调context.shutdown。Void完成不是durability/deletion proof。本任务纯本机关闭装配与生命周期校验，无真实账号/CloudKit/Health/WC/签名/设备/部署执行，生产默认Unavailable保持。source产品/测试/plan已冻结，本卡提交不重测；不自行merge/push/archive。
