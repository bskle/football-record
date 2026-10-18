# NATIVE-023：schema4、原 Session 与 HTTP 纵向

状态：本机软件实现及作者最终完整验证完成，作者冻结交两位非作者 exact 审阅。未预填审阅、actual merge、同步、SDK所有权移交或清理通过。

- 作者：m4_session；唯一 worktree `/Users/liam/.codex/worktrees/m4-session-authority/20260830_足球记录`。
- 分支：`feat/m4-session-authority`；attachment `01a14fd7-5113-7dd2-8c29-c64d7f18b94a`。
- 原始 base_ref/target：dev；完整 base / 开工 target / 初始 HEAD：`8d6ec935efa060ab462b2913ab8460734871ff40`，初始 clean。
- 最新已验证合并目标：dev `17f2e39adcdbc633682992d5e5e2f348dbc940e6`。已普通 no-ff 合入已审027、029～036与GIT005/006；不消费未审代码。
- 作者最终运行 source：`5ee7bd33721a9015e23dfe23fd0e31c15fafd211`。最终仅两卡文档提交，完整final SHA、clean及223个相同产品输入的blob/SHA证明置树外manifest，避免提交自引用SHA。
- 所有权：`native/Packages/MatchCore/**`、`native/Modules/AccountKit/**`、必要`scripts/native/verify.sh`、本卡及验证卡；未写他人模块、工程配置或生产Bootstrap。依赖来源及实际红绿保留验证卡和Git历史。

## 软件交付

| 切片 | 实际行为 |
| --- | --- |
| 023.1 | schema0～3 additive到4；SQL故障rollback/reopen、partial4/future5；原canonical/receipt/packet/ACK bytes保持。 |
| 023.2 | Node固定bytes经CryptoKit；真实HTTP acquire/query/fresh-held到原Session；COMMIT丢响应同意图恢复；已知终态不续采，合法已有比赛允许离线恢复。 |
| 023.3 | 一个facade完整facts/tombstone/token/generation CAS原子导入；历史只读；当前完整云proof+永久normal release才完成；异常终结先本地事务再原compare-release。 |
| 023.4 | 独立production grant/envelope及持久route/inbox/ACK；signed roles/activePhoneID、公钥、epoch、域与签名强制；原v2 bytes和M3 development guards保持。 |
| 023.5 | 实际HTTP auth/recovery/032 knownAbandoned、持久control backoff、两轮正常迁移/七天丢失窄授权、删除saga/统计；identity generation/SQL CAS/vault晚写门闩；033非空purge永久fence重开重试。 |
| 登记闭环 | Watch持钥、Phone仅授权中继、原attempt/receipt持久、Watch-only vault；显式submit/recover；036 pinned signed closed proof后才结束unknown，late成功不覆closed。 |

SessionRepository原required方法未扩大，附加能力由同SQLiteSessionRepository/Store和原Session队列实现。网络/SDK await不在SQL或同场队列内。normal仅原recorder PoP，phone opaque HTTP relay不重编码签名请求。删除originalScope首次同事务固定，wrongSpace/原UTF8不同zone不碰driver或进度；未知旧scope不推断、不显示finished。

## 最终作者验证

本轮同一source完整脚本实际exit0，591项/0：Node161、Core257（44 Core /149 Store /47 Session /17 Sync）、CloudSync80、AccountKit54、Presentation39。12项最低iOS17/watch10 Simulator产品（Store/Session/Sync/Cloud/Account/Presentation各双端）及2个无签名generic Simulator App通过；最低系统未升级。094失败及27d的570/0+12SDK+2App均保留独立旧输入层，不与本轮相加。

036 focused Watch11/0、Core登记3/0；真实TTL未送达重开红1项4fail已闭环。十类篡改、closed COMMITlost、只有fence无原row401、双端身份变化、闭合fault/reopen和late成功反例均在最终全套。`S23-watch-ttl-1`本机软件缺口已关闭，不替代真实SDK/账号验收。

## 024 / 025 / 026交接

实际公开API、初始化、持久查询、稳定ID、retry/shutdown见[AccountKit README](../../../native/Modules/AccountKit/README.md)。024接AppleSignInDriver、DeviceProofSigner、fenced DeviceCredentialVault及CloudDriver；已有DB缺原key不得换新key，检查与Keychain写必须原子。025使用同facade/Session，查询account/role/suspension、auth原pending/resolution、Watch原attempt/receipt、control queue、latestMigration、deletionSagas、analytics与proof/history状态；不得另造仅内存恢复ID。

026接真实WC typed登记action及原HTTP normal relay、production peer transport、全ownedledger/staging删除聚合。`deletionSagasV4()`含原originalScope/ID/capability，`localDataProgress`聚合一个本地数据结果；默认transport eraser unavailable，单033文件receipt不证明全本地删除。云历史不授旧Workout/原机录制恢复权。SDK/App所有权在root正式交接后转移，作者此处先停写。

真实Apple/iCloud/Keychain/CloudKit/HealthKit/Workout/WC、签名安装、生产配置和服务部署仍待024/026；生产provider/trust/bootstrap保持unavailable，编译不称E2E。008/010/016/018及queued树不动。

树外证据：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-023`；`023-final-manifest.json`、`023-final-evidence-sha256.txt`、六项final Git输入、原红绿与分层日志供root+m2 exact双审。审阅/merge结果由root另记。
