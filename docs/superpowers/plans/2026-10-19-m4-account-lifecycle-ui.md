# NATIVE-025 账号与生命周期 UI 实施计划

依据已批准 M4 §9、现有原型与57-input接口准备实施，无新增产品决定。作者 `/root/m3_ui`；base `17f2e39adcdbc633682992d5e5e2f348dbc940e6`，已审023 final `f7f7a3bceb3000fd6d655d4724089601870eeb4d` 普通依赖 merge `ba01e83c861f2daa7d0733258097da13390243c6`，最终普通同步 verified dev `fcf530ada01a7cbf87bbfde598f611d8a35705b2`。

- [x] 状态与同 facade：红绿后交付 AccountStatus / LifecycleStatus，唯一 SQLiteSessionRepository / 原 MatchSession，持久读取 / 重开、未知清旧成功、默认统计关闭、删除本地双分项聚合及原 bootstrap / recovery / sync回归。
- [x] Debug纵向：独立 namespace、原 key / identity / pin、Mac监督既有Node HTTP fixture、私有 typed mailbox、真实原 auth / Watch submit-recover / acquire、已登记文件云保存回读、正常双 proof / 原请求恢复。旧库缺原材料失败关闭；App无Process，生产Unavailable，Release忽略开发输入。
- [x] 双端 UI：保留原四tab / 四快捷入口，Phone账号 / 迁移 / 删除四组 / 统计，Watch紧凑账号 / 登记状态；后台锁、异常终结与云状态保持真实来源；身份变化后的现有reload先停旧context再建新context。
- [x] 唯一工程与验证：真实Package依赖及target装配，未写reserved entitlements或发明配置。615宿主 / 12最低SDK、4simApp / 2deviceSDK无签名构建、双端UI / Recovery / 375深色最大字体均有实际分层证据；Release实测隔离。详见[验证记录](../../native/validation/NATIVE-025.md)。
- [x] Conventional分片提交；source `4ec78e879cd8a7cef981540bdeebac39e5e82b95`冻结，root + m2本机软件源码双审PASS。最终仅任务卡 / 验证卡 / 本plan，作者clean停写并移交共享工程 / 模拟器权。
- [ ] 主代理最终文档双审、no-ff实际合并、当前merge输入账号UI复验、同步及按依赖安全清理；作者不得推进永久分支。
- [ ] 026本人账号 / 设备 / 签名 / 容器 / 真实SDK装配、真人VO / 触觉及最低系统runtime验收；本轮软件通过不关闭这些门槛。

所有权为已登记39路径；未改 Core / SDK / backend / verify.sh，未合024候选，未写其他树。配置 / owned ledger catalog、staging及Health确认交接见[配置清单](../../../native/Configuration/M4-capability-handoff.md)，任务信息见[任务卡](../../native/tasks/NATIVE-025.md)。host68cc与后续UITest helper层不冒充同source一次全量；换环境先取消 / join旧资源，禁止复用stopped模型。
