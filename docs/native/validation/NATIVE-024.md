# NATIVE-024 验证记录

源码冻结后完成本机验证，2026-10-19上海；整项 root + m2 双审待核。证据树外 `native-validation/NATIVE-024/`；开工六Git输入、工具版本与100份已审依赖输入hash已保存。依赖为实际merge `e0997c6b09791e423d224dd04cbf26da32f2a3c2`，与已审023候选 `f7f7a3bceb3000fd6d655d4724089601870eeb4d` 的native/backend/scripts树一致。

slice1：`024-1-vault-runtime-red.log` 实际7项/4 failures；`024-1-vault-green.log` 同7项/0。只使用受控文件Keychain driver，真实Security执行未调用。初次依赖构建的Core LifecycleInboundCoordinator.swift:23/33两个unused repository warning属于既有已审源，不越界修。后续新增竞争/duplicate验证与完整最终数量待实际命令登记，不累加旧层次。

SDK执行默认false，真实AS/Keychain/CloudKit/CKUser/用户账号均未调用。真实门槛、签名、容器和设备后验；不据host/fake或编译声称真实SDK已执行。

`024-1-vault-race-green.log`：同一次10/10，含两个实例在实际受控文件update阻塞期间竞争advance、duplicate add重读、不同owner目录拒绝。新增adapter本次无warning；最终全包与SDK尚未运行。

slice2：`024-2-identity-runtime-red.log` 实际7项/11 failures，因unavailable seam未发受控请求；`024-2-identity-first.log` 同7/0。补 `024-2-fence-cancel-runtime-red.log` 1项/1 failure证明身份推进还需retire SDK操作；修复后 `024-2-account-adapters-green.log` 单轮17/0（10 Keychain + 4 Apple + 3 CloudIdentity），增量构建无warning。AS/CloudKit真实对象未在测试实例化，UIKit/watch分支尚待四triple编译。

Slice3 raw evidence: 024-3-assets-staging-runtime-red.log ran11 tests with missing implementation failures (plus a constructor-derived unwaited expectation). First implementation caught two symlink-escape assertions. Separate manifest-byte-fidelity, root-owner and receipt-response-lost logs each ran1 test/1 failure before their fixes. 024-3-scope-gates-green.log then ran15/0 (5 Codec +10 Staging), including near8MiB, two-handle actual copy/erase race, durable fence/receipt faults, reopen, other-account preservation and old-operation rejection.

024-3-final-green.log is a preserved FAILED diagnostic despite its filename: directory-URL trailing slash comparison and fixture timing caused1 failure. Passing is determined by actual EXIT/count. Keychain owner comparison received the same narrow resolved-path-byte correction and 024-3-keychain-path-regression.log reran10/0. No real SDK operation was executed.

Slice4: 024-4-cloud-driver-runtime-red.log ran7/7 failures against unavailable behavior, then controlled-first7/0. The actual SDK branch compiled on macOS in 024-4-sdk-compile-first.log; its one accountStatus callback-in-async warning was removed by the async API. 024-4-cloud-sdk-host-green.log ran22/0; added real SQLite conflict retention, cloud-only fencing/local preservation and cancellation tests ran25/0 in 024-4-driver-boundaries-green.log. Account adapter zone derivation cross-check ran18/0 in 024-4-account-zone-regression.log. These are separate incremental rounds, not a sum.

Pre-copy manifest budget runtime red ran1 test/2 assertion failures in 024-4-manifest-budget-runtime-red.log; bounded total/reference checks then ran26/0 in 024-4-manifest-budget-green.log. Real SDK callbacks pass the manifest's expected part reference into synchronous copying; host tests prove pure budget and controlled copy behavior, not real CloudKit callback semantics. Preliminary AccountKit watchOS10 simulator and CloudSync iOS17 simulator builds passed before this last budget delta; final fresh eight builds must use the frozen source and supersede these preliminary inputs.

## 最终同输入验证

源码 `06ce54634dbf96c6c29fcaa8339dad05079ddb93`，目标已验证dev `fcf530ada01a7cbf87bbfde598f611d8a35705b2`。证据目录 `native-validation/NATIVE-024/final-06ce546/`。完整 AccountKit 本轮72项/0，完整 CloudSync 本轮106项/0，分别 fresh scratch；共178项只表示这两个相关包本轮的并集，不含旧591或其他模块/设备测试。

