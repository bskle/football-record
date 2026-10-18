# NATIVE-024 验证记录

实现中，2026-10-19上海。证据树外 `native-validation/NATIVE-024/`；开工六Git输入、工具版本与100份已审依赖输入hash已保存。依赖为实际merge `e0997c6b09791e423d224dd04cbf26da32f2a3c2`，与已审023候选 `f7f7a3bceb3000fd6d655d4724089601870eeb4d` 的native/backend/scripts树一致。

slice1：`024-1-vault-runtime-red.log` 实际7项/4 failures；`024-1-vault-green.log` 同7项/0。只使用受控文件Keychain driver，真实Security执行未调用。初次依赖构建的Core LifecycleInboundCoordinator.swift:23/33两个unused repository warning属于既有已审源，不越界修。后续新增竞争/duplicate验证与完整最终数量待实际命令登记，不累加旧层次。

SDK执行默认false，真实AS/Keychain/CloudKit/CKUser/用户账号均未调用。真实门槛、签名、容器和设备后验；不据host/fake或编译声称真实SDK已执行。

`024-1-vault-race-green.log`：同一次10/10，含两个实例在实际受控文件update阻塞期间竞争advance、duplicate add重读、不同owner目录拒绝。新增adapter本次无warning；最终全包与SDK尚未运行。

slice2：`024-2-identity-runtime-red.log` 实际7项/11 failures，因unavailable seam未发受控请求；`024-2-identity-first.log` 同7/0。补 `024-2-fence-cancel-runtime-red.log` 1项/1 failure证明身份推进还需retire SDK操作；修复后 `024-2-account-adapters-green.log` 单轮17/0（10 Keychain + 4 Apple + 3 CloudIdentity），增量构建无warning。AS/CloudKit真实对象未在测试实例化，UIKit/watch分支尚待四triple编译。

Slice3 raw evidence: 024-3-assets-staging-runtime-red.log ran11 tests with missing implementation failures (plus a constructor-derived unwaited expectation). First implementation caught two symlink-escape assertions. Separate manifest-byte-fidelity, root-owner and receipt-response-lost logs each ran1 test/1 failure before their fixes. 024-3-scope-gates-green.log then ran15/0 (5 Codec +10 Staging), including near8MiB, two-handle actual copy/erase race, durable fence/receipt faults, reopen, other-account preservation and old-operation rejection.

024-3-final-green.log is a preserved FAILED diagnostic despite its filename: directory-URL trailing slash comparison and fixture timing caused1 failure. Passing is determined by actual EXIT/count. Keychain owner comparison received the same narrow resolved-path-byte correction and 024-3-keychain-path-regression.log reran10/0. No real SDK operation was executed.
