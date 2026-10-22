# NATIVE-055：Watch 当前接受来源与只读快照

状态：plan-only draft；等待 root 与 `/root/m4_recovery_audit` 对具体计划 exact commit 双审。尚未写产品/测试，尚无本任务新增测试通过证据。

唯一作者 `/root/m4_watch_provenance`。base dev `2cab4640ee3a375da39fdabf0f5a317600b0c263`，root 普通接收 053 final `e0b88df9e8d694555f5f597f3eea508d3a1acaf1` 与052 final `bcf2c7fc3b0dfd623f5550618dbf2b55fad3369c` 后 effective HEAD `27a0aef4dac7f2beb8189303b75a12ac1e1b53da`。分支 `feat/m4-watch-current-evidence`；工作树 `/Users/liam/.codex/worktrees/m4-watch-current-evidence/20260830_足球记录`；attachment `01a1618d-fcd3-71c3-9837-a328568ed713`。作者已核branch/HEAD和clean含ignored。

[具体计划](../../superpowers/plans/2026-10-22-m4-watch-current-evidence.md)定义10个唯一owned paths，其中CapturePersistence/LifecycleStatePersistence仅新marker库存/擦除consumer接点。采用固定版本watch-current-v1本地marker，只在原Store首次接受registered且真正写非nil Watchbinding的同事务保存；过期receipt-only、Phone authorizer、knownAbandoned及历史receipt重放都不补造。历史getter保持历史语义。

optional currentWatch reader与原Session facade转发将同SQL快照复验原attempt/receipt、current tuple/gen/admission和迁移删除控制。它仅证明本地当前接受来源，不授予live credential、resource scope或business/recording权；authority签名key与派生WatchdeviceKeyID分开，parent/cloud为本地checkedassociation。旧缺失/不完整/歧义来源typedblocked；生产默认Unavailable不变。

交付仅held026，登记目标d155eaaeee02384187966f835d85ce94f079c983，root接入前重核。作者不merge/push/archive或推进长期分支。产品前双审、meaningfulRED、完整Core+AccountKit、四最低SDK、source/final双审均尚待执行；[验证draft](../validation/NATIVE-055.md)明确当前证据层次。真实账号/设备延期不阻塞本机工作，无原生冻结/发布。
