# DeviceSync（held037）

原018 v2 transport 保持 opaque frame canonical bytes、摘要及现有 required driver 方法。037提供单个已明确归属的 `DeviceSync` root 逻辑清理；默认擦除driver unavailable，尚待026全组件接线和真实设备验收。

固定 `<namespace>/DeviceSync/{inbox,outbox,state}` 共用 `.control/.owner` inode 锁和 SQLite control。调用方先构造 `DeviceSyncStorageContext(root:)`，从026受验收 catalog 提供原 tuple/epoch、namespaceID、catalog revision/digest、实际 rootIdentity，再 `bind`。只有 fresh 空 root 可首次绑定；非空 unbound legacy 保留并拒绝，不从帧/文件名猜账号。旧标准构造器同门；任意 standalone leaf 有专用 gate，不支持 namespace erase，不能绕过 managed ancestor。

`DeviceSyncErasureService` 先严格枚举、持久原请求与永久 fence，再调用可选 `DeviceSyncErasureDriving` 排空已知 owned queue，之后仅删该 root 已验证文件并复核零，最后提交最小 receipt。SQLite事务与unlink不是同一个原子事务；每阶段重开只恢复原 requestID/digest，未知/损坏/未来schema不重建或声称成功。相同receipt重放，异意图冲突。`.control`、owner inode、root及parents保留，无unfence；以后恢复保留云须026先失效旧实例，再显式选新 namespace。

此receipt只证明一个声明目录的逻辑 canonical 清理与有界队列结果，不证明全owned catalog、物理擦除、备份、CloudKit、其他设备或全账号删除。026还须聚合033全部ledger、024 asset staging、023 Store并保护saga/capability/028 selection；SDK cancel 不代表业务ACK或远程召回。

本阶段36项host通过；原生dispatch/cancel接线与四最低SDK最终结果见任务卡，未完成前不作全037通过声明。生产provider/trust/bootstrap保持unavailable，本模块不导入AccountKit/CloudSync。
