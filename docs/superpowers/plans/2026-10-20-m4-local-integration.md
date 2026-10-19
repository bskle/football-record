# M4 Local Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Sole026 author: `/root/m4_integration`; root owns orchestration, independent review and branch governance.

**Goal:** Complete controlled same-Session assembly, retained owned-storage catalog and recoverable composite deletion without requiring user accounts, signing or devices.

**Architecture:** Reuse accepted018/037,024,028 and integrated023/025. Establish original identity/vault before first businessSQLite; all services retain the same facade and originalSession. Freeze complete catalog and Health selection before Storeerase; keep saga controls while independently aggregating required leaf receipts. Default/Release and controlled local composition do not construct realAS/Security/CK/HK/WC factories.

**Tech Stack:** Swift6.4, SwiftPM, Foundation/Darwin retained-file control, existingSQLite ledgers, SwiftUI and controlledNode HTTP fixture. MinimumiOS17/watchOS10.

## Reviewed inputs and ownership

Accepted frozen blueprint SHA256: `23df926d93faafd0b44ade079e50e438c0088dca3a2dcef7a2476e6cfe44497b`. Root+m2 plan PASS authorizes local implementation, not implemented-code or actual-environment acceptance. See [M4 plan](2026-10-18-native-m4.md), [contract](../../native/contracts/m4-account-lock-cloud.md), [Git governance](../../git-workflow.md).

- Base/target: `e3e4b09d79c1f2556b8648c214f6c3c148ca8cd1`; accepted025final1c09 is already an ancestor.
- Managedtree: `/Users/liam/.codex/worktrees/m4-e2e-integration/20260830_足球记录`; branch `test/m4-e2e-integration`; attachment `01a155ff-6fe4-79d0-8f55-1e58a4b98670`, createdAt1792444166. Root verified path/branch/HEAD/clean before writes.
- Accepted037final `55718f44375cf2a44eb9ef7e380819f5dba72ca9` contains018final `891000e1842f21f4a594a1d29168974debed68b9`; ordinarymerge `b795132c6a085f220cf31d375e127ebade7c35bf`.
- Accepted024final `a8ad01157cc0752f41790ac2b88b06bda04efb0e`; ordinarymerge `b7e6426e0ea0a8952d6dc2008517a05cb24b6242`.
- Accepted028final `0fa3dff4d3232e72257f6fa115ecada873f086db`; ordinarymerge `ef6d86efce52ead420d922d193bcc2a0de2a866f`.
- `cd84cfac144cbc4ccca7e8fd9b9e39be3e3cd94b` independently fixes the Watchoverview optional action; actual unsignedWatch build red then green.
- NATIVE-038 now exclusively owns six Presentation paths: AppBootstrap/BootstrapTests, AccountStatusModel/AccountStatusTests, LifecycleStatusModel/LifecycleStatusTests.026 does not edit them or assume future signatures; root ordinarymerges an exactreviewed038 result before026-2.026-1/3 can proceed independently.
- Project/schemes/config/scripts remain sole026 ownership. NoCore/backend/SDKleaf/oldtree/DevelopmentAuthorityScenario edits. Accepted018 entitlement files and Info declarations remain original input bytes; project does not bindentitlements or enableHealth/BackgroundModes capability. FournewM4 reservedentitlements remain unwritten.
- Whole026 remains held, with no dev/release/main promotion, push or archive; actualaccounts/devices/deployment are deferred.

Current direct ownership:

