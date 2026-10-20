# NATIVE-050 Session registration retirement

状态：source `60b78241ba20dbc91cdea50280f3db5d6d33b8ce` 已root+m2两位非作者 exact `PASS_SOURCE_HELD_026_ONLY`；本次仅两卡final收尾，等待最终窄审，不预填merge或whole026完成。作者cloud，非作者root+m2。

按 [计划](../../superpowers/plans/2026-10-20-m4-session-registration-retirement.md) 六路径完成。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，accepted042 `dd38dc2a0f80eb5dbbf3aeac09ab515b7088796b`，effectiveBase `f2716d21be717e4152b30bf3c59e91a834199b19`，登记held026 target `1fea5109dc32e9564f36111df2809f1f85e572ae`。树/branch/attachment与登记见计划，HEAD/branch/clean含ignored已核。

五个原Session mutation入口用既有beginBusiness/defer endBusiness计数，并在environment和authority mutex await后重查永久门。gate后首次入口及原锁/读等待者均不能首次写身份；门前已admit的原SQL完整await被退役join，保留实际成功/原错误，不postawait retired掩盖COMMIT。admitWatchRegistrationContext实际持久写入也计数；Phone nil-binding仍属正向registration receipt写入口。

最小产品delta为两协调器+15/-10，Store schema/generation/CAS、通用protocol/API/Package以及terminal/knownAbandoned/Lifecycle/Saga控制段逐字未变。真实原SQLite/Session、pinned验签receipt与原COMMIT后held回复测试：稳定runtime RED8项/76失败/0unexpected→同8/0；完整Core单轮276/0（44Core+149Store+66Session+17Sync），两fresh最低iOS17/watch10 Session sim编译通过。详细原证据和双审哈希见 [验证卡](../validation/NATIVE-050.md)。

026仍负责永久停业务client并join完整owned HTTP/service/vault调用，尤其Session返回后的vault.replace，再freeze/换factory/关DB。本任务不创建另一Runtime/Session/DB，不证明HTTP/vault实际排空；原reauth-ID/capability控制恢复保留，freshApple安装binding属于业务入口。本卡收尾不重测、不改产品/测试/计划，继续held026，不自行merge/push/archive。纯协调器软件，无真实账号/SDK/设备/签名部署操作，默认Unavailable保持。
