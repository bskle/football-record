# NATIVE-023：schema4、原 Session 与 HTTP 纵向

状态：收尾执行中，删除scope修复和Watch客户端登记已补；最终完整验证等待035已审测试修复合入后执行。两位非作者 exact 审阅、actual merge、同步与清理均待主代理，不预填通过。

- 作者：m4_session；唯一 worktree `/Users/liam/.codex/worktrees/m4-session-authority/20260830_足球记录`。
- 分支：`feat/m4-session-authority`；attachment `01a14fd7-5113-7dd2-8c29-c64d7f18b94a`。
- 原始 base_ref / target：dev；完整 base / 开工 target / 初始 HEAD：`8d6ec935efa060ab462b2913ab8460734871ff40`；初始 clean。
- 最后已验证合并目标：dev `71251f9afbb299e97344ff082c1d83bf17a110df`；已普通 no-ff 合入已审 027、029～033 与 GIT005/006。前轮运行 source：`094c690775809eb9ce40d82d19a139ff5d9ea4d3`；最终两卡提交的完整 SHA 与相同产品输入证明放树外 manifest，避免自引用 SHA。
- 依赖：021 final `a55dab4d10bf2b10011c81a49a30128cd9f835ad`；022 final `b648b730fbb9929453c32a43b12bc77bd2d67faf`，均已双审合入实际 base。后续已审接口来源与每次合并保留 Git 历史和验证卡。
- 所有权：`native/Packages/MatchCore/**`、`native/Modules/AccountKit/**`、必要 `scripts/native/verify.sh`、本卡与 `docs/native/validation/NATIVE-023.md`。未写他人模块、工程配置或生产 Bootstrap。

## 交付范围

| 切片 | 实际软件行为 |
| --- | --- |
| 023.1 | schema0～3 additive 到4；故障 rollback/reopen、partial4/future5；原 canonical、receipt、packet、ACK bytes 保持。 |
| 023.2 | Node 固定 bytes 经 CryptoKit；真实 HTTP acquire/query/fresh-held 到原 Session；COMMIT 丢响应同意图恢复；已知终态不续采，已有合法比赛离线恢复仍可用。 |
| 023.3 | 一个 facade 的完整 facts/tombstone/token/generation CAS 原子导入；历史只读；当前完整云 proof + 永久 normal release 才完成；异常终结先本地事务后原 compare-release。 |
| 023.4 | 独立 production grant/envelope verifier 与路由/inbox/ACK；signed roles/activePhoneID、公钥、epoch、域/签名强制核验；原 v2 bytes 和 M3 development guards 保持。 |
| 023.5 | 真实 HTTP auth/recovery、032 knownAbandoned、持久控制 backoff、两轮正常迁移/七天丢失窄授权、删除 saga/统计；身份 generation/SQL CAS/vault 晚写门闩；033 非空永久 purge 后重开重试。 |

不扩大 SessionRepository 必需方法；新增附加协议仍由原 SQLiteSessionRepository / Store 与 Session 队列实现。网络或 SDK await 不在 SQL / 同场队列内。normal 仅原 recorder PoP；phone 使用公开 opaque HTTP relay 工厂原样转发，不能重编码签名请求。

## 当前验证与交接

094旧输入层单轮宿主实际通过：Node128/0、Core253/0（Core44 / Store145 / Session47 / Sync17）、CloudSync80/0、AccountKit42/0（Auth11 / Cloud7 / Control3 / HTTP10 / Lifecycle6 / Migration5）。该轮Presentation39项一项6断言注入失败；12最低SDK及两无签名simApp实际通过，均仅旧层；历史 checkpoint 不与本轮相加。

024/025/026 的实际 public API、初始化、持久查询、恢复 ID、retry/shutdown 与隔离约束见 [AccountKit README](../../../native/Modules/AccountKit/README.md)。025 通过 `deletionSagasV4()` 重开发现原 ID；`localDataProgress` 聚合一个本地数据结果。默认 transport eraser unavailable，026 仍需聚合所有 owned ledger/staging；单文件033 receipt不能替代全本地删除。云历史 API 不授旧 Workout/原机录制恢复权。

真实 Apple / iCloud / Keychain / CloudKit / HealthKit / Workout / WatchConnectivity、签名安装、生产配置与服务部署仍待024/026。生产 provider/trust/bootstrap保持 unavailable；最低 iOS17 / watchOS10 不升级，编译不算真实E2E。008/010/016/018及queued树不动。

树外证据：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-023`。红绿原日志、六项 Git 输入、工具、运行202个产品输入及所有改动/证据 SHA256 manifest 交主代理 exact 审阅；源码/最终审阅结果不由作者声明。

## 最后审阅修复与登记边界

删除scope P1已提交 `ce0d9212373beacc43dd90d6569ad907e9ef3185`：originalScope在原saga控制行同事务固定，wrongSpace/raw Unicode zone重开不碰任何driver/bytes/fence/progress，原scope继续；Lifecycle7/0与StoreLifecycle8/0，缺scope旧记录不能假finished。未改HTTP删除intent或schema版本。

Watch客户端登记归023唯一Core/Account作者补齐：Phone仅授权/中继、Watch持钥与独立vault，原attempt/receipt持久，404/网络unknown不换ID，明确已提交过期只显式fresh；late identity/key/epoch/vault callback拒绝。实际NodeHTTP七项/0，含登记后原Watch Session开赛、COMMIT/query丢响应重开同session、Phone vault不覆盖、DB无Watch token；Core两项/0覆盖Phone/Watch receipt+binding六故障重开与旧epoch拒绝。024/026仅具体SDK/WC driver，public入口见README。该软件登记此前仅有backend harness，本卡现明确纳入023。

上述新增输入与094旧层分开，最终完整host/最低SDK/两App待最新已审034/035普通合入后一次执行；未把旧层或选测计作最终整包通过。
