# 球历：打开设备验收候选

当前没有连接真机也可以完成源码审阅、宿主回归、模拟器操作和实际设备SDK的无签名构建；这些都不能证明授权、签名、安装或真实采集通过。NATIVE-010保留在本地 `test/m2-device-integration` 候选，真机门禁通过前不合入长期分支、不推送或分发。

## 现在就能打开

Xcode工程位于 `/Users/liam/.codex/worktrees/m2-device-integration/20260830_足球记录/native/FootballRecord.xcodeproj`。用Xcode打开后选择 `FootballRecord-iOS` 或 `FootballRecord-Watch` scheme和已有模拟器，使用Debug配置。正式中文名“球历”，英文名`football-record`；工程技术名`FootballRecord`。

当前两个Bundle ID `com.example.footballrecord`、`com.example.footballrecord.watchapp`仅是本地占位，未注册；工程没有预填Team。自动检查与实际候选路径见[010验证记录](validation/NATIVE-010.md)。构建命令：

```sh
NATIVE_BUILD_ROOT=/tmp/football-record-check scripts/native/verify.sh
NATIVE_DEVICE_BUILD_ROOT=/tmp/football-record-device-check scripts/native/verify-device-candidate.sh
```

第二条只构建generic iOS/watch实际设备SDK的无签名App并检查最终Info.plist与配置entitlements，不生成provisioning profile，不安装，也不能用该产物直接作为签名成功证据。

## 三个入口的区别

| 入口 | 用途 |
|---|---|
| 正式入口 | 生产开赛许可在M4前不可用，保留原开赛请求，没有静默模拟许可 |
| 纯界面演练 | 独立SQLite及Unavailable采集gateway，验证UI与事实；不会记录健康数据 |
| 真实设备验收 | Debug专用；固定`device-acceptance-v1`数据集，实际HealthKit/定位适配器，持续“开发模拟锁”；不等于真实账号或后台唯一锁 |

iPhone在“设置→开发环境”选择；Watch在初始页或比赛主页向下滚动找到“开发环境”。选择“真实设备验收”，回到记录页后确认首发/替补才开始本轮。需要写入/定位授权时由系统显示本人选择；不要把模拟器结果当授权通过。

环境偏好会保存，重启后回到同一真实验收数据集；当前比赛始终由数据库扫描恢复，没有另存currentMatch索引。系统Watch恢复回调与“重新核对当前记录”复用原会话，不能创建替代Workout。纯界面演练的独立数据库不用于恢复真实采集。

任何真实活动、未知状态、待解锁关联、阻断诊断、未完成操作或未释放记录都会阻止切换/新建演练。**结束后仍是待同步且锁held，M4完整释放尚未实现，因此当前也不能绕锁另开一场。**保留数据、用“重新核对当前记录”检查；不要靠删除App/换dataset/重建演练逃过未决Workout，也不把空健康查询当读取拒绝或未创建证明。

## 以后能连接设备时

