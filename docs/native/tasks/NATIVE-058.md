# NATIVE-058：M4 空 authority HTTP fixture 与独立身份观察

状态：仅静态计划交付，等待 root + 第二位非作者计划审阅；尚未准入实现。唯一作者 `/root/m4_native_http_fixture`，不得消费026 WIP或代替原M4/051组合验收。

- original base / 创建后实际 HEAD / 当前dev：`2cab4640ee3a375da39fdabf0f5a317600b0c263`；分支 `test/m4-native-http-fixture`。
- tree：`/Users/liam/.codex/worktrees/m4-native-http-fixture/20260830_足球记录`；原生attachment `01a1620a-0182-7f02-a3f2-6bb32dd43d4f`。写文档前已核branch/HEAD/clean，含ignored无内容。
- merge target：held `test/m4-e2e-integration`，登记时 `acfd8ae569417e20be4b0b346845f03d0317ab77`；只读ref观察已为 `04d994899b08fe43ab0642358272664b33b502b9`。不读其目录/Watch WIP、不把移动ref作为执行输入；root须在026停写干净后重新冻结target。
- 本轮所有权仅 [实施计划](../../superpowers/plans/2026-10-22-m4-http-fixture.md)、本卡、[验证卡](../validation/NATIVE-058.md)。后续拟准入且尚未写：`backend/src/device-auth.mjs`、新 `scripts/native/m4-authority-fixture.mjs`、新 `backend/test/native-m4-fixture.test.mjs`；最小方案不需要新生产模块。
- 禁写共享工程/Swift/UI/锁文件/生产HTTP routes、support/Apple verifier/authority/config/database/codec/lifecycle、其他任务卡/树或长期分支；扩路径先报root并重登记。

依据 [M4合同](../contracts/m4-account-lock-cloud.md)、[M4母计划](../../superpowers/plans/2026-10-18-native-m4.md)与 [Git治理](../../git-workflow.md)。用户已有子代理执行授权；本次停在计划checkpoint，不重复请求用户选择执行方式。

## 计划锁定的最小责任

1. 在device-auth原44行所在模块内纯提取并导出 `accountIDForAppleIdentity(accountHMACKey,identity)`；原authenticate仍在同事务、absence fence/checkChallenge之后调用。原HMAC SHA256、issuer+单LF+subject原UTF8、lowercase hex、production及legacy development语义不变。
2. 新sidecar直接createAuthority + authSetup + createHTTPServer，空file SQLite、loopback、默认实际Unix秒；不调用startFixtureAuthority/openHTTPFixture/login/request/device，不预登录另一Phone、不输出其credential/privateKey、不手写accounts空行、不清activePhone/锁/epoch。
3. 测试专用server observer使用独立内存nonce/60秒生命周期、genuine branded development verifier与verified identity，在await前后核同实际authority/config/key/clock/generation；共用服务端mapper，逐表证明观察零写。只返回currentIdentity，不给accountExists/registered/activationEpoch/grant，不拿config.subject、客户端HMAC或binding冒充独立观察。
4. requestID JSONL stdio只发布无密启动metadata；显式apple op向调用者内存发送真实RS256 development JWT和随机受控code，可复用既有revocation fixture；fault仅既有故障，restart只同进程保留原DB/keys/clock，完整await close，不增加生产HTTP身份API或CloudDriver。真实Apple账号/授权码、CloudKit观察、跨进程secret协议不在范围。
5. 测试按TDD验证品牌拒绝/nonce/audience/过期/身份隔离、所有表前后原bytes零写、原HTTP first-device仍registered/active及独立ID一致、原故障恢复与完整backend回归。two non-author source/final审阅后由root no-ff合入停写干净026，按052 target回归；不进dev/release/main。

## 本次交付与依赖

只完成静态源码/API/合同核准与三文档计划；所有运行验证checkbox保持未勾选。2cab→固定acfd差异表明原身份映射未变，052在目标侧增加删除控制路由/purpose/nonce budget；合入时保留其已审修改，不以本树文件覆盖。原生M4 current identity输入及051真实链仅下游026在固定组合中消费，058不改Swift或直接bindAccount。

精确输入副本、四份acfd参考研究的hash及whole-tree/提交证据见验证卡与树外manifest。最终提交SHA不回写自引用，由 `planning-final-manifest.json` / `planning-checkpoint.json` 记录。作者计划提交后clean停写，不运行Node/HTTP/SQL/test/build/设备或模拟器探测，不push/merge/archive/delete/rebase。

本任务为host fixture与纯函数提取计划，当前真机/SDK编译不适用；后续自动通过也不等于真实Apple/CloudKit/Keychain/WC/签名/设备/生产部署通过，不宣称M4或026完成。本树为026活跃依赖保留；全部必需目标接收且无依赖并保存必要ignored证据后，root先原生archive、核实际成功、再安全branch -d，queued/拒绝保留且不强删。
