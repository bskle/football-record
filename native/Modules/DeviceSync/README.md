# DeviceSync（独立 held037）

保留018 v2 opaque frame canonical bytes、摘要及 `WCSessionDriving` 原 required 方法。037增加单个已证明独占归属的 `DeviceSync` root 逻辑清理；默认擦除driver为 unavailable/unresolved。真实WC、签名、配对、账号、设备和026整包验收未完成，不因本模块host/编译通过而入dev。

## 目录与归属

固定 `<namespace>/DeviceSync/{inbox,outbox,state}` 共用 `.control/.owner` inode 锁与SQLite control。026先构造 `DeviceSyncStorageContext(root:)`，由已验收catalog提供原 account/cloudSpace/zone UTF8、epoch、namespaceID、catalog revision/digest和实际rootIdentity，调用 `bind` 后才构造managed叶子/显式system工厂。组件校验值与持久owner一致，不能证明catalog的真实来源或覆盖所有目录。

只有fresh空root可首次绑定；非空unbound legacy、未知control、混合或损坏均保留并拒绝，不从帧/文件名/当前登录账号猜归属。旧标准构造器同门；任意standalone leaf有专用gate，不支持namespace erase，也不能进入managed祖先建立独立内层gate。大小写别名失败关闭，不把generic临时父目录当共享root。root/control/owner inode与parents保留，无unfence；026恢复保留云时先失效旧实例，再显式选新namespace。

## 擦除与重试

`DeviceSyncErasureService` 接受原parent saga requestID/digest与不可变binding，先严格枚举，再持久原请求/冻结transfer身份/永久fence，随后可选 `DeviceSyncErasureDriving` 精确取消并排空已知owned队列，删除本root已验证文件、复核zero，最后持久最小receipt。也可调用已正确装配的 `WCSessionTransport.erase`；不支持可选能力的driver只返回unresolved，不伪造完成。

SQLite事务与unlink不是同一个原子事务。中断后只恢复原请求，先前receipt保持不可变；每次重放也须重新验证当前strict inventory/zero，恢复的known canonical或unknown文件不会被已有receipt掩盖。所有control BLOB统一64KiB编码/解码上限；owner、原请求+冻结transfer、未来receipt在进度前预验，超预算不改旧状态或业务文件，不截断/规范化原ID。

未知/损坏/未来schema不重建；既存schema0也不能自动重置永久fence。owner inode及路径替换失败关闭。跨handle/进程操作共用retained inode锁；最后handle释放可关FD，inode文件仍保留。故障audit、pairing、outbox completion/recovery以及queued actor交付都受同门约束。

## SDK边界

实际原生activate/sendMessageData/transferFile/cancel同步调用与fence共用storage→driver锁序，不持锁await；delegate先释放driver锁再进入storage。文件callback在stat/read/copy/audit之前检查。异步SDK返回后transport再次核验，迟到成功不能恢复active或返回可继续推进的成功。

新SDK-local metadata带namespace/owner digest，不改变v2帧或业务canonical。原生inventory区分owned/foreign/unresolved：只有完整原transfer身份吻合才可取消；外tag与实际outbox目录inode、原token/checksum或本owner digest矛盾时unresolved，不能借foreign分类跳过。真正其他namespace/外路径保留；未知或仍未排空阻完成。原legacy exact mapping保留。

使用真实 `WCSessionFileTransfer.cancel()` 句柄，不做global cancel。`sendMessageData`无SDK取消句柄，只结束本地waiter；取消与native completion都不是业务ACK或远程召回。

## 026交接

receipt只证明一个声明目录的逻辑canonical清理与有界队列结果，不代表物理擦除、备份、CloudKit、其他设备、全owned catalog或全账号删除。026还须聚合033全部owned ledger、024 asset staging、023 Store，并保护saga/capability/028 selection。未受037约束的旧可执行进程必须先失效/退出，不能用新sidecar追溯约束未升级代码。

实际软件验证层次、源码SHA和限制见[验证卡](../../../docs/native/validation/NATIVE-037.md)。本模块不导入AccountKit/CloudSync，不改App/工程/production provider、trust或bootstrap。