- `native/Apps/iOS/Integration/Package.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/AppAssembly.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/IntegrationContext.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/IntegrationPolicy.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/DeviceSyncCoordinator.swift`
- `native/Apps/iOS/App/FootballRecordApp.swift`
- `native/Apps/Watch/App/FootballRecordWatchApp.swift`
- `native/FootballRecord.xcodeproj/project.pbxproj`
- `native/FootballRecord.xcodeproj/xcshareddata/xcschemes/FootballRecord-iOS.xcscheme`
- `native/FootballRecord.xcodeproj/xcshareddata/xcschemes/FootballRecord-Watch.xcscheme`
- `native/Configuration/M4-capability-handoff.md`
- `native/Configuration/iOS/Info.plist`
- `native/Configuration/iOS/M4-Debug-Info.plist`
- `native/Configuration/Watch/Info.plist`
- `native/Configuration/Watch/M4-Debug-Info.plist`
- `scripts/native/verify.sh`
- `scripts/native/ui-test.sh`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4AccountComposition.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4IdentityBootstrap.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4OwnedDataCatalog.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4LocalTransportDeletion.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4HealthDeletionBridge.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4WatchRegistrationRelay.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4AccountCompositionTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4IdentityBootstrapTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4OwnedDataCatalogTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4DeletionRecoveryTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4WatchRegistrationRelayTests.swift`
- `docs/native/tasks/NATIVE-026.md`
- `docs/native/validation/NATIVE-026.md`
- `native/Apps/iOS/Integration/Sources/AppIntegration/RecoveryInbox.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/RecoveryInboxTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/IntegrationContextTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/DeviceSyncCoordinatorTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/IntegrationTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/DevicePairIntegrationTests.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4CatalogJournal.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4ControlledAdapters.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4TestSupport.swift`
- `native/Apps/iOS/Features/Match/PhoneMatchView.swift`
- `native/Apps/Watch/Features/Match/WatchMatchView.swift`
- `native/README.md`
- `native/UITests/NativeAccountLifecycleUITests.swift`
- `native/UITests/NativeRecordingUITests.swift`
- `docs/superpowers/plans/2026-10-20-m4-local-integration.md`

## Fixed architecture and sequencing

### composition

- M4AccountComposition opens originalidentity/vault first, then one SQLiteSessionRepository(authorityTrust/cloudSavePolicy) and PersistentDeviceIdentityProvider over the same original file. Build AuthorityStartPermitProvider, original MatchSession with injected WorkoutGateway, attach provider, create MatchSyncService with same Session inbound, attach CloudSessionBridge and existing public AccountKit services. Do not use AppBootstrap.composition development path for authority recording: it installs DevelopmentStartPermitProvider rather than the HTTP provider.
- IntegrationContext accepts this preparedcomposition and its one RecordingModel/DeviceSyncCoordinator. It must not call AppBootstrap.composition again, and must not create a second RecordingModel merely to swap sync adapters. Register DeviceSync events before any RecordingModel.load -> sync.start -> activation.
- M4ControlledAdapters uses public AccountKit/CloudSync protocols and DEBUG-only private file/loopback seams with existing Mac broker.025 DevelopmentAuthorityScenario.make remains untouched and available for its priorUI flows; its private runtime is not a dependency factory because it creates its ownfacade/Session. No exposure of024 internal test drivers.
- M4AccountComposition owns separate businessworker-quiesce and finalclose. AccountAppContext.shutdown remains final and closes facade. During deletion/identity invalidation, first stop/join business, sync, cloud, mailbox and capturewrapper operations while retaining same repository/Session for LifecycleService saga updates; finalclose only after progress persisted or before a serial replacement.

### firstIdentityAndVaultOrder

- Under retainedcontrol owner lock, validate explicit canonical root/namespace and existing file identities without opening business SQLite. Classify namespace fresh only when no known businessDB/WAL/SHM, identity, credentialcontrol, ledger/staging/DeviceSync or unknown owned-file evidence exists; unclassified legacy is not fresh.
- Read exactly football-record.identity.v1:<UUID> and keep UUID.uuidString canonical deviceID. Provenfresh creates withoutOverwriting and fsyncs identity+parent; concurrentwinner reread must match. ExistingDB evenempty missing/corrupt originalidentity or originalvault/key/pin failsclosed; do not generate a replacement identity or silently choose newnamespace.
- Vault factory is injected protocol boundary returning signer+DeviceCredentialVault bound to this installationID and original businessDatabaseURL. Construct it before first SQLitecreation.024 real Keychain factory stays uncalled/defaultdisabled; local DEBUG fixture owns durable private key/control and tests order, not Keychain behavior.
- Persist namespace ownership/control and originalID before canonical writes. Open one businessfacade, create PersistentDeviceIdentityProvider against originalidentity and assert exact ID agreement. Attach Session/coordinators only after repositoryidentity checks. Preserve retained owner inodes/parents throughout erase.

### identityStopAndReadmission

- Notification is only a trigger. Immediately pause UI admission and prevent scheduling new business work; revoke peer/transport paths; cancel and join owned async tasks/listeners and record lifecycle identityChanged on originalsamefacade. New recordstart remains authority-owned, no added always-online capture requirement.
- Propagate resulting persistent identityGeneration monotonically to vault, Apple/cloudidentity adapter gates and everystaging binding; do not lower to a caller counter. Callback results must match originating generation/scope, not current UI identity.
- RecoveryInbox gains detach+cancel+join that clears pending oldsignals. Original AppleWorkoutDriverFactory owns its private RecoveryEvidenceCache;026 never edits it. Retire old resourcewrapper/factory after controlled operation shutdown, do not reuse it in anothercontext; real callback drainage/source behavior stays deferred and a leaf deficiency returns to originalauthor. Never auto-invent abnormaltermination or newWorkout to clear memory.
- Read current Apple authentication/verifiedbinding plus currentcloud identity again; compare originalaccount/cloudSpace/epoch/device/key/environment, then invoke existing explicit AccountService/WatchRegistrationService admission and checked presentation update. Unknown/mismatched identity remains paused. If oldrecording permanentlystopped, UI requires explicitreload; oldcontext is never resurrected.
- For retainedcloud restoration select explicitly new authorizednamespace/root/catalogcapsule only after oldactors stopped and originalfacade closed. Old033/024/037 permanentfences are neverremoved or rebound; restore history via existing authorizedbridge.

### aggregateLocalDeletion

- Implement existing LocalTransportDeletionDriver.purgeBusinessCopies. Reload originalsamefacade saga; check backendDeleted, originalscope, localChoice, immutableplan+requestdigest andStorecomponentresult beforeleafpurge. Stop/join canonicalwriters butretain controlfacade.
- For each cataloged Cloudledger call033eraseLocalTransport usingstablechild ID andoriginalraw CloudScope; persist firstreceipt. Validate returnedrequestID/stablezone andretain leafdigest unchanged; do not reimplement internal CloudCodec or treatparentdigest asleafdigest.
- For eachstaging call024erase with stablechild/originalparentdigest/originalscope; verify receiptmatchingstablezone/request. KeepcontrolDB/WAL/ownerinodes+parents. Cloud-only deletion is independent andpreserves localassets perexisting024rule.
- For eachDeviceSync root use accepted037 final typedbinding andactualstoragebounddriver; initial andresumed erasure must use samepermanentgate andprecisequeueinventory. Pending/unresolved/unsupported/unknownnative state returns no aggregatecompletion; no globalWCcancel, no opening normalactivecomponents to resume an alreadyfencedroot.
- After everyrequiredleaf durableresult, recheck catalogmembership/rootidentities andexact firstreceipts. Return only then; LifecycleService sets localTransportProgress completed while UI localDataProgress also requires023localProgress. Any error leaves localfailed/pendingrecoverable. Health/cloud/backend groups neverborrow thissuccess.
- Oldfirstreceipt is not authorization to ignore a newlyrestoredcanonical/unknownfile. Revalidate currentinventory/zero whereleaf APIguarantees; fullcatalogcannotdrop inaccessible/mixed entries to getgreen. No physicaldisk/backup/all-device erase claim.

### healthBridge

- Build exacttargets from original StoreSnapshotV2.captureOperations: samebinding, linked(workoutID), validUUID andoriginalexternalToken; crosscheck matching CaptureRevision.metadata.segments and knownmapping. CaptureSegment.id is externalToken + "/segment" inexistingcoordinator, but026mustnotstrip/synthesize tokens fromidstrings.
- Expectedsource is notstored inbusinesscapturemetadata. A currentplatform provenApp-source provider mustsupply it; controlledtests inject fixture source. SourcePhone/Watch mismatch ormissingmetadata staysfailed/unavailable, notassumed equal andnottranslated to deleteallWorkouts.
- StableparentconfirmationID maps to persisted028 UUID requestID/digest/confirmationID andexplicitHealthdeletion.028requests max256 exacttargets; ifmore, freeze deterministicnonoverlappingchunks andpersistallIDs/digests/confirmations beforeStoreerase, orleaveunsupportedpending withouttruncatingselection. Do not generate newchunk IDs onretry.
- AppWorkoutDeletionDriver looks up exactparentmapping, resumes028 originalrequest, and returns only when each selectedchunk entry has succeededLocally andmatchingimmutable receipt. awaitingOutcome/executing/timeout stayunknown anddo notsend anotherattempt. Count0 is an operationresult for exactlocalscope only, notallhealthabsent/readpermission.
- ActualHKStore source/permissions/userconfirmation/objectdelete remain held. Defaulthealthdriver unavailable, existingUI independentHealthfailure remains honest.

### watchAndCapture

- M4WatchRegistrationRelay implements existing WatchRegistrationAuthorizing over an injected typed request/reply transport. Message envelope explicitly distinguishes context, submit, recover and carries exact WatchRegistrationAttemptV4 canonicalbody/action unchanged. Phone verifiescurrentadmittedcontext andcalls PhoneWatchRegistrationService; it never derivesaction fromlocalattemptpresence.
- Watch ownsoriginalinstallationID, key/signer/vault andchallenge proof, thenWatchRegistrationService validatesreturnedcredential. Phone freshPoP authorizesforwardonly andnever installsWatchcredential.404/401/timeout remainunknown; only existingstrictsignedknownAbandoned closesoriginalrequest.
- 018 DeviceSyncCoordinator retains original MatchSyncService/inboundSession. SameLiveMetricsChannel feeds originalcapturegateway/display onrealpath; localtests inject deterministicWorkoutGateway toexercisebinding/recoverywithoutHealthStore. Existingv2 canonicalfacts/ACK semantics unchanged, peerACKneverclearslock/completes.
- Authoritynetwork is required for originalfreshstart/recovery perexistingprovider; committedrecording continuesoffline perexistingSession rules. No new periodiconlinecapturegate. Normalfinish remainsendedPendingSync untilmatchingfullcloudproof andnormalrelease; anomaly remainsincomplete andoldlatefacts neverrelease newlock.
- RealWC orWatchselfnetwork/Phoneproxy behavior notproven by localtypedrelay or private mailbox. Preservedefaultunavailableproductiontrust/provider; no acceptingproductionenum/grantwithoutexistingverifier.

### Retained catalog and journal

- placement: Retained integrationcontrol directory outside every removable business/staging/DeviceSync collection. Keep catalogjournal, ownerlockinode, original request/childID mappings,028ledger/selection and Keychain/staging ownercontrols. Business matches.sqlite and WAL/SHM remain logically erased via023; never unlink its live saga/capability/control tables.
- durability: M4CatalogJournal is a versioned canonical JSON file plus separate retained ownerinode. Synchronous flock/NSLock critical section validates root/parents/owner/currentjournal rawbytes and bounded completepayload before atomic tempwrite+fsync+rename+directoryfsync; journalfile may replace, ownerinode/parents must not. No await inside lock; no implicit future/corrupt reset, unknownfile adoption or path normalization. Expose deterministic crash seams only to tests. Initial026 engineering limits: encodedjournal at most1MiB, at most256immutablecapsules and paths at most4096UTF8bytes; validate thecompleteencodedreplacement beforeanyprogress. Exceedinglimits preservesoldstate andreturns explicitstorageblocked; no truncation.028targetpayloads live intheirretainedledger, journalonlykeepsminimalIDs/digests. This is controlstorage, not another MatchStore.
- ownershipCapsules: Persist immutable pernamespace/root ownershipcapsule with namespaceUUID, originalrawscope, rootdevice/inode, stablecomponentID, fixedrevision and digest. Digestbody contains only ownershipmembership, excludes derived037 binding/receipts so no selfreference. Global catalogindex can append/retire capsules but neverrewrite their originalbinding; deletion freezes an entire exactindex snapshot.037 request uses that root originalcapsule revision/digest, not a newglobaldigest that would force forbiddenrebind.
- stableChildIDs: At freeze, persist componentID -> childrequestID mapping using fixed versioned domain and UInt64 big-endian lengthframing of originalparentrequestID UTF8, parentintentdigest, immutablecapsuleID/digest, leafkind and raw originalscope. Encode digest as bounded ASCIIhex, no newrandomID onretry, no Unicode normalization.033 leafcomputes its own digest; never substitute parentdigest for it.024 receives childrequestID plusoriginalparentdigest;037 request remains tied to originalparent request/digest andits originalbinding unless finalinterface explicitly requires mapping.

- Current and retired application-owned businessnamespaces and their retainedSQLite/WAL/SHM identity/control classification. Erasure eligibility requires exclusive sameaccount ownership for wholebusinessStore; mixed/unboundlegacy staysblocked.
- Every current/retired SQLiteCloudLedger file with originalvalidatedscope membership;033 purges targetstablezone acrossepochs and leavesforeignzones/controls. No glob of only latestactivefile.
- Every024 CloudOwnedStaging root + separatecontrolDB/WAL, root.owner and control.owner plusretainedparents; rootcanonicalassets are purgeable, livecontrols neverunlink.
- Every037 managedDeviceSync root with originalimmutablebinding and all durable inbox/outbox/state plusprecise nativepending inventory. Owner/.control/parents retained, futurebound-gate and erasure-only reopen APIs consumed only after accepted037final.
- device.identity anddevelopment-peer.json/.invalidated plusauthority/fixture/key/request controls classified by authoritydomain; preserve identity/proof/controlneededforrecovery, remove only provenbusinesscopies. Unknown files blockcompleted, no broadrecursive delete.
- In-memory RecordingModel observations/history, RecoveryInbox, cloud tasks and capture resourcefactory/cache references are retired; this does not claim physical RAM/native/OS erase or remote recall.

- Hold localcomposition lifecycle barrier; stop newbusiness/registrations and awaitowned quiesce. Freeze knowncatalog membership/revision/digest andexact Healthselection/missingmapping diagnostics before calling LifecycleService.requestDeletion/resumeDeletion. Do not freeze only after LocalTransportDeletionDriver runs: Core erases Store first.
- Create stableparent deletionrequestID first, persist deletionplan thensubmit/confirm exact028 request anddurable parent->selection mapping. Only after these controls arereadback/recoverable call existing LifecycleService.requestDeletion. Crash before orafter createsaga must reuse sameparentplan; sameID differentchoices/catalog/selection rejects, never silentlyresnapshots to newaccount.
- If Healthchoice isdelete, exactWorkoutUUID/rawmatch/recorder/token/currentAppsource mapping andindependentexplicitconfirmation are persisted outsidebusiness. Missingmapping staysa durable independentHealthfailure/unresolvedselection; do not broadquery orfabricate completed. Do not erase the only neededmapping before it is safelyretained.
- On reopen, read retained originalplan/saga/capability evenafterbackendDeleted andsuspendedbinding. Verify scope/catalogdigest/IDs/rootownership before resuming; no currentaccount substitution. Only ownreceipt hashes/minimalprogress areadded underCAS, no oldbusinesspayload stored inreceipt.

### Accepted037 final mapping

Fresh root: DeviceSyncStorageContext(root:) -> persist originalcatalog capsule/binding -> bind -> managedcomponents/system factory. Resume first calls DeviceSyncErasureService(context:driver:UnavailableDeviceSyncErasureDriver()).erase(originalRequest) to persist/replay the originalfence. If incomplete, only a later enabledreal path may use WCSessionDriver(stateDirectory:erasureRequest:) with the same root/request and retain it through readiness retries. Do not rebuild activeinbox/outbox to resume a fencedroot.

DeviceSyncStorageBoundDriving is internal. Product cannot conform or use@testable; controlledhost tests may. Direct publicDeviceSyncErasureDriving injection into publicservice is a controlledcontract only, notnativeproof. Defaultprovider staysUnavailable. Nativecompletion needs successful owneractivation, currentactivated andcancel-then-recheck; pending/unresolved cannot completeaggregate.

## 026-1: Original identity/vault before the one business facade

Files:

- `native/Apps/iOS/Integration/Sources/AppIntegration/M4IdentityBootstrap.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4AccountComposition.swift`
- `native/Apps/iOS/Integration/Package.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4IdentityBootstrapTests.swift`

- [ ] Write the named behavioral regressions first:

  - `testVaultFactoryFinishesBeforeFirstBusinessSQLiteCreate`
  - `testExistingEmptyDatabaseMissingIdentityOrOriginalKeyDoesNotRegenerate`
  - `testFreshConcurrentIdentityCreationKeepsOneOriginalUUID`
  - `testReopenUsesOriginalSignerAndMonotonicFence`
  - `testUnknownLegacyNamespacePreservesBytesAndRefusesAdoption`

- [ ] Run the relevant newtestfilter, preserve actualred; compile-missing-API red is distinct from runtimeassertion failure.
- [ ] Minimal implementation: Implement noDB preflight+retainedcontrol ownership; injected vaultfactory then one repository/identity check; allrealSDK factories absent/unavailable. Preserveoriginalid/key/pin onreopen.
- [ ] Run relatedfullsuite, preserve originalassertions and rawexit/count; no historicalcount aggregation.

```sh
swift test --package-path native/Apps/iOS/Integration --scratch-path "$NATIVE_BUILD_ROOT/AppIntegrationHost" --filter M4IdentityBootstrapTests
```

- [ ] Explicitly stage ownedpaths and commit `feat: bootstrap one retained device identity before business storage`; body records actualverification andlimits. Send root an exactsource checkpoint; finalsource/final need two nonauthor reviews.

## 026-2: Same-facade account presentation and permanent old-instance shutdown

Files:

- `native/Apps/iOS/Integration/Sources/AppIntegration/M4AccountComposition.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/IntegrationContext.swift`
- `native/Modules/MatchPresentation/Sources/MatchPresentation/AppBootstrap.swift` (NATIVE-038 upstream ownership;026 waits)
- `native/Modules/MatchPresentation/Sources/MatchPresentation/AccountStatusModel.swift` (NATIVE-038 upstream ownership;026 waits)
- `native/Modules/MatchPresentation/Sources/MatchPresentation/LifecycleStatusModel.swift` (NATIVE-038 upstream ownership;026 waits)
- `native/Apps/iOS/Integration/Sources/AppIntegration/RecoveryInbox.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4AccountCompositionTests.swift`
- `native/Modules/MatchPresentation/Tests/MatchPresentationTests/AccountStatusTests.swift` (NATIVE-038 upstream ownership;026 waits)
- `native/Modules/MatchPresentation/Tests/MatchPresentationTests/LifecycleStatusTests.swift` (NATIVE-038 upstream ownership;026 waits)
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/RecoveryInboxTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/IntegrationContextTests.swift`