| 产品 | 最低 triple | 实际 exit |
| --- | --- | --- |
| AccountKit | arm64-apple-ios17.0-simulator | 0 |
| AccountKit | arm64-apple-ios17.0 | 0 |
| AccountKit | arm64-apple-watchos10.0-simulator | 0 |
| AccountKit | arm64-apple-watchos10.0 | 0 |
| CloudSync | arm64-apple-ios17.0-simulator | 0 |
| CloudSync | arm64-apple-ios17.0 | 0 |
| CloudSync | arm64-apple-watchos10.0-simulator | 0 |
| CloudSync | arm64-apple-watchos10.0 | 0 |

每项命令为 `swift build --package-path native/Modules/<product> --target <product> --triple <triple> --sdk <xcrun对应SDK绝对路径> --scratch-path <独立新建树外路径>`。八日志及两份results JSON保存完整实际参数与exit，没有用旧scratch/旧日志替代。工具为本机Xcode27.0/Swift6.4，最低部署版本未升级；只编译产品target，不执行设备SDK。

Git输入、207项相关产品/测试/后台fixture/脚本文件、23项实际SDK header/interface均按原bytes固定；post-runtime检查207项零差异。023实际合并/GIT007只影响治理文档，未消费作者WIP，Core/backend/Apps/project/Package/scripts保持原依赖。最后收尾仅两张024卡，产品输入无需重跑。最终完整SHA与证据manifest由树外manifest记录，避免文档自引用。

诊断：Core LifecycleInboundCoordinator.swift23/33既有unused repository warning保留；Node22 experimental SQLite warning保留。完整AccountKit运行还输出系统CoreData/contactsd NSXPC4097连接诊断，72项仍0失败；源码/测试未调用Contacts API，不据该系统日志认定真实账号或权限能力已验。新增adapter无编译warning，slice4早期accountStatus warning已经换async接口并被最终八构建覆盖。53a7db6 body字面量换行保留历史，不amend/rebase。

宿主只用受控Authorization/Keychain/CloudKit transport与受控文件SQLite；公共factory默认false。没有实际AS授权、Security item读写、CKContainer/CKUser请求、CloudKit query/save/delete、账号配置或设备行为。真实iCloud环境选择来自签名工程配置，enum不是服务器切换开关。未构建App、未签名安装、未把单staging receipt或SDK候选bool升级为全本地/账号/cloud/health完成。真实SDK行为和组合验收仍归026；候选独立保留待双审。

## S24-manifest-binding-1：替代旧整项结论的新输入

新增P2 finding使旧06ce/ae8 whole PASS失效。旧178/八SDK/原manifest保持未改；新目录 `native-validation/NATIVE-024/S24-manifest-binding-1/` 保存独立红绿和输入。

`manifest-binding-runtime-red.log` 实际编译成功后运行3项/2 assertion failures；不是编译失败充当红。纯metadata seam先抽取旧SDK语义，actual alias ID/tag配原manifestbytes/parts仍产生期望ID证明，top引用错配同样未拒；正常actual ID/tag通过。修复后 `manifest-binding-targeted-green.log` driver13/0。SDK canonical实际从CKRecord取得recordID、owner、scope、tag和callback-owned bytes送同一binder；绑定实际ID、top引用和decoded checkpoint后才能取parts。readback再次核upload期望并返回实际ID/tag。host证明metadata边界，不能声称真实CloudKit取回或服务器条件已验。

新源码 `59c82d482e8455d546eca0e950c176246d2cec90`（目标仍为已验证fcf530），完整fresh host AccountKit72/0、CloudSync109/0；本轮两包181/0。新目录 `final-59c82d4/` 的八个fresh SDK日志/两份results JSON分别覆盖AccountKit、CloudSync的最低iOS17/watch10 simulator/device四triples，全部exit0。AccountKit依赖变更的CloudSync产品，因此两产品八项均按新输入重跑；没有沿用旧scratch/日志。

207项相关源/测试/fixture/脚本输入、23项实际SDK header/interface重新读取hash，post-runtime207项零差异。source后仅两张024卡收尾；最终SHA/manifesthash在树外。诊断仍为已审Core23/33 unused repository与Node实验SQLite warning；fullAccount系统CoreData/contactsd4097输出原样保留，72项零失败，无Contacts显式调用。新增binder未产生编译warning。

真实AS/Security/CKContainer/CKUser、账号配置、设备与实际CloudKit query/save/delete均未调用；没有改变执行默认false或单组件删除边界。旧review记录不覆盖新source，必须root+m2重新exact source/final审阅；仍不合dev/push/archive。
