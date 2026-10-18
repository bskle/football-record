# NATIVE-037 验证

实施中，尚无 source/final PASS。输入与受管树见[任务卡](../tasks/NATIVE-037.md)，设计见[实施计划](../../superpowers/plans/2026-10-19-m4-device-sync-erasure.md)。

树外证据：`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-037`。保留原始红绿、实际单轮计数、四最低 SDK 日志、Git/源码/编译输入与 evidence SHA256。

待实际运行：迟到文件/message/audit、双 handle/进程/重开、owner inode、SQLite fence/request/receipt 故障、未知归属保护、owned SDK 取消/排空与晚回调、完整旧回归。真实 WCSession/账号/设备行为未验，不将编译视为设备验收；候选 held026，不推进长期分支。

## durable control / filesystem checkpoint

首个现有 late-file 行为测试实际红1失败→绿1/0。新增归属/擦除 API 初次为缺失类型编译红，运行实现后发现并修复系统 `/var` 别名、目录 URL 尾斜线、已存在 control 创建兼容。随后 owner/schema 两项具体 runtime 红（6项/2失败）→完整36项/0失败，日志 `slice2-host-1.log`。该36项单轮包含原21项、初始late-file及14项新的归属/文件/故障/进程检查，不等于018旧331或026整体验收。原生SDK同步dispatch/cancel尚待下一slice，不以该轮宣称完整037完成。