- [ ] Write the named behavioral regressions first:

  - `testAccountFactoryRejectsSecondFacadeOrDifferentSession`
  - `testAdmittedProjectionRejectsChangedScopeGenerationAfterAwait`
  - `testScopeRefreshCannotPublishOlderCloudProjection`
  - `testRenewedIdentityDoesNotReviveStoppedRecording`
  - `testRecoveryDetachCancelsAndJoinsOldWorkerAndDropsPending`
  - `testDeletionQuiesceRetainsOriginalFacadeForSagaUpdates`

- [ ] Run the relevant newtestfilter, preserve actualred; compile-missing-API red is distinct from runtimeassertion failure.
- [ ] Minimal implementation: Addchecked sameobjectfactory/modelprojection boundaries; separatebusinessquiesce fromfinalclose; explicitidentityfence/admission; recoveryworkerjoin. No arbitraryverifiedbool/freshSession.
- [ ] Run relatedfullsuite, preserve originalassertions and rawexit/count; no historicalcount aggregation.

```sh
swift test --package-path native/Apps/iOS/Integration --scratch-path "$NATIVE_BUILD_ROOT/AppIntegrationHost" --filter M4AccountCompositionTests
```

- [ ] Explicitly stage ownedpaths and commit `feat: compose account and recording lifecycle on the same facade`; body records actualverification andlimits. Send root an exactsource checkpoint; finalsource/final need two nonauthor reviews.

