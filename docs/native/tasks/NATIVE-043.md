# NATIVE-043 Debug 协议客户端工厂

状态：已登记独立树，按 [计划](../../superpowers/plans/2026-10-20-m4-debug-protocol-clients.md) 开始 TDD；尚未声明验证通过。

base `2cab4640ee3a375da39fdabf0f5a317600b0c263`；held026 target `12cb0cfabc0619ddb07784603f313623c26aa080`；分支 `feat/m4-debug-protocol-clients`；attachment `01a1572e-7a79-74a1-b62d-77ed2d80922f`。作者 cloud、非作者 root+m2。初始HEAD/branch/clean含ignored已核。

仅复用原 Debug 协议实现与邮箱；无新 Runtime / DB / Session / identity / signer / vault / SDK。finalclose 与026业务 quiesce 分开，原 Saga 仍用原客户端；pending/未知邮箱保全阻断。原Runtime行为与 production Unavailable 保持。见 [验证卡](../validation/NATIVE-043.md)。
