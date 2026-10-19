# NATIVE-038：Presentation checked装配与查询边界

状态：本机软件实现及作者验证完成，等待 root+m2 exact source/final 双审。唯一作者 `/root/m4_cloud`；作为026上游接缝交付，不提前消费或代替026整包验收。

- original base/登记 target：`e3e4b09d79c1f2556b8648c214f6c3c148ca8cd1`。
- current target：`0744708e4b4cf892e36e6cce18135b4815de2f24`。e3→074仅GIT008六文档，九授权路径及89build/98host运行时输入零delta；按root裁定不合入该纯文档更新或重复SDK，root后续普通合并到最新dev。
- source：`e39cc2b24499404fd38b76e932a3c4b0ab702d5f`；final仅两卡收尾，actual final SHA、审阅/合并状态只记树外manifest/registry，不回写自SHA。
- branch：`feat/m4-presentation-boundaries`；tree：`/Users/liam/.codex/worktrees/m4-presentation-boundaries/20260830_足球记录`。
- attachment：`01a1560b-0e05-7df1-b0fb-fa92514b2d46`；createdAt1792444927。写入前已核实际HEAD/base、分支和clean。
- 所有权：三个MatchPresentation source与其三个existing tests、本卡、[验证卡](../validation/NATIVE-038.md)、[实施计划](../../superpowers/plans/2026-10-20-m4-presentation-boundaries.md)，共九路径。未写Core/AccountKit/CloudSync/Apps/工程/配置/共享脚本，未回写037/026或其他树。

遵循[M4母计划](../../superpowers/plans/2026-10-18-native-m4.md)、[Git治理](../../git-workflow.md)和已双审026 blueprint。先缺API红、旧unchecked行为runtime红，再最小检查实现、绿后明确路径Conventional Commits。作者不推进长期分支、push或archive。

## 公开交接接口

`try await AppBootstrap.accountContext(repository:session:recording:account:lifecycle:close:)` 接收已经存在的 SQLiteSessionRepository、原 MatchSession、RecordingModel及两个状态模型。比较session/model的原facade token、recording.session具体对象和status repository actor；不以相同namespace代替同连接，不新建资源，拒绝时不调用close。AccountAppContext.init仍internal；原rootDirectory默认工厂保持Unavailable。

`try await account.admitIdentity(binding, expectedIdentityGeneration: generation)` 仅在026已完成真实 AccountService/WatchRegistrationService 当前身份admission之后调用。本接口不认证；核exact持久binding每个ID的UTF8、epoch/role/environment/suspended及读前后generation，await后再核持久generation与本地token/stopped。pending、waiting、Unavailable沿用既有phase。公开init不接受verified bool；025 Debug内部旧init/confirmIdentity保持internal。`requireReload()`公开但只单调收紧，readmission不清它；老RecordingModel shutdown和老context stop均不能被重新激活，026须显式重建新composition。

`try await lifecycle.projectCloudScope(scope, expectedIdentityGeneration: generation)` 只投影非suspended current binding的account/cloudSpace/epoch，或同facade中retained deletion saga的exact originalScope（含zone原UTF8和epoch）。suspended时只允许后者；不是admission或读写授权。更新会清旧cloudSaved/backendStatus/cloudIssue并使旧await失效；先启动的投影/refresh不能覆盖新scope。旧025 internal setCloudScope兼容保留。

## 实际验证与保留边界

固定source一次fresh完整Presentation **74项/0失败**（原02563项+11新增），最低iOS17/watch10两项simulator MatchPresentation产品编译通过。没有运行其他依赖包测试、App/XCUI、真实SDK/账号/设备；不累计旧615或591。本任务仅装配/查询校验，硬件不适用；真实认证/SDK能力、026整包组合、签名/设备与部署仍由后续验收。

日志有两个原Core unused-binding warning，Core文件与base原bytes相同，不跨所有权修复。完整命令、红绿计数、hash及限制见验证卡。final仅两卡，所有产品/测试输入与上述source一致，clean停写交双审。