## 026-3: Immutable ownedcatalog and Health selection frozen before Store erase

Files:

- `native/Apps/iOS/Integration/Sources/AppIntegration/M4OwnedDataCatalog.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4CatalogJournal.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4HealthDeletionBridge.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4OwnedDataCatalogTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4DeletionRecoveryTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4TestSupport.swift`

- [ ] Write the named behavioral regressions first:

  - `testRetiredLedgerAndStagingRemainRequiredCatalogMembers`
  - `testCatalogCapsuleDigestHasNoSelfReferenceAndNeverRebindsOldRoot`
  - `testForeignRawUnicodeScopePreservesBytes`
  - `testUnknownOrFutureControlAndReplacedOwnerFailClosed`
  - `testCrashBeforeAndAfterFreezeReopensSameParentAndStableChildren`
  - `testHealthSelectionAndConfirmationExistBeforeAnyStoreErase`
  - `testLinkedWorkoutUsesOriginalOperationTokenAndSourceNotSegmentIDGuess`
  - `testMissingHealthSourceCannotBecomeAllWorkoutsSelection`

- [ ] Run the relevant newtestfilter, preserve actualred; compile-missing-API red is distinct from runtimeassertion failure.
- [ ] Minimal implementation: Implementboundedcanonical retainedjournal+lock+fsync, immutablecapsules/globalindex, stablechildmapping andexact028 selection/explicitconfirmation; rawscope bytes andforeignentries preserved. NoStore erase untilminimalrecoveryplan isreadback.
- [ ] Run relatedfullsuite, preserve originalassertions and rawexit/count; no historicalcount aggregation.

