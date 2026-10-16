# NATIVE-006 验证记录

状态：作者交付，源码 `a69cefd788c47fac9c0ad742d5fb1565c0b22899` 已获 `/root` 质量审和 `/root/m2_review` 规格审 PASS；最终文档/证据复审及主代理合并待执行。基线 `391228dc556afc716dfc3100d6beb78b2ba6c0e0`。作者未合并、推送或归档。

## 最终实际验证

2026-10-16 上海，Xcode 27.0（27A266a），Apple Swift 6.4。在任务独占工作树执行：

```sh
NATIVE_BUILD_ROOT=/tmp/football-record-NATIVE006 scripts/native/verify.sh
```

实际 exit 0；最终日志目录 `/tmp/football-record-NATIVE006/logs/20261016T014117Z`。该次运行的源码与最终交付源码相同；后续仅补三份文档。

| 检查 | 实际结果 | 持久日志（证据根目录下） |
|---|---|---|
| 全宿主 XCTest | 96 项，零失败；MatchStore 52、MatchCore 44；保留 M1 70 项，增加 26 项 | `verify-a69cefd/swift-test.log` |
| MatchStore iOS 17 simulator SDK | 显式 `arm64-apple-ios17.0-simulator` 编译通过 | `verify-a69cefd/store-ios-build.log` |
| MatchStore watchOS 10 simulator SDK | 显式 `arm64-apple-watchos10.0-simulator` 编译通过 | `verify-a69cefd/store-watch-build.log` |
| iPhone App | `CODE_SIGNING_ALLOWED=NO`，BUILD SUCCEEDED | `verify-a69cefd/ios-build.log` |
| Watch App | `CODE_SIGNING_ALLOWED=NO`，BUILD SUCCEEDED | `verify-a69cefd/watch-build.log` |
| 静态及范围 | 最终暂存 `git diff --cached --check` exit 0；仅允许路径 | 文档交付提交及下列输入清单 |

脚本没有修改；旧工程预览 App 只消费 MatchCore，所以脚本仍单独显式编译 MatchStore。Xcode 仅报现有 AppIntents metadata extraction skipped（没有 AppIntents.framework 依赖），没有 Swift 编译警告或测试失败。未删除 FinderInfo/xattr 或他人产物。

## 持久证据与输入

全部证据根目录：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-006`。

- 最终 `inputs-a69cefd.json` 包含 48 个源码、fixture、App、工程、配置及脚本文件的逐文件 SHA256/字节数，另保存各 Git tree/blob ID。
- 输入清单 SHA256：`070b7a41912ba3c0ab1c819755f5993854a0b1bb016fb41334bf3a77bb5c791d`。
- `SHA256SUMS` 汇总所有持久日志、输入清单和已知 fixture 旁文件证据；本次汇总 SHA256：`6c003b5c0550539d74477af6e718f7f6f74ea9e6034c6fdd2b10d338db297d26`。
- `football-record-NATIVE006-full-verify-a69cefd.log` 为完整最终 stdout；此前 fd31699、11f6cfa 的验证分别保留，不能冒充最终源码结果。
- 固定 v1 数据库 SHA256：`1fb3b1a5b82ab64facf88ed4cd92221e5bad5b1de0fdcad62f11acb01db56573`，73,728 字节。由未改的 v1 生产代码实际生成，再冻结原 StoreCommit、receipt、packet、ACK/inbound JSON 和逐列旧表快照；新 encoder 没有重建旧样本。
- 生成 `legacy-rows.json` 时 Python SQLite 曾创建 0 字节 WAL/32,768 字节 SHM；主库 hash 未变。两旁文件已复制到 `fixture-inspection-sidecars/`，核实 WAL 无未提交数据后只移除了这两个已知源树旁文件，未提交运行时旁文件。

## 红测与修复事实

| 阶段 | 实际红测 | 后续结果 |
|---|---|---|
| 迁移/合同 | `red-migration` 实际版本 1 != 2；`red-contract` 缺 CaptureRevision API；`red-failure` 缺正交 failure 字段 | 值校验、v2 新库/固定旧库迁移与 API 绿 |
| lookup 诊断 | 合法 JSON 损坏及 match 索引损坏，真实比赛未得到 blocking 诊断 | 独立 match 索引与 hash/canonical 验证后选择诊断归属；两方向篡改均绿 |
| 操作/确认历史 | `red-history-proof` 12 用例中 7 个断言失败：已保存变未创建、重算 checksum 改历史、旧确认承认新 digest | 历史逐条对照保存的完整 command，保存事实不回退，确认 ID 不可改绑 |
| 双审发现 | `red-review-boundaries` 19 用例中 15 个断言失败：旧确认替换/迁移复用、动作未成功却 settled、删除尾行扫描变空 | 旧/v2 确认共用历史、迁移当前旧 proof、动作结果矩阵及 registry 反向集合复核 |
| 未决保存 | `red-stopped-proof` 清 failure 后 settled；`red-stopped-failure-replace` 更换 failure 后 failed，均各实际失败 | stopped+captureFailed 仅可继续未决 stopped/captureFailed，或进入已保存待关联/真实 linked |

上述短名均对应证据根目录内 `football-record-NATIVE006-*.log`。最初一次迁移测试的只读检查设置报 invalidRequest，修正检查方式后才记录有效的 1 != 2 红测；没有将设置错误冒充功能红测。首次源码提交暂存检查还提示一个 EOF 空行，已在新提交修复；最终检查实际通过，不改写旧提交。

## 已覆盖的边界

固定 v1 七表所有旧 blob/checksum/request_hash/ACK 逐列不变；原 expectedGeneration 重试和响应丢失后 receipt、入站 ACK 保持。v1→v2 三个故障点回滚，无半套新表，部分/未来/物理损坏库保留失败。facts、revision、operation、outbox、receipt 写入故障原子回滚；单机不造 peer。

全局 revision/segment/gap/operation/outbox ID 不覆盖；累计 metadata 可复用同 canonical segment；跨类别/跨场碰撞、缺父/分叉保留原行和新原字节诊断。操作创建/中间 receipt 在后续已结算、generation 推进和重开后仍返回首次结果；不可变请求、状态历史和 command/outbox/revision 损坏不能凭 receipt 确认。恢复扫描用 registry 反向发现被删除的 revision/operation/outbox，旧 proof 不因采集行丢失复活。

两种 snapshot 均过滤过期采集 proof；旧保存入口遇 capture revision 拒绝；空集合有明确 v2 digest 域；确认历史覆盖迁移旧 proof、旧 API 每次保存及新 proof，禁止同确认 ID 改事件或采集集合。linked 必须有同 binding 的真实 Workout UUID segment，仓储不自动补造关联。finish 仅 linked 可 settled；pause 对应 paused/linked，resume 对应 running/linked，start/recover 对应 running/paused/linked。已保存待关联不回到 unknown/notCreated/failed；未证明保存的 stopped 不能清 pending。

## 限制与交接

本任务是真机不适用的纯值/SQLite 事务层，没有 HealthKit、健康样本、位置、服务/UI、真实 peer/传输、账号锁或能力变更。SDK/App 构建不等于真实采集、设备恢复或生产闭环通过。真实 complete-save adapter 仍是可信边界，首次未曾落库的 evidence 来源不能由本地事务层自行认证；commit/ACK 不制造 completed。

008/009 仍须等待 007 已合并接口；作者只交付 006 源码与证据。工作树/临时分支保留等待主代理验收、合并与安全归档。
