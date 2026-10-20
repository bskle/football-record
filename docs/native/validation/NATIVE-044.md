# NATIVE-044 验证

source `961c95d0232fa515b9b3120de25d275e0757b36d` 已 root+m2 exact 双审 PASS_SOURCE_HELD_026_ONLY。final 仅本卡与[任务卡](../tasks/NATIVE-044.md)；产品、测试、[计划](../../superpowers/plans/2026-10-20-m4-cloud-erasure-replay.md)原 bytes 不变，停写后交同 HEAD 窄审。

## 实际红绿与分层

| 输入层 | 实际运行 |
|---|---|
| 原 receipt 反例 | `current-zero-red.log` 6项17失败/0unexpected；四表当前/旧epoch恢复、同inode重开、坏foreign库存错误返回成功 |
| 四行修复 | 同六测试 `current-zero-green.log` 6/0；239输入前后零差，红绿仅产品文件改变 |
| 旧67a检查点 | source67a完整Cloud86/0 +四fresh最低SDK，保留原根目录20证据及aggregate，不能冒称最终source运行 |
| live格式 probe | `S44-layout/layout-red.log` 1项3失败；独立详细/issue日志各1项4失败，明确99/新table/column/view返回receipt；不声称所有六变体在旧source均失败 |
| 修后定向 | `S44-layout/layout-green.log` 全7/0；逐项记录99/table/column/view/trigger/index均typedblocked，最终RED→GREEN仅产品输入改变 |

最终七项覆盖四表每表在epoch1/7恢复、epoch31同原inode重开与原mainfile、三个合法foreign account/space/zone各四表保全、八种坏foreign canonical/control状态、原COMMITlost重开及重复receipt原字节、同ID异意图、live未知布局版本/目录SQL定义保全。原receipt、fence及原canonical不重写；恢复目标不自动再擦。

## 最终 source 完整相关验证

`S44-layout/source-commands.json` 记录原argv、exit、耗时及logSHA；`source-inputs.json`绑定239项native/backend/scripts Git bytes/mode/blob，每命令before/post0。

| 命令层 | 实际结果 |
|---|---|
| `swift test --package-path native/Modules/CloudSync` | 单轮87/0 =原80+新7；不叠加旧/定向运行 |
| CloudSync arm64-apple-ios17.0-simulator | fresh，exit0 / Build complete |
| CloudSync arm64-apple-watchos10.0-simulator | fresh，exit0 / Build complete |
| CloudSync arm64-apple-ios17.0 | fresh，exit0 / Build complete |
| CloudSync arm64-apple-watchos10.0 | fresh，exit0 / Build complete |

五命令本轮原日志无warning/error行。设备SDK只是编译，没有本人设备、签名、安装、Simulator启动或真实CloudKit/provider/账号/网络业务运行。纯本地SQL receipt查询修复无需硬件验证；实际cloud/device验收继续由026负责。

## 来源与限制

树外 `native-validation/NATIVE-044/S44-layout/source-aggregate-manifest.json` SHA256 `e6ad4f69ad4f1b08287c1d25ab9f3db48f0143d8793b2ff74261fdde7ca58c13` 绑定44证据（新23+旧20+旧aggregate）、5Git/5owned/239runtime。原67a aggregate SHA256 `288ad4954e5f26ac3a384af41575ffdd8e0408f422715a9cd484591a5325adb6` 与其20证据逐hash不变。root source review SHA256 `221c65511ae8d0c17cb53527292f359e4af0860eb71602f490ca737a8b2f050d`；m2 SHA256 `bd723600c2dab00023128e3428b45f779c9e874d45a40c6af2ba864c4428a5d2`。

精确原布局检查只读且保守；非原SQL格式即便语义相近也保全拒绝，不自动迁移/修复。单ledger当前零不表示全部owned、跨叶原子、物理擦除、024 staging、023 Store、026 fullseal或nativeproof；仍须caller每轮fresh聚合。final aggregate另核仅两卡增量与原44证据/239输入不变，不重测或回写自SHA。未合长期分支、未发布，M4未完成。
