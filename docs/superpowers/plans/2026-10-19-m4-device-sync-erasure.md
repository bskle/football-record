# NATIVE-037 DeviceSync 擦除实施计划

root+m2 已通过方案方向与 root 最终决定。输入、工作树和审阅者见[任务卡](../../native/tasks/NATIVE-037.md)。用户授权先推进本机范围，无额外产品决策。

## 不变量

固定 `<namespace>/DeviceSync/{inbox,outbox,state}` 共用持久 storage gate。SQLite control、`.owner` inode、root 与父目录保留；所有同步 filesystem/SDK dispatch 在 storage→driver 锁序下进行，不持锁 await。旧标准构造器必须同门；任意 standalone 采用专用 gate，不能绕过 managed ancestor，不能声称整 namespace 擦除。

026 提供 namespaceID、原 account/cloudSpace/zone UTF8、epoch、catalog revision/digest 和 root identity 的受验收归属。037 对持久 owner 精确核验；fresh 空 root 显式 bind 后写，非空 unbound legacy/混合/未知不迁移、不删除。控制记录不含 canonical 业务 bytes。无 unfence；新激活只能由026失效旧实例后选新 root。

文件清理不是 SQL 与 unlink 的原子事务：先持久 fence+原请求，后 owned SDK cancel/strict unlink/zero，再 receipt。COMMIT 丢响应重开重放原 receipt；中间失败保持 fence 和原 intent。未知 SDK metadata/取消未排空/driver unsupported 不能 completed。sendMessageData 无 SDK cancel handle；只结束本地 waiter，不能声称远程召回或业务 ACK。

## Slice 1：写入门与 durable control

1. 用现有 transport 真实文件回调复现 invalidate 后落 canonical 的 runtime 红。
2. 写 SQLite scope/binding/fence 原请求/未来坏库、双 handle 与原字节测试；按红绿实现 Foundation-only DTO、retained owner+flock 与 gate、SQLite control。
3. 标准和 standalone 构造器全部同步 gate；adoptFile 在 stat/read 前 gate，失败 audit 同门；outbox/pairing mutation 同门。旧 fixture 调整仅显式绑定，不弱化断言。

## Slice 2：擦除服务与故障

1. 先写真实文件 inventory、空/非空、多 scope/其他 root、request 冲突、先 receipt、before/after COMMIT、部分 unlink、重开测试。
2. 实现可选 erasing/driver 能力、先持久 fence 后取消与清理，保留最小 control；strict all-entry inventory 和末尾 zero，未知/损坏不静默忽略。
3. 两 handle/child process、inodes/路径替换、future schema 与 corrupt control 原文件保护；SDK 等待期间不持 storage 锁。

## Slice 3：native dispatch 与验收

1. 受控 driver barrier 先测 callback/dispatch 两顺序、owned/foreign/unresolved inventory、取消错误/未排空、late completion/reply/error。
2. 实际原生 activate/sendMessageData/transferFile/cancel 调用在同 gate；native对象不跨 Task，回调先释放 driver 锁再进 storage。保留 v2 canonical/hash 与旧协议 required functions。
3. 完整 DeviceSync host；fresh arm64 iOS17 sim/device、watchOS10 sim/device 四编译。README/卡记录真实范围和026桥接责任。
4. 精确 manifest/source/final、clean 停写交 root+m2，不 merge/push/archive。最终卡收尾也审阅。
