# NATIVE-049 validation

状态：source `913bb01496e2c5cee0626dcd1fa6e06a281b325b` 已 root/cloud 两位非作者 exact PASS；final 仅两卡待窄审，不预填合入或 whole026 通过。见 [任务卡](../tasks/NATIVE-049.md) 与 [计划](../../superpowers/plans/2026-10-20-m4-cloud-empty-wal-reopen.md)。

## 原因与保全

原诊断在树外 `NATIVE-026/strict-cloud-349-diagnosis-m2.json`，SHA `40aea818499ca8313c73882d3f95067408c9db7d38f2f89fe454d400535ff00c`。原 main SHA `7d8594230add61c28b7b03d7a4a8f682ed8befef6934b2da9747d400daea6650`、inode53691013、61440 bytes保全。同系统 `/usr/lib/libsqlite3.dylib` 3.54.0 unix VFS，exact READONLY|FULLMUTEX 开 main 成功，quick_check 首次 prepare14/extended14/system_errno2；被动 VFS 看到 missing-wal READONLY 无 CREATE 开失败。immutable 诊断成功不充作普通 RO 通过。原026相关42/1unexpected不是049运行。

## 实际验证层次

- 三态 runtime RED：fresh-empty 使用普通公开 init→close 后直接 strict 重开，未 enqueue 或用检查器改变原态；另两态用正常公开 API 准备非空 canonical 及原 firstreceipt/fence，SQLite 正常 checkpoint/close 清协调日志。旧产品三项均因 storageUnavailable 失败（3tests/3failures/0unexpected），最小实现后同三项3/0。
- 边界 focused11/0：主文件替换或原字节变化、交接两时点 WAL/SHM/journal 出现、零长或非regular/symlink sidecar、URI特殊字符和原 UTF8 路径、旧/未来/未知 DDL及坏 canonical保全、缺内部原 receipt/fence不得重建证明。sidecar 从不手工删掉来制造成功。
- source 单轮完整 Cloud108/0（原97+新11），不相加 focused 轮次。四项 fresh arm64 最低 iOS17/watch10 simulator/device CloudSync 包编译分别实际 exit0、Build complete；无真实设备运行。五命令241个 backend/native/scripts 输入各自 before/post及 source Git 对照0差。
- 编译 RED、最初 checkpoint fixture 前提失败及名为 green-three.log 的编译失败均原样另存，不能冒称产品 runtime RED/GREEN。真实三态依据 red-three-loaded-checkpoint.log；source-evidence-notes.json记录上述区分。

树外 `NATIVE-049/source-aggregate-manifest.json` SHA `16cfa409f39c7847a8c22b85fd6e06995f0ceaaf42cb260edb9255999b57708a` 绑定54项证据、5 Git对象、五授权路径和241 runtime输入。root source 审阅 SHA `194246dc6d025f16ca410dda7f94e9d965222b32f8ba6945d9f8a2378a602a85`；cloud source 审阅 SHA `3eefb62e4b4a786bc468e73fed8ca311c465bf9ca4dc9c7769cb284f1b1454a5`。本次仅两卡收尾，复用同源108/0+4SDK，源码/测试/计划和54原证据不变，无重测声明。

## 限制

仅实际14/ENOENT且全 sidecar 缺失、原 FD/path/identity/header/size/mtime/ctime/固定初始长度 streaming SHA稳定时才 provisional immutable；随后 existingRW无CREATE在正常锁内重验全部当前 supported v4布局、canonical/control。可非空，原 erase/replay事务、firstreceipt及普通init/migration不变。任一已有/出现日志不走 immutable；caller先 join owned 写者，点时校验不保证最后指令窗口的任意外部 writer或跨进程互斥。不复制DB、不改header、不使用全局custom VFS、不证明缺失历史日志从未存在。

无实际 CloudKit、真实账号/设备、签名/部署、掉电或 whole026验证。candidate 继续 held026；actual组合、final双审和主代理合入另行记录，作者不自行推进长期分支。
