# NATIVE-051 Debug material and Phone inbox implementation plan

> **For agentic workers:** Execute inline with superpowers:executing-plans and superpowers:test-driven-development. No subagents; only the six registered paths may change. Product/test implementation waits for root confirmation of this API/publication checkpoint.

**Goal:** Let026 assemble its original facade with retained Debug material and the existing typed Phone inbox, without creating another Runtime, Session, business DB or mailbox protocol.

**Architecture:** Expose a non-Codable material value around the existing private signer/vault and add a phone-only, owned inbox to accepted043 protocolClients. M4 retains namespace ownership and creates the original device identity before calling the material factory; independent fresh identity and original AccountKit services remain026-owned.

**Tech Stack:** Swift6, Foundation/Darwin/CryptoKit, existing AccountKit protocols and existing controlled mailbox/loopback fixture. No real Apple/Keychain/CloudKit/WC calls.

## Registration and exact ownership

Author m2; nonauthor reviewers root/cloud. Base `2cab4640ee3a375da39fdabf0f5a317600b0c263`, accepted043 final `cfeefe85b1489227664a3bc19b9c6c78367e581e`, prepared effectiveBase `ddb659f37cfdaf3a154a59859b63649c46818ec2`; merge target only held026 registered at `eb05eaf2c4521ccd0406a1d3e1bb599952ec9609`.

Managed tree `/Users/liam/.codex/worktrees/m4-debug-material-inbox/20260830_足球记录`, branch `feat/m4-debug-material-inbox`, attachment `01a157b0-7c32-7721-a9ca-445fe2540703`. Actual HEAD/branch/clean including ignored were independently checked before writing these documents.

Only:

1. `native/Modules/MatchPresentation/Sources/MatchPresentation/DevelopmentAuthorityScenario.swift`
2. `native/Modules/MatchPresentation/Tests/MatchPresentationTests/DevelopmentAuthorityDeviceMaterialTests.swift`
3. `native/Modules/MatchPresentation/Tests/MatchPresentationTests/DevelopmentAuthorityPhoneInboxTests.swift`
4. This plan.
5. `docs/native/tasks/NATIVE-051.md`
6. `docs/native/validation/NATIVE-051.md`

No Package, Core, AccountKit, App/project/SDK or other tree edits. Other workers retain their ownership. No long-term branch changes, push or archive.

## API checkpoint

All additions remain inside the file's existing `#if DEBUG`.

```swift
public struct DevelopmentAuthorityDeviceMaterial: Sendable {
  public let namespace: String
  public let deviceID: String
  public let signer: any DeviceProofSigner
  public let vault: any DeviceCredentialVault
  // Factory-only construction; no Codable or raw signing-key accessor.
}
public extension DevelopmentAuthorityScenario {
  static func deviceMaterial(configuration: DevelopmentAuthorityConfiguration,
    namespaceDirectory: URL, installationID: String) throws
    -> DevelopmentAuthorityDeviceMaterial
}
// Added to the existing DevelopmentAuthorityProtocolClients actor:
public func startInbox(authorizer: any WatchRegistrationAuthorizing) throws
public func stopInbox() async
```

The external actor call to startInbox is awaited; internally it publishes its one-owner poller/gate before any suspension. start is phone-only, coalesced and permanently rejected after stop; stop is shared cancel/join, and does not close the original HTTP/Cloud-delete clients. final close also stops/joins the inbox. No new AccountKit protocol or AppIntegration DTO is introduced.

## Strict material publication and restoration

1. Validate the existing configuration and development trust; exact raw namespace must match the directory component. Require a canonical original installation UUID and original regular `device.identity` bytes `football-record.identity.v1:<installationID>`. This API validates that file; it never generates or changes the ID and never opens SQLite or constructs Runtime/mailbox.
2. The only first-publication state is all three material paths `development.key`, `authority.fixture`, `development.vault` absent, while actual `matches.sqlite` and its exact `-wal/-shm/-journal` paths are all absent. Do not trust a caller's hasData=false as permission. If any material exists and any other is missing, preserve all files and reject, even without a business DB. Failed/interrupted partial publication is deliberately failclosed, not auto-repaired.
3. First publish the existing raw32 Ed25519 key format, exact existing pin bytes `(keyID + "\n" + publicKey + "\n" + cloudSpaceID + "\n" + subject).utf8`, and existing vault State format with generation0/no credential. Use exclusive no-follow creates,0600 files, file fsync and parent-directory barrier; complete readback precedes returning material and therefore precedes026's first DB. The initial empty vault is a real retained file.
4. Reopen only when all three are original regular files: key exactly32 bytes, pin bounded16KiB and byte-exact to the validated configuration, vault bounded64KiB with the existing known State/Saved fields. Reject symlinks, nonregulars, oversized/invalid/unknown layouts and preserve their bytes. Recheck the namespace-directory/device.identity and file identities across reads and publication. No user-controlled path is appended as a child except the fixed names.
5. Vault generation is a nonnegative safe integer; a retained credential, if present, has valid fields/token and exact raw deviceID/keyID for the original installation/signer. Expiry alone does not erase the retained credential or prove current identity. No wrong-device/key credential is admitted. Do not rewrite a valid retained state merely on factory construction.
6. The strict factory uses the existing DevelopmentFileVault implementation with an optional private strict binding; nil binding keeps the legacy Runtime initialization/empty-vault behavior mechanically unchanged. Strict mode rereads the real file and checks its binding for credential/generation operations, with a short shared in-process namespace file gate and no await while held. Two in-process handles cannot lower the persisted generation or let a late replace overwrite a newer fence. This is not a second owner protocol or an interprocess lock:026's original M4 namespace lease must span use.
7. The strict path may use the existing privateWrite machinery for atomic replacement plus its own sync/readback barriers; no global behavior change to legacy privateWrite. Legitimate vault replacement can change its inode; immutable key/pin/device and directory identity must still match, and each read/write verifies the actual file being accessed. No reset/rekey/recovery heuristic, credential logging or second business storage is added.

