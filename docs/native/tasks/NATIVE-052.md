# NATIVE-052 删除控制面 fresh reauthentication

状态：已核受管树并提交具体plan/API待root+m2审阅；尚未写产品/测试，未声称source或whole026通过。作者cloud，非作者root+m2。

依据[计划](../../superpowers/plans/2026-10-20-m4-deletion-control-reauth.md)与[合同追加段](../contracts/m4-account-lock-cloud.md)。initialbase `2cab4640ee3a375da39fdabf0f5a317600b0c263`，accepted050 `c031a15a5dfd1aa51f219770c6cee57bdc36006c`及046 `f05e987b3c91fef81f34e22a588d77915a6648db`普通合入effective `07c1b92a75d1c9998afecbfb8cb731a464b414af`。登记held026 target `0e7292df9b1f4eef2edc31d3d7954eee92ceb892`。branch `fix/deletion-control-reauth`，tree `/Users/liam/.codex/worktrees/m4-deletion-control-reauth/20260830_足球记录`，attachment `01a157d5-d491-7062-b011-005625f415a7`。HEAD/parents/branch/clean含ignored已核。

固定20paths见计划：backend+Core+AccountKit一位作者，三卡及合同仅追加新purpose说明；无database/schema、旧receipt/旧canonical、Package/工程/UI/SDK或旧business gate改动。专用fresh流程只恢复原删除parent，不走generic建身份分支；原device/cap/Apple/currenttx验证后可预留原client intent absent→requested。原delete bytes不改，appleRevocation不回退。控制凭证仅原delete/query及精确原锁status/明确abnormal，不能normal/acquire/放新锁。

新控制Store入口须同SQL查原Saga/control/cap/rawscope/key/gen，保留firstbytes及unknown恢复；仅最小retained控制行，不造Match/permit/capture。046/045/LocalErasure与kind/ID兼容须实际验证。全部服务owned任务finalstop/cancel/join，原vault先SQL后同gen更新，业务永不重启。计划确认后才真实TDD，结果与限制写[验证卡](../validation/NATIVE-052.md)。不merge/push/archive，默认Unavailable、真实账号/SDK/设备/部署边界保持。