```sh
swift test --package-path native/Apps/iOS/Integration --scratch-path "$NATIVE_BUILD_ROOT/AppIntegrationHost" --filter M4OwnedDataCatalogTests
```

- [ ] Explicitly stage ownedpaths and commit `feat: freeze owned storage and workout deletion selections`; body records actualverification andlimits. Send root an exactsource checkpoint; finalsource/final need two nonauthor reviews.

## 026-4: Aggregate033/024/037 receipts and independent028 resume

Files:

- `native/Apps/iOS/Integration/Sources/AppIntegration/M4LocalTransportDeletion.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4HealthDeletionBridge.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4DeletionRecoveryTests.swift`

- [ ] Write the named behavioral regressions first:

  - `testOneLeafReceiptCannotCompleteWholeLocalDeletion`
  - `testStoreEraseKeepsSagaCapabilitySelectionAndOwnerInodes`
  - `testPartialLeafFailureAndLostResponseResumeOriginalChildIDsAfterReopen`
  - `testFencedDeviceRootResumesWithoutConstructingActiveInboxOutboxOrDriver`
  - `testPendingOrForeignNativeTransferCannotFabricateLocalCompletion`
  - `testRestoredCanonicalOrUnknownFileBlocksAggregateReplay`
  - `testHealthUnknownAttemptDoesNotResendOrAdvanceOtherGroups`
  - `testRetainedCloudRestoreUsesExplicitNewNamespaceAndOldWritersStayFenced`