## Owned inbox and preservation boundaries

- Reuse existing MailboxRequest/Reply, WatchForward and bounded polling/response encoding; factor the original private polling routine if needed so Runtime's phone-migration branch remains mechanically equivalent. The public seam handles only phone-context/phone-register. It does not construct or retain PhoneWatchRegistrationService itself.
-026 injects an existing WatchRegistrationAuthorizing wrapper; each request performs current independent identity validation and calls the original Phone service/040 endpoint. The inbox never infers identity from configuration, installed credential or a received body. Original canonical attempt/action/opaque reply bytes are preserved; the Phone never installs the returned Watch credential.
- Track poller, handlers and publication as owned work. Gate before dispatch and freshly after every awaited handler, including error paths, before any reply publication. An uncooperative cancelled handler is joined; its late success cannot publish. Stop is permanent for that instance, clears handler references only after join, and never awaits an App context/DB close callback.
- drainState includes active handler/publication work and the existing same-inode four-directory inventory. It must not interpret empty directories while own work can still publish as drained. Unknown, malformed or substituted input/files remain preserved/undrained; closing does not adopt or broadly delete them.
- stopInbox leaves original HTTP/Cloud-delete available for original-parent Saga control. final clients.close stops/joins owned inbox and existing operations before reporting the fresh current drain state. DB ownership remains with026.

## Execution sequence and real RED/GREEN

### Slice1: material factory

- [ ] Add public-API compile RED in the new material test file, then minimal declarations and actual runtime RED for first persistent empty vault, strict partial/missing/bad material and retained generation/credential behavior.
- [ ] Implement only the strict factory/private binding needed by those assertions. Exercise the original device.identity plus original signer/vault, absence of business DB before/after, two-handle generation fence and reopen; verify wrong namespace/device/key/pin and bounded/type failures preserve original files.
- [ ] Run `swift test --package-path native/Modules/MatchPresentation --scratch-path /private/tmp/football-record-NATIVE051-build/material --jobs 4 --filter DevelopmentAuthorityDeviceMaterialTests`; retain red and green logs/input hashes. Commit only source and this test at a stable green checkpoint.

### Slice2: owned typed inbox

- [ ] Add compile RED then real mailbox runtime RED in the new inbox test file for one owner, phone-only start, context/submit/recover raw bytes, idle/active drain, permanent stop and held cancellation-insensitive handler.
- [ ] Implement private shared poll/owned lifecycle with the existing wire and public two-method seam. Keep original default Runtime behavior and migration branch; no replacement Runtime/services.
- [ ] Run `swift test --package-path native/Modules/MatchPresentation --scratch-path /private/tmp/football-record-NATIVE051-build/inbox --jobs 4 --filter DevelopmentAuthorityPhoneInboxTests`; preserve original HTTP/Cloud-delete continuation after inbox stop and current unknown/substituted-directory drain tests. Commit stable source/test checkpoint.

### Slice3: original services, final validation and handoff

- [ ] New test uses the existing actual Node loopback fixture support and two distinct real SQLite facades/MatchSessions/credential vaults to drive original Phone and Watch AccountKit services through the existing mailbox context, exact submit and explicit recover. No pre-registered Watch or fake signed result replaces the original flow; 404/401/timeout cannot invent knownAbandoned.
- [ ] Freeze runtime/Git inputs, then one complete Presentation host command: `swift test --package-path native/Modules/MatchPresentation --scratch-path /private/tmp/football-record-NATIVE051-build/full-host --jobs 4`.
- [ ] Four fresh minimum SDK products: MatchPresentation Debug and Release for `arm64-apple-ios17.0-simulator` and `arm64-apple-watchos10.0-simulator`; use separate scratch roots under NATIVE051-build, explicit Xcode SDK paths and `swift build -c debug|release --target MatchPresentation --jobs 2`.
- [ ] Ordinary public import consumers: Debug can use the new material/inbox APIs; Release compilation must fail because their DEBUG-only types/functions are absent. Bind the actual module artifacts/argv and input snapshots; do not call real SDKs.
- [ ] Source commit/clean including ignored, exact input before/post/Git comparison and tree-external manifest/raw logs. Source root/cloud dual review, then only two final cards and final aggregate/dual review. No repeated suite solely for unchanged documentation.

## Limits

Held026 software-only candidate; no actual Apple/Keychain/CloudKit/WC/Health, device/signing, App/UI, whole026 or deployment claim. Existing independent fresh identity gates and all service/Store proof semantics stay in their original owners. Historical compiler or fixture failures remain distinct from actual behavior RED. Future counts are not prefilled.