1. 记录本人iPhone/Watch型号和系统版本，确认Watch已经与这台iPhone正常配对。无需为开发抹除或重配现有设备。[Apple配对说明](https://support.apple.com/guide/watch/pair-and-set-up-applewatch-with-iphone-apdde4d6f98e/watchos)
2. 先用数据线把解锁的iPhone连接Mac，按系统提示允许附件并在iPhone点“信任”。在Xcode27的Device Hub（Open Developer Tool，或目的地下Manage Devices）核对设备；按提示再建立Watch与Mac的开发连接。较早iOS可能需要iPhone保持插线，不承诺所有设备均可从零无线配对。[USB信任](https://support.apple.com/109054)、[Device Hub](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)
3. 在两端“设置→隐私与安全性”按提示启用Developer Mode并重启/本人确认；该选项可能在开始Xcode配对后才出现。Watch也按提示信任Mac、输入本人设备密码。[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
4. 本人在Xcode→Settings→Apple Accounts登录自己的Apple账号，查看实际Team。当前未获知账号/Team；不需要把账号密码或验证码发给代理。未加入付费Program的账号可能显示Personal Team，不能与付费Individual Team混同。[账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account)
5. 在两个App target的Signing & Capabilities选择**同一实际Team**、Automatically manage signing。给手机及Watch各配置本人可注册的唯一Bundle ID，Watch ID由手机ID派生；同步修改Watch Info.plist的`WKCompanionAppBundleIdentifier`，保持手机关联完全一致。不以当前占位ID声称已注册。[Bundle ID](https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier)、[自动签名与运行](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
6. 核对两个App普通HealthKit capability及读/写用途说明、WhenInUse定位说明；Watch只有Workout processing后台模式，iPhone路线后台使用location。候选没有Always定位、audio或HealthKit Background Delivery。后者与Workout processing不同，不因训练后台自动添加。[HealthKit配置](https://developer.apple.com/documentation/xcode/configuring-healthkit-access)、[Watch后台模式](https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes)
7. 选择本人真实设备运行。只有Xcode实际生成双端profile、签名并安装成功后，才能记录这些步骤通过；还须检查签名App的实际HealthKit entitlement。UI测试runner可能另占ID/设备配额，按真实签名结果核对。

当前Apple官方iOS和watchOS能力表中，普通HealthKit与Background modes均支持免费Apple Developer账号；不需要为了这两项能力先购买Program。该资格不保证本人账号/profile已成功。[iOS能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios)、[watchOS能力表](https://developer.apple.com/help/account/reference/supported-capabilities-watchos)

免费Personal Team有设备/App ID及7天profile等限制，应按本人Xcode实际提示处理；App Store/TestFlight对外分发另需Program membership，本候选不做分发。[Apple账户与会员说明](https://developer.apple.com/help/account/basics/about-your-developer-account)

## 真机验收仍须逐项完成

| 项目 | 当前状态及需记录的事实 |
|---|---|
| 账号、Team、唯一ID、双端profile/签名/安装 | pending；设备型号/OS、实际Team和签名产物 |
| 允许/拒绝运动写入、定位允许/拒绝 | pending；比赛事实保留、无伪零/无读取拒绝猜测 |
| Watch真实心率/距离/速度，iPhone手动builder及HR不支持 | pending；单位与缺失语义、健康中实际Workout |
| 上下场、暂停/继续、后台、路线 | pending；bench不暂停采集，暂停样本不补算、路线真实 |
| 结束保存与锁屏nil/nil、解锁后UUID关联 | pending；先stop/end/save，不重复保存或新建Workout |
| 系统恢复、崩溃、用户强退、设备重启 | pending；分场景记录，后两者不保证原session可恢复 |
| 等待授权时结束、迟到SDK回调/授权 | pending；已终结不再创建，原token对账，无二次开始 |
| 物理触觉、VoiceOver朗读、最低系统运行 | pending；模拟器AX和SDK编译不能代替 |

真实Workout一旦不确定，先保留原记录和token，禁止自动另起；没有真实设备证据就不标记上述行完成。


## M3 Debug 双端显式配对（NATIVE-018）

此步骤等设备方便连接时再做，不影响当前本机开发。设备验收环境固定数据库命名空间 `ui-simulation-device-acceptance-v1`，与生产、纯界面演练分离。先分别运行 iPhone / Watch 的 Debug 设备验收入口，打开“开发环境”，抄下各自“本机持久身份” UUID。它来自本安装数据库旁的 `device.identity`，禁止拿随机 UUID 代替已有身份。

在两个 target 的 Scheme → Run → Arguments 中加入 `--device-acceptance`，再加入一对参数 `--sync-peer-config` 和下列完整 JSON 字符串（作为一个参数）：

```json
{"localDeviceID":"本机实际UUID","remoteDeviceID":"另一端实际UUID","accountSubject":"development-football-record","pairingID":"明确约定的同一开发pair","trustEpoch":"明确约定的同一开发epoch"}
```

两个安装的 local / remote 必须互换，accountSubject / pairingID / trustEpoch 必须完全相同。此 account 是人工配置的开发标签，不是生产账号或 Apple 登录认证。第一次有效配置会保存在本安装相同 namespace 下的 `development-peer.json`，以后重启可省略 JSON；每次授权仍重读本机 identity、配置与持久失效记录。未配置仅保存本机，不从 WC 状态、来包或对端 sandbox 猜身份。双方 UUID 与绑定一经使用不得更换；配置、身份、配对或 companion 变化会 fail closed，保留原记录/待发数据与失效锁存。不要删文件、重装、换 epoch 以绕过；须保留现场后安排恢复方案。

界面持续显示“开发模拟锁”和“开发配对”状态。真正 WC 激活才进入 connectionDidActivate，普通前台唤醒和重试不重置 ACK 的八次预算。传输文件持久化通知不是业务 ACK；只有真实业务 ACK 与完整持久计数才能显示对端已保存。对端确认不完成比赛或释放后台锁，普通结束仍是 endedPendingSync。

Simulator 可以验证界面、隔离 SQLite、受控驱动、状态及生命周期；Apple 的 transferFile 不支持 Simulator，不能据此判定真实双端通信。签名安装、HK/定位授权、真机 WC、离线补传、锁屏/后台、系统恢复、真人 VoiceOver 与触觉仍按前文真机清单延期验收。最低 iOS17/watchOS10 保留编译门槛，当前 iOS27/watchOS27 Simulator 运行不等于最低系统已运行。