- [ ] Run the relevant newtestfilter, preserve actualred; compile-missing-API red is distinct from runtimeassertion failure.
- [ ] Minimal implementation: Useaccepted finalleafAPIs, persistfirstreceipts underfrozenplan; onlycompositezero/knowncomplete returns. 037storageboundgate+erasure-onlyreopen arehardprerequisite notemulated. Keepallgroupsindependent.
- [ ] Run relatedfullsuite, preserve originalassertions and rawexit/count; no historicalcount aggregation.

```sh
swift test --package-path native/Apps/iOS/Integration --scratch-path "$NATIVE_BUILD_ROOT/AppIntegrationHost" --filter M4DeletionRecoveryTests
```

- [ ] Explicitly stage ownedpaths and commit `feat: resume complete owned storage deletion from retained controls`; body records actualverification andlimits. Send root an exactsource checkpoint; finalsource/final need two nonauthor reviews.

## 026-5: TypedWatch relay and original018 capture/transport composition

Files:

- `native/Apps/iOS/Integration/Sources/AppIntegration/M4WatchRegistrationRelay.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/M4ControlledAdapters.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/DeviceSyncCoordinator.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/IntegrationContext.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/IntegrationPolicy.swift`
- `native/Apps/iOS/Integration/Sources/AppIntegration/AppAssembly.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/M4WatchRegistrationRelayTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/DeviceSyncCoordinatorTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/DevicePairIntegrationTests.swift`
- `native/Apps/iOS/Integration/Tests/AppIntegrationTests/IntegrationTests.swift`

