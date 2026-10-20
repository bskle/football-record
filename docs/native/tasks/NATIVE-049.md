# NATIVE-049 Cloud WAL reopen compatibility

状态：source `913bb01496e2c5cee0626dcd1fa6e06a281b325b` 已 root/cloud 两位非作者 exact PASS；本次仅任务卡、验证卡收尾，final 尚待两位非作者窄审，未合入026或长期分支。见 [计划](../../superpowers/plans/2026-10-20-m4-cloud-empty-wal-reopen.md) 与 [验证卡](../validation/NATIVE-049.md)。

base `2cab4640ee3a375da39fdabf0f5a317600b0c263`，accepted047 final `b3c078616ddacebca839533ac1a88138d0902df6`，effectiveBase `85b3bf6bb8fb7ebf172ac832a57c4fb57bcfe400`，登记 held026 target `2775d77e391497e6fe92ee777b3eb49f7cbdde5d`。作者 m2，审阅 root/cloud；五路径所有权和原生 tree 标识见计划。

仅对实际 RO14/ENOENT、前后全无 sidecar 的合法 WAL 原文件，先稳定 FD/原身份/元信息/header/固定长度 streaming SHA，再完整 immutable 只读预检，最后 existingRW 无 CREATE 正常锁内重验。支持 fresh-empty、非空 canonical 与原 firstreceipt/fence；任一日志出现、原文件变化或未知结构均拒绝保全。普通 init/migration、原047 erase/replay 和 proof/receipt 域未改；内部同步门闩仅用于确定性文件交接测试，不新增公共 API。

真实三态旧产品 runtime RED3tests/3failures →3/0；新增边界 focused11/0与完整同源 Cloud 单轮108/0（原97+新11）分层保留。四项 fresh arm64 最低 iOS17/watch10 sim/device CloudSync 包编译实际 exit0，五命令241输入 before/post/committed Git 0差。source manifest 的54项证据、源码/测试/计划及原失败 fixture 保持不变；本次文档收尾不重测。

树外 `NATIVE-049/source-aggregate-manifest.json` SHA `16cfa409f39c7847a8c22b85fd6e06995f0ceaaf42cb260edb9255999b57708a`。source 审阅分别为 `review-source-root.json` SHA `194246dc6d025f16ca410dda7f94e9d965222b32f8ba6945d9f8a2378a602a85`、`review-source-cloud.json` SHA `3eefb62e4b4a786bc468e73fed8ca311c465bf9ca4dc9c7769cb284f1b1454a5`；作者不自审。

caller 仍须先 join 全部 owned 写者；此为受协作 owner 约束的点时验证，不证明历史 WAL 完整性、跨进程互斥或掉电安全。原026旧相关42/1unexpected及原61440-byte fixture另存，不将新108/0改称旧026全绿。production 仍 Unavailable；真实 CloudKit/账号/设备/签名部署、049 actual组合及 whole026均未验收，候选继续 held026，不自行 merge/push/archive。
