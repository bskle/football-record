# NATIVE-050 Session registration retirement

依据 [M4](2026-10-18-native-m4.md) 与 [Git治理](../../git-workflow.md)。仅修原Session正向身份写入在042永久业务退役后仍可接纳的问题，保留原Lifecycle/Saga控制恢复。

## 登记与所有权

作者cloud，非作者root+m2。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，root普通合accepted042 final `dd38dc2a0f80eb5dbbf3aeac09ab515b7088796b` 后effectiveBase/实际初始HEAD `f2716d21be717e4152b30bf3c59e91a834199b19`，parents2cab+dd38。held026 target `1fea5109dc32e9564f36111df2809f1f85e572ae`。树 `/Users/liam/.codex/worktrees/m4-session-registration-retirement/20260830_足球记录`，branch `fix/session-registration-retirement`，attachment `01a1579a-a24b-7f31-99aa-6e8ef3d0d4f3`，created1792471114；作者已自核HEAD/branch/clean含ignored。

唯一六路径：AccountLifecycleCoordinator.swift、WatchRegistrationCoordinator.swift、新RegistrationRetirementTests.swift、本计划及050任务/验证卡。不改Store/schema/generation/通用protocol/API/Package/工程/SDK、026或其他任务树，不派helper、不自行merge/push/archive。

## 已批准最小边界

五个原Session mutation：saveAuthAttempt、acceptAuthentication、admitWatchRegistrationContext、saveWatchRegistrationAttempt、acceptWatchRegistration（包含Phone传nil binding但保存receipt）。每个入口同步beginBusiness并立即defer endBusiness；environment await后及authority mutex acquire await后requireBusinessActive，再发送原repo SQL。mutex已取得后defer释放，拒绝也不能锁死后续队列。

最后gate到发送原SQL之间不加其他await。gate前已合法发送的SQL属于原inflight工作，业务计数覆盖完整await，retireBusiness必须join真实成功/原错误；不在COMMIT后追加retired来掩盖已写事实，不造新attempt/receipt或撤销真实正面结果。原Store事务identityGeneration CAS继续负责实际身份变化，不新增retirement generation或schema。

admitWatchRegistrationContext实际会持久化admission，跨epoch还可暂停binding/推进generation，故同属完整mutation join而非readonly。纯读取可在读后检查，但不适用该入口。root已批准此代码事实修正。

不把永久门加到shared validateEnvironment/acquire，不blanket gate Lifecycle/Saga/reauth-control、terminal Auth resolution和knownAbandoned Watch closure。当前AccountService fresh signIn/recover也安装binding，属于正向入口；若以后要在retired facade新增纯身份不变reauth，应由明确checked控制路径实现，不暗放业务安装。本任务不新增该能力。

026仍须永久停业务client入口并join整个owned service任务，包含Session返回之后的vault.replace；仅Session计数不证明外层HTTP/vault已排空。所有原写者join后才能freeze/换factory/关DB。

## TDD与验证

先计划commit，再新增真实Core coordinator层测试，不依赖AccountKit/网络/Package变化。用原SQLiteSessionRepository、具体原MatchSession及pinned controlled签名验收据，非fake Session/coordinator。

1. gate后首次入口：五mutation/Phone nil-binding与Watch首次binding零写；原attempt/canonical/gen保留。
2. 已进入后await：原真实authority mutex队列与environment读取跨退役，醒后typed retired，零SQL mutation，队列释放/退役可完成。
3. SQL门前已admit：机械proxy转发原repo identity及实际SQL，COMMIT后hold reply；retire等待完整await且保留真binding/firstreceipt。失败同样join原错误，不postawait掩盖，不重复SQL；真实close/reopen读回原canonical。
4. 原active身份写、terminal Auth/knownAbandoned closure及Saga/control继续可用，不造新DB/Session作为退役替身。

完整Core单轮与fresh最低iOS17/watch10 Session simulator产品；记录实际数量，不预填。所有Git输入、每命令before/post、红绿原logs和hash放树外NATIVE-050。source冻结后root+m2双审，再仅两卡final窄审。纯原协调器/持久化软件，不执行真实HTTP/Apple/WC/Health/CloudKit/账号/本人设备；不称整个026完成，production defaults保持。