- [ ] Write the named behavioral regressions first:

  - `testSubmitAndRecoverKeepOriginalWatchCanonicalBodyAndTypedAction`
  - `testPhoneUsesFreshPoPWithoutWritingWatchCredential`
  - `testUnknownRelayFailureRetainsOriginalPendingAttempt`
  - `testOriginalRecorderAndSessionSurviveOfflineCaptureAndReopen`
  - `testIdentityChangeCancelsAndJoinsSuspendedRelayBeforeReplacement`
  - `testDefaultAndLocalControlledModesNeverConstructNativeSDKFactories`
  - `testPeerAckOrCloudOnlyCannotEnableNextMatch`

- [ ] Run the relevant newtestfilter, preserve actualred; compile-missing-API red is distinct from runtimeassertion failure.
- [ ] Minimal implementation: Injectexistingpublic AccountKit/WorkoutGateway/transportseams; DEBUGcontrolledadapters+existingbroker only; observerbeforeactivation, origsession/metricschannel retained. Preservelegacyv2bytes/noalwaysonlinecapture.
- [ ] Run relatedfullsuite, preserve originalassertions and rawexit/count; no historicalcount aggregation.

```sh
swift test --package-path native/Apps/iOS/Integration --scratch-path "$NATIVE_BUILD_ROOT/AppIntegrationHost" --filter M4WatchRegistrationRelayTests
```

