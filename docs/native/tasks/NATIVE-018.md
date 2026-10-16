# NATIVE-018

状态：实现及本机分层验证检查点；完整整包等待独立019测试兼容修复接收后重跑，未标全量通过。

作者 `/root/m3_ui`；base/目标dev b0070c90d91bf9d7741b7a7ed24165f1ad27383d；branch test/m3-device-integration；受管树/attachment与016/010 merge完整SHA见[小计划](../../superpowers/plans/2026-10-16-m3-device-integration.md)。root提交依赖merge，作者只解决已授权五冲突，不推进长期分支。

本轮先交付不需要用户协助的可审整包；依赖008/010/016/018的物理门槛保持，不将Simulator fake当真实WC。同一facade/Session、单observer/driver、生命周期停旧和显式Debug配对为验收重点。


同一facade/具体Session/真实Workout与DeviceSync已装配；先events再start，激活与普通wake分离，失效先撤权再stop/join。环境替换不复用shutdown model，停指标/同步/旧context再开新；gate复用active facade。传输factory故障降级unavailable而继续恢复本机。Debug持久双方UUID与显式account/pair/epoch，原身份/配置每次复验，失效锁存不清除；生产trust/permit仍unavailable。

当前实际Integration18、DeviceSync21宿主绿；首次全量Core213 / Presentation39 / 8SDK / 2sim App绿后，被旧WorkoutCapture测试替身编译阻断。两端UI各12项原输入过、新环境往返各1项测试定位修正后定点过，保留分层输入，不写同轮13全绿。完整命令/输入/日志/xcresult/实际UUID页在树外 `native-validation/NATIVE-018`（构建根 `/tmp/football-record-NATIVE018-build`）。最终完整矩阵、源码/文档精确SHA与双审待续；008/010/016/018物理门槛保持，临时树/分支不合长期分支、不推送或归档。
