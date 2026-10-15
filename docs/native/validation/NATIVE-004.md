# NATIVE-004：采集片段契约验证

验证日期：2026-10-16（上海）。源码提交 `36f31bbeecd05418d062dc69ad8f7fb8411be6c9`，base `f2cf0786fa57f846001a8df67d1861803f4a090d`。本记录只针对非健康元数据值类型；没有真实采集、Workout 恢复或持久化接线。

## 结果与证据

| 检查 | 实际结果 |
|---|---|
| TDD 红灯 | 可编译无验证骨架执行 8 个测试方法，6 个方法失败，共 33 个预期断言失败，exit 1；不是编译错误 |
| TDD 绿灯 | 相同 8 个方法全部通过，0 失败，exit 0 |
| 完整 Core | 原有 33 + 新增 8 = 41 个测试，0 失败 |
| iOS / Watch | 两端 generic simulator 无签名 SDK 构建均 `BUILD SUCCEEDED`，完整脚本 exit 0 |
| 改动范围 | 新源码 123 行、新测试 134 行；未改任何既有 Core / Store / 工程配置 |
| 输入一致性 | 28 个已提交 native / 验证脚本输入逐字节核对源码 SHA 相同；源码提交后只改本任务文档 |
| 证据校验 | 8 份持久证据文件逐份 SHA256 复核；manifest 不将自身纳入哈希 |
| 真机 | 纯 Foundation 值合同不依赖硬件；真实采集、权限、恢复、签名和设备验证均未执行 |

实际命令：

```bash
swift test --package-path native/Packages/MatchCore \
  --scratch-path /tmp/football-record-native004-red/SwiftPM --filter CaptureMetadataTests
NATIVE_BUILD_ROOT=/tmp/football-record-native004-final-20261016T0438Z scripts/native/verify.sh
```

完整脚本的实际 UTC 日志子目录为 `logs/20261015T203848Z`。构建目录名称只是隔离路径；不据此推断时间。持久证据根目录：

`/Users/liam/.codex/visualizations/2026/10/15/01a13ea0-175e-7362-b38a-36e561719b89/native-validation/NATIVE-004/`

其中 `red-test.log` / `green-test.log` 保存红绿；`verify.log` 和 `final/` 下三个日志保存完整验证；`environment.txt` 为 Xcode / Swift 版本；`build-inputs.json` 记录准确源码、命令、范围与输入哈希；`SHA256.json` 保存文件哈希。日志已脱离工作树和 `/tmp`，归档不会丢失。

本分支 base 尚无 MatchStore target，脚本此处只测试 Core；主代理在接入 NATIVE-003 后须另验最新 Store + Core 组合，不把 41 项误报为仓储验收。

## 行为覆盖与后续使用

- 同一原始 matchID / recordingDeviceID 可以关联两个不同 Workout 的采集片段，中间明确保留 gap；编码解码不更换绑定或 Workout ID。
- 未知、单边未知和已知零宽窗口都原样保留；没有派生时长、补造起点、插值、拼接连续片段或重置比赛计时。
- 构造与嵌套解码均拒绝空白标识、跨比赛 / 跨设备误挂、重复片段 / 缺口 ID、颠倒或非有限已知边界。自定义日期解码器允许生成非有限 Date 后仍被合同拒绝，证明验证没有被 Codable 绕过；损坏的 JSON 时间和标识类型也被拒绝。
- M2 从已有 MatchDescriptor 取得一次原绑定；调用方核实真实 Workout，并提供其稳定非健康关联 ID 与片段 ID。恢复成功可继续关联原 Workout；恢复失败追加新 Workout 片段及未知缺口，保持原比赛 / 原记录设备。合同本身不能证明 Workout 存在，M2 适配层必须保证这一事实。
- `CaptureMetadata` 是完整值快照；片段和缺口在该快照内共享 ID 命名空间，重复包的传输 / 持久化去重不是此容器职责。数组顺序保留，不强制要求不完整观测能够拼成连续采集。
- 源码只含绑定、标识和观测时间，没有 HR、GPS、距离、速度、路线、权限状态或原始健康样本字段。数据结构没有写入 MatchStore、CloudKit、后台或 HealthKit。

## 审阅与集成

/root/environment_check 独立规格审与 /root 质量审均对源码 `36f31bbeecd05418d062dc69ad8f7fb8411be6c9` 给出 PASS，无新增阻塞。主代理负责最终文档复审、`--no-ff` 集成、最新组合验证和安全归档；作者未 merge / push 长期分支。
