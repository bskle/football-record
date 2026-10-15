# NATIVE-003：SQLite 事务仓储

负责人 /root/transactional_store；依据母计划 M1 和 NATIVE-002 接入契约。先测试后实现，接口不要求 UI、真机或网络。

## 文件与接口

只写 Package.swift、新 MatchStore Sources/Tests、verify.sh、native/README.md、本计划与 NATIVE-003 任务/验证记录。MatchCore、Xcode 配置只读。新增系统 SQLite3 / CryptoKit 依赖，不引入第三方。

`MatchStore` actor 独占连接，WAL/FULL；`commit` 接收调用端已生成的 immutable descriptor/facts/outbox、稳定 commandID 和 expectedGeneration。一次无 suspension 的事务提交 CAS、全部事实、包与首次 receipt。先保存无许可 descriptor 的稳定意图；带 start 的提交必须拥有匹配许可。成功后调用端才采纳 recorder staging。相同命令完整请求哈希一致返回首次 receipt，不一致报错。

`receive` 只接受可信 adapter 已确认的 expected peer/match；验证版本/包校验后把事实与固定 ACK 同事务保存。冲突 payload 隔离保留，不覆盖事实、不产生成功 ACK。`acknowledge` 精确匹配包、SHA256 与接收设备，传输完成不是 ACK，不删除包。checksum 仅检测内容完整性，不做身份认证。

快照暴露 generation、所有原始修订和持久诊断；派生结果交给 MatchReplay。保存可信完成证据仅校验当前事实版本；本地 COMMIT/部分 ACK 不创建该证据、不释放后台锁。未来 adapter 必须验证真实证据与权限。

## 实施顺序与通过条件

- [x] 记录真实 worktree/base/依赖；计划与任务卡提交24227e7。
- [x] 真实临时 SQLite 文件测试：意图恢复、故障事务回滚、关闭重开命令幂等、两连接 CAS、撤销重传不复活；红绿日志保留。
- [x] 乱序/修订先到、全局ID冲突隔离、接收落盘 ACK 丢失重传、错 ACK、版本/checksum/peer 拒绝。
- [x] migration 故障回滚、未来版本DB/WAL/SHM保留、部分schema与物理损坏显式失败且不重建、坏 JSON/checksum 保留 bytes；异常终结/旧完成证据。
- [x] 29仓储测试加原33测试；verify.sh 显式 cross-build MatchStore iOS17/watchOS10 Simulator，并构建两个 App schemes，全部退出0。
- [x] 持久日志、SHA256 与构建输入245252e075487235c27811b493f9bcf518133379；两位非作者源码审阅PASS。审阅补齐恢复发现、receipt数据核验、audit/blocking及全局ID。
- [ ] 主代理复审最终文档后执行 --no-ff 集成、实际 merge 验证，再安全归档与 branch -d；作者不推进长期分支。

验证使用 NATIVE_BUILD_ROOT=/tmp/任务唯一目录，避免 Desktop 元数据污染构建。生产 API 不开放任意 SQL，故障注入仅 internal 测试入口。迁移版本与 schema 同事务；未知或损坏库保留，禁止删库伪恢复。
