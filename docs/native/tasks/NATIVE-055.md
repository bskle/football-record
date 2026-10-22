# NATIVE-055：Watch 当前接受来源与只读快照

状态：修订 source `dc9fcee1a869219a5a676d1577fe92c151b7b91a` 已获 root 与 `/root/m4_recovery_audit` 两位非作者 whole/source PASS，R55-1 已闭合，无其他发现。作者仅收尾 task/validation 两卡并停写；exact final 增量双审、实际目标接入仍由 root 安排。

- 唯一作者 `/root/m4_watch_provenance`；base dev `2cab4640ee3a375da39fdabf0f5a317600b0c263`。
- root 普通接收 053 final `e0b88df9e8d694555f5f597f3eea508d3a1acaf1` 与 052 final `bcf2c7fc3b0dfd623f5550618dbf2b55fad3369c`，effective base `27a0aef4dac7f2beb8189303b75a12ac1e1b53da`。计划提交 `2038bad0b935911e24d0ca89d1b0401dfd12567f` 已先双审准入，计划 bytes 保持不变。
- 分支 `feat/m4-watch-current-evidence`；工作树 `/Users/liam/.codex/worktrees/m4-watch-current-evidence/20260830_足球记录`；attachment `01a1618d-fcd3-71c3-9837-a328568ed713`。初始及冻结 HEAD/branch/clean 含 ignored 均已核对。
- 仅交付 held026 `test/m4-e2e-integration`，登记 target `d155eaaeee02384187966f835d85ce94f079c983`，root 实际接入前重核；尚未合入目标，不入 dev/release/main。

[具体计划](../../superpowers/plans/2026-10-22-m4-watch-current-evidence.md)的 10 个唯一 owned 路径均遵守。七个产品/测试路径新增 Store marker/reader、原 facade 转发与两组测试；原 Watch 接受方法只加事务接点，两个条件 consumer 路径仅增加 inventory、DELETE 前和 current-zero 前三处历史验证调用。未改 Backend wire/schema、Package/project、required protocol、AccountKit、旧业务 gate 或生产 provider。

固定 `watch-current-v1` marker 仅由原 Store 的首次 registered receipt + 实际非 nil Watch binding 接受事务产生，与 binding/receipt 原子提交。nil binding 的 Phone authorizer、过期 receipt-only、knownAbandoned、旧 receipt 重放均不补造来源；较新请求的 marker 不因旧请求重放倒退。历史 getter 保留历史原义。

optional `CurrentWatchRegistrationEvidenceReadingV4` 及原 SQLiteSessionRepository 转发从同一原 SQLite `BEGIN DEFERRED` 快照复验 marker、原 attempt/raw receipt、current binding/generation/admission、完整 parent/cloud/Watch tuple 和迁移/删除控制。返回值为不可公开构造、非 Codable 的本地接受证据；无网络/vault/SQL mutation/资源关闭。authority 签名 key 与派生 Watch device key ID 分开，parent/cloud 是本地验证关联，不宣称为不存在的独立 signed claims，也不声称抵御所有 metadata 协同改写或数据库回滚。026 仍需独立身份、原资源 owner、signer/lifetime 与业务准入。

原 source `c55a802b59dbfa94b1a3b8e855d36b3661f26355` 的 whole 审阅发现 R55-1：历史 factory 未把本地环境关联闭合到已签名 receipt.environment。修订仅两原 owned 路径：一条环境 guard 和四个实质回归；历史完整性仍不依赖当前 generation/admission，换父或删除后的合法保留事实不会毒化库存。新 guard 使库存、擦除前、zero、新接受覆盖均拒绝可检测的签名环境矛盾并保全全部 rows/total_changes。

[验证记录](../validation/NATIVE-055.md)：R55-1 运行 RED 为 4 项/8 断言失败/0 unexpected，随后 focused 25 Store + 1 Session = 26/0。新 source 的完整 Core 单命令 **364/0**（44 Core、234 Store、69 Session、17 Sync）、独立完整 AccountKit **80/0**（含原 Watch 11）以及四项最低 iOS17/watchOS10 MatchSession sim/device SDK 编译通过；26 已含 Core，不重复相加，不称一次 444 项。每阶段直接冻结同 212 项输入，含 49 个 Backend 运行依赖；源码 Git/current/执行前后零漂移。

树外旧 c55 3357 份与 R55-1 新 1724 份证据分层保留，源码双审已逐 hash/size 审核；旧 360/0、Account80/0、四 SDK 及早期 Account163 输入层不冒称覆盖此次修订。最终两卡后产品/测试/计划及 212 输入保持 source bytes，exact final checkpoint 另存树外。root 和第二位审阅者为只读审证据，未冒称他们重新执行矩阵。

实际工具为 Xcode27.1 / Swift6.4，最低 iOS17/watchOS10 不变。此本地事务/reader 无需用户连接真机；SDK 只编译，未执行 App/UI、真实 Apple/Keychain/iCloud/CloudKit/Health/WC、个人账号、签名设备、部署或 whole026/M4 验收。生产 Unavailable 保持，无原生冻结/发布。

作者不 merge/push/archive 或推进长期分支。最终双审、实际 held026 no-ff/复验、依赖完成后的安全归档与 branch-d 由 root 负责；在途依赖期间保留该树。
