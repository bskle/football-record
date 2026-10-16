# NATIVE-018

状态：本机可审整包完成，待物理验收；保持临时分支/工作树，不合 dev / release / main。

作者 `/root/m3_ui`；base / 审阅目标 `b0070c90d91bf9d7741b7a7ed24165f1ad27383d`；branch `test/m3-device-integration`。受管树/attachment、依赖普通merge、所有权和完整SHA见[小计划](../../superpowers/plans/2026-10-16-m3-device-integration.md)。最终源码是root接019后的actual `72846583e503349d117dac84e42fde746d384fee`；root质量与m2规格双审 PASS。

真实Workout/DeviceSync使用同一个SQLite facade与具体Session。同步事件先订阅再start；注册合并为一套监听，失效先撤Debug trust再stop/join，普通wake不重置ACK预算。环境替换不复用shutdown模型；gate复用活动facade。传输factory故障降级unavailable，本机有效记录继续恢复/提交。Debug显式持久身份/绑定每次复验并锁存失效；生产trust/permit保持unavailable。

实际728完整一轮331项宿主 / 14项最低SDK / 2个Simulator App通过。2个genericdevice unsigned App配置检查通过，019仅测试变化后App字节相同。iOS为9 Recording+3旧Integration通过及新增环境1项查询修正后通过；Watch为9旧Recording通过+最终Integration整类4/0。保留初次失败和各轮输入，不写成同轮13全绿。完整命令、分层界限和manifest见[验证记录](../validation/NATIVE-018.md)。

签名/安装/授权/GPS/后台/锁屏/系统恢复/真实WC、真人VoiceOver/触觉、最低OS运行均未验；当前iOS27/watchOS27模拟器与受控driver不是物理E2E。普通结束仍endedPendingSync，peer ACK不释放后台锁或制造completed。008/010/016/018保持物理依赖；019已由root实际归档、安全删支。最终文档head与证据由树外final manifest及root复核绑定。