- [ ] Explicitly stage ownedpaths and commit `feat: integrate typed watch registration with retained recording resources`; body records actualverification andlimits. Send root an exactsource checkpoint; finalsource/final need two nonauthor reviews.

## 026-6: Local App/project gates and honest readiness evidence

Files:

- `native/Apps/iOS/App/FootballRecordApp.swift`
- `native/Apps/Watch/App/FootballRecordWatchApp.swift`
- `native/Apps/iOS/Features/Match/PhoneMatchView.swift`
- `native/Apps/Watch/Features/Match/WatchMatchView.swift`
- `native/FootballRecord.xcodeproj/project.pbxproj`
- `native/FootballRecord.xcodeproj/xcshareddata/xcschemes/FootballRecord-iOS.xcscheme`
- `native/FootballRecord.xcodeproj/xcshareddata/xcschemes/FootballRecord-Watch.xcscheme`
- `native/Configuration/iOS/Info.plist`
- `native/Configuration/iOS/M4-Debug-Info.plist`
- `native/Configuration/Watch/Info.plist`
- `native/Configuration/Watch/M4-Debug-Info.plist`
- `scripts/native/verify.sh`
- `scripts/native/ui-test.sh`
- `native/UITests/NativeAccountLifecycleUITests.swift`
- `native/UITests/NativeRecordingUITests.swift`
- `native/README.md`
- `native/Configuration/M4-capability-handoff.md`
- `docs/native/tasks/NATIVE-026.md`
- `docs/native/validation/NATIVE-026.md`
- `docs/superpowers/plans/2026-10-20-m4-local-integration.md`

- [ ] Write the named behavioral regressions first:

  - `testReleaseIgnoresAllDevelopmentLaunchArgumentsAndPrivateConfiguration`
  - `testControlledAccountReloadClosesOldContextBeforeNewFactory`
  - `testLocalDeletionFourGroupsRemainIndependentAfterAppReopen`
  - `testControlledRecordingStillPendingUntilFullCloudAndNormalRelease`
  - `testChangedAccountControlsReachableAt375DarkLargestFont`

- [ ] Run the relevant newtestfilter, preserve actualred; compile-missing-API red is distinct from runtimeassertion failure.
- [ ] Minimal implementation: Serialengineeringlinkage andexplicitcontrolledlaunchroute, defaultUnavailableunchanged, noentitlements/signing/realvalues. Extendverify toallcombinedproducts/suites andevidenceinventory; SDKandAppcompileonly.
- [ ] Run relatedfullsuite, preserve originalassertions and rawexit/count; no historicalcount aggregation.

```sh
swift test --package-path native/Apps/iOS/Integration --scratch-path "$NATIVE_BUILD_ROOT/AppIntegrationHost" --filter AppIntegrationTests
```

- [ ] Explicitly stage ownedpaths and commit `test: validate controlled account device integration and readiness`; body records actualverification andlimits. Send root an exactsource checkpoint; finalsource/final need two nonauthor reviews.

## Final local validation and actual gates

Run Node and all affected hostpackages on one frozen source. Build ten supportedproducts for all four minimumSDK triples (40 invocations), Debug/Release iOS+Watch genericSimulator Apps and two genericdevice Apps unsigned. Runchangedtwo-endXCUI and375ptdarklargestfont, preservingxcresult/PNG/AX and inputhashes; no realSDK services.

Bind source/final manifests to runtimeGitblob/hash/mode, ownedfiles, actualcommands/exit/count andpostrunzeroinputdrift. ActualApple/Keychain/iCloud/CloudKit/Health/WC, signing/installeddevices, original018 GPS/background/recovery, realdeploymentdurability and fullE2E remain separatepending gates. M4 is notcomplete; defaultprovider/trust/bootstrap remainUnavailable.
