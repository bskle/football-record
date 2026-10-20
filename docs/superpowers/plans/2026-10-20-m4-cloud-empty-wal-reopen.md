# NATIVE-049 无 sidecar WAL 既存重开

依据 [M4计划](2026-10-18-native-m4.md) 与 [Git治理](../../git-workflow.md)，仅修复已审047在系统SQLite对合法无WAL/SHM文件只读开库返回14/ENOENT的兼容缺口。普通init、迁移、原erase/replay及证明域保持。

## 登记

作者m2，非作者root/cloud。base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，root普通合accepted047 final `b3c078616ddacebca839533ac1a88138d0902df6` 后effectiveBase `85b3bf6bb8fb7ebf172ac832a57c4fb57bcfe400`。held026 target `2775d77e391497e6fe92ee777b3eb49f7cbdde5d`。树 `/Users/liam/.codex/worktrees/m4-cloud-empty-wal-reopen/20260830_足球记录`，branch `fix/cloud-empty-wal-reopen`，attachment `01a15787-1ab5-7353-95bc-c3d9d6c01d0f`，created1792469834。已独立核HEAD/parents/branch/clean含ignored。

仅五路径：SQLiteCloudLedger.swift、新CloudLocalTransportEmptyWALTests.swift、本计划及049任务/验证卡。不写026/048/原047树、Package、工程、SDK、schema、receipt或通用协议；不派代理、不merge/push/archive。

## 已批准算法

1. 原regular文件dev/inode及只读FD保留；bounded100-byte合法WAL头、size/mtime/ctime和固定初始长度的bounded-memory streaming SHA前后比对。不复制数据库，不全量Data加载，不加任意文件大小上限。
2. 先原正常RO。仅实际CANTOPEN14且system_errno=ENOENT2（在finalize/close覆盖之前捕获）、原main稳定、原前后精确-wal/-shm/-journal全无，才准私有短暂immutable只读解析。已有或出现任何sidecar，包括零长或非regular、热journal，不能走该分支，不删/忽略任何日志。
3. immutable仅全quick_check、原exactv4/autoindex、全部canonical/control校验；完整supported current state可以非空，原firstreceipt/fence照验。其journal_mode=delete仅该连接语义，不替代原WAL头。v3/future/unknown/malformed在RW前拒绝保全。
4. 关闭临时RO，再核原FD/path身份、元信息、header、streaming SHA及sidecar全无。existingRW无CREATE，在正常SQLite锁内重复全部验证，再设connection同步FULL。没有DDL、迁移、business写或proof重建；原erase及expected replay事务不改。
5. caller先join全部owned写者；本leaf是点时控制，不宣称跨进程互斥，不能保证任意外部writer在最后指令窗口创建热journal。已出现/变化侧文件当前尝试拒绝，properRW及原事务仍须再验当前事实。

## TDD与交付

先运行原fresh-empty建库关闭后直接strict重开（不enqueue/检查器造副作用）的真实RED；另用正常publicAPI准备非空canonical、原firstreceipt checkpoint后三态。新增边界覆盖：坏/旧/未知结构保全、主文件变化/替换、WAL/SHM/journal出现、UTF8路径与URI字符、firstproof不改、正常liveWAL保持。各运行和原失败fixture独立保留，不混API编译或辅助失败。

source冻结后单轮完整Cloud及iOS17/watch10各sim/device共四fresh最低SDK，逐命令输入before/post和Git等价、原log/hash进树外NATIVE-049。source root/cloud双审后仅两卡final，再最终双审；held026不提前进入长期分支。无真实CloudKit/账号/设备/掉电/whole026完成声明。
