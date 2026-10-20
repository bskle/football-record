#if DEBUG
import Foundation
import CryptoKit
import XCTest
import AccountKit
import MatchStore
import MatchCore
import MatchSession
import CloudSync
@testable import MatchPresentation

final class DevelopmentAuthorityPhoneInboxTests: XCTestCase, @unchecked Sendable {
  private struct Fixture {
    let root: URL, clients: DevelopmentAuthorityProtocolClients
    var mailbox: URL { root.appendingPathComponent("development/mailbox") }
    func incoming(_ id: String) -> URL { mailbox.appendingPathComponent("incoming/"+id+".json") }
    func response(_ id: String) -> URL { mailbox.appendingPathComponent("incoming-responses/"+id+".json") }
    func close() async { _ = await clients.close(); try? FileManager.default.removeItem(at: root) }
  }
  private func fixture(role: String = "phone") throws -> Fixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let key=try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:7,count:32)),config=DevelopmentAuthorityConfiguration(dataset:"inbox",namespace:"m4-ui-inbox-"+role,baseURL:"http://127.0.0.1:1",keyID:"fixture",publicKey:AuthorityWire.base64URL(key.publicKey.rawRepresentation),cloudSpaceID:"cloud",subject:"subject",role:role)
    return Fixture(root:root,clients:try DevelopmentAuthorityScenario.protocolClients(configuration:config,rootDirectory:root))
  }
  private func request(_ f: Fixture, operation: String, payload: Data = Data()) throws -> String {
    let id=UUID().uuidString
    try JSONSerialization.data(withJSONObject:["id":id,"operation":operation,"dataset":"inbox","payload":payload.base64EncodedString()],options:.sortedKeys).write(to:f.incoming(id))
    return id
  }
  private func reply(_ f: Fixture,_ id: String) async throws -> Data {
    let deadline=ContinuousClock.now.advanced(by:.seconds(3))
    while ContinuousClock.now<deadline {if FileManager.default.fileExists(atPath:f.response(id).path) {return try Data(contentsOf:f.response(id))};try await Task.sleep(for:.milliseconds(2))}
    throw AuthorityError.unavailable
  }
  func testOnlyPhoneMayStartAndStoppedInboxNeverRestarts() async throws {
    let watch=try fixture(role:"watch"),handler=InboxAuthorizer()
    do {try await watch.clients.startInbox(authorizer:handler);XCTFail("Watch cannot serve Phone registration") } catch {}
    await watch.close()
    let f=try fixture();try await f.clients.startInbox(authorizer:handler);try await f.clients.startInbox(authorizer:handler)
    await f.clients.stopInbox();await f.clients.stopInbox()
    do {try await f.clients.startInbox(authorizer:handler);XCTFail("inbox retirement is permanent") } catch {}
    await f.close()
  }
  func testOriginalTypedContextAndBothActionsUseExistingWireAndOpaqueReply() async throws {
    let f=try fixture(),handler=InboxAuthorizer();try await f.clients.startInbox(authorizer:handler)
    let id=try request(f,operation:"phone-context"),raw=try await reply(f,id),object=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any]),payload=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(object["payload"] as? String)))
    let expected=try await handler.registrationContext();XCTAssertEqual(try JSONDecoder().decode(WatchRegistrationContextV4.self,from:payload),expected)
    let attempt=try inboxAttempt()
    for action in [WatchRegistrationAction.submit,.recover] {
      let data=try JSONEncoder().encode(InboxWatchForward(attempt:attempt,action:action)),id=try request(f,operation:"phone-register",payload:data),raw=try await reply(f,id),result=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
      XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(result["payload"] as? String)),Data([0,255,7,128]))
    }
    let calls=await handler.actions;XCTAssertEqual(calls,[.submit,.recover]);let values=await handler.canonical;XCTAssertEqual(values,[attempt.canonicalRequest,attempt.canonicalRequest])
    await f.clients.stopInbox();let state=await f.clients.drainState();XCTAssertEqual(state,.undrained,"inbox must not delete pending original private files")
    await f.close()
  }
  func testStopJoinsUncooperativeHandlerAndCannotPublishItsLateSuccess() async throws {
    let f=try fixture(),handler=InboxAuthorizer(held:true);try await f.clients.startInbox(authorizer:handler);let id=try request(f,operation:"phone-context")
    await handler.waitForEntry();let done=InboxFlag(),stopping=Task{await f.clients.stopInbox();await done.set()}
    let deadline=ContinuousClock.now.advanced(by:.seconds(2));var stopped=false
    while ContinuousClock.now<deadline {
      do {try await f.clients.startInbox(authorizer:handler)} catch {stopped=true;break}
      try await Task.sleep(for:.milliseconds(2))
    }
    XCTAssertTrue(stopped);let early=await done.value;XCTAssertFalse(early)
    await handler.release();await stopping.value
    XCTAssertFalse(FileManager.default.fileExists(atPath:f.response(id).path));XCTAssertTrue(FileManager.default.fileExists(atPath:f.incoming(id).path))
    let state=await f.clients.drainState();XCTAssertEqual(state,.undrained);await f.close()
  }
  func testRequestOrPublishedDirectoryReplacementPreventsSuccessAndErrorPublication() async throws {
    for variant in 0..<4 {
      let f=try fixture(),handler=InboxAuthorizer(held:true,fail:variant.isMultiple(of:2));try await f.clients.startInbox(authorizer:handler);let id=try request(f,operation:"phone-context")
      await handler.waitForEntry()
      if variant<2 {let original=try Data(contentsOf:f.incoming(id));try original.write(to:f.incoming(id),options:.atomic)}
      else {let incoming=f.mailbox.appendingPathComponent("incoming"),retained=f.root.appendingPathComponent("retained");try FileManager.default.moveItem(at:incoming,to:retained);try FileManager.default.createDirectory(at:incoming,withIntermediateDirectories:false)}
      await handler.release();try await Task.sleep(for:.milliseconds(60));await f.clients.stopInbox()
      XCTAssertFalse(FileManager.default.fileExists(atPath:f.response(id).path),"original request/directory identity applies to errors too")
      let state=await f.clients.drainState();XCTAssertEqual(state,.undrained);await f.close()
    }
  }
  func testUnknownHTTPAndTimeoutRepliesCannotBecomeSignedAbandonment() async throws {
    for failure in ["notFound", "unauthorized", "timeout"] {
      let f=try fixture(),handler=InboxAuthorizer(failure:failure);try await f.clients.startInbox(authorizer:handler)
      let id=try request(f,operation:"phone-context"),raw=try await reply(f,id),object=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
      XCTAssertEqual(Set(object.keys),["issue"]);XCTAssertEqual(object["issue"] as? String,"unavailable")
      XCTAssertTrue(FileManager.default.fileExists(atPath:f.incoming(id).path));await f.clients.stopInbox();await f.close()
    }
  }
  func testBusinessInboxStopKeepsOriginalCloudMailboxUsableUntilFinalClose() async throws {
    let f=try fixture();try await f.clients.startInbox(authorizer:InboxAuthorizer());await f.clients.stopInbox()
    let scope=try CloudScope(accountID:"account",cloudSpaceID:"cloud",zoneID:"zone",activationEpoch:1)
    let deleting=Task{try await f.clients.deletePrivateZone(scope:scope)},deadline=ContinuousClock.now.advanced(by:.seconds(2))
    var response:URL?
    while ContinuousClock.now<deadline {
      for file in try FileManager.default.contentsOfDirectory(at:f.mailbox.appendingPathComponent("outgoing"),includingPropertiesForKeys:nil) {
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]);guard object["operation"] as? String == "cloud-delete" else {continue}
        let id=try XCTUnwrap(object["id"] as? String),payload=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(object["payload"] as? String)))
        XCTAssertEqual(try JSONDecoder().decode(CloudScope.self,from:payload),scope);response=f.mailbox.appendingPathComponent("responses/"+id+".json")
      }
      if response != nil {break};try await Task.sleep(for:.milliseconds(2))
    }
    let target=try XCTUnwrap(response);try JSONSerialization.data(withJSONObject:["payload":Data().base64EncodedString()]).write(to:target)
    try await deleting.value;let state=await f.clients.drainState();XCTAssertEqual(state,.drained)
    await f.close()
  }
  #if os(macOS)
  func testOriginalPhoneWatchServicesRecoverCommittedResponseThroughSameTypedInbox() async throws {
    let host=try InboxNodeFixture();defer{host.close()}
    let phone=try await host.device(role:"phone"),watch=try await host.device(role:"watch")
    let phoneIdentity=await phone.repository.syncRepositoryIdentity(),watchIdentity=await watch.repository.syncRepositoryIdentity()
    XCTAssertNotEqual(phoneIdentity,watchIdentity)
    let account=AccountService(client:phone.client,repository:phone.repository,coordinator:phone.session,deviceID:phone.material.deviceID,cloudSpaceID:"cloud",apple:InboxNodeApple(host:host))
    try await account.admitCurrentIdentity()
    let signedIn=try await account.signIn(requestID:"original-phone-auth",challengeRequestID:"original-phone-challenge")
    let phoneService=PhoneWatchRegistrationService(client:phone.client,repository:phone.repository,coordinator:phone.session)
    let handler=InboxOriginalPhoneHandler(service:phoneService,accountID:signedIn.binding.accountID)
    try await phone.clients.startInbox(authorizer:handler)
    let broker=InboxWireBroker(phone:phone.root,watch:watch.root);await broker.start()
    do {
      let authorizer=watch.clients,context=try await authorizer.registrationContext()
      let service=WatchRegistrationService(client:watch.client,repository:watch.repository,coordinator:watch.session,deviceID:watch.material.deviceID,cloudSpaceID:"cloud",authorizer:authorizer)
      try await service.admitCurrentIdentity(context:context)
      _=try host.command(["op":"fault","value":"registerWatch"])
      do {_=try await service.register(requestID:"original-watch-register",challengeRequestID:"original-watch-challenge");XCTFail("real backend COMMIT response is deliberately dropped")}
      catch {XCTAssertFalse(error is WatchRegistrationError,"transport uncertainty cannot become knownAbandoned")}
      _=try host.command(["op":"fault","value":"none"])
      let pending=try await watch.repository.pendingWatchRegistrationAttemptsV4();XCTAssertEqual(pending.count,1)
      let original=try XCTUnwrap(pending.first);XCTAssertEqual(original.requestID,"original-watch-register")
      let unbound=try await watch.repository.accountBindingV4();XCTAssertNil(unbound)
      _=await watch.clients.close();try await watch.repository.close()
      let reopened=try await host.device(role:"watch"),stored=try await reopened.repository.watchRegistrationAttemptV4(requestID:original.requestID),same=try XCTUnwrap(stored)
      XCTAssertEqual(same.canonicalRequest,original.canonicalRequest);XCTAssertEqual(reopened.material.signer.publicKey,watch.material.signer.publicKey);XCTAssertEqual(reopened.material.deviceID,watch.material.deviceID)
      let recoveredService=WatchRegistrationService(client:reopened.client,repository:reopened.repository,coordinator:reopened.session,deviceID:reopened.material.deviceID,cloudSpaceID:"cloud",authorizer:reopened.clients)
      try await recoveredService.admitCurrentIdentity(context:context)
      let result=try await recoveredService.recover(requestID:original.requestID)
      XCTAssertEqual(result.binding.role,.watch);XCTAssertEqual(result.binding.deviceID,watch.material.deviceID)
      let raw=try await reopened.repository.watchRegistrationReceiptV4(requestID:original.requestID);XCTAssertEqual(raw,result.receipt.raw)
      let phoneCredential=try await phone.material.vault.credential(),watchCredential=try await reopened.material.vault.credential()
      XCTAssertEqual(phoneCredential.deviceID,phone.material.deviceID);XCTAssertEqual(watchCredential.deviceID,watch.material.deviceID);XCTAssertNotEqual(phoneCredential.sessionID,watchCredential.sessionID)
      let ids=try await reopened.repository.pendingWatchRegistrationAttemptsV4();XCTAssertTrue(ids.isEmpty)
      let actions=await handler.actions;XCTAssertEqual(actions,[.submit,.recover]);let bodies=await handler.canonical;XCTAssertEqual(bodies,[original.canonicalRequest,original.canonicalRequest])
      let checks=await handler.identityChecks;XCTAssertEqual(checks,3,"each typed context/authorize uses original explicit Phone identity admission")
      await phone.clients.stopInbox()
      let queried=try await phone.client.query(requestID:original.requestID);XCTAssertFalse(queried.isEmpty,"inbox stop leaves original HTTP control client available")
      await broker.close();_=await reopened.clients.close();_=await watch.clients.close();_=await phone.clients.close()
      try await reopened.repository.close();try await phone.repository.close()
    } catch {
      await broker.close();_=await phone.clients.close();_=await watch.clients.close();try? await phone.repository.close();try? await watch.repository.close();throw error
    }
  }
  #endif
  private func inboxAttempt() throws -> WatchRegistrationAttemptV4 {
    let key=try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:8,count:32)),publicKey=AuthorityWire.base64URL(key.publicKey.rawRepresentation),hash=String(repeating:"a",count:64),context=try WatchRegistrationContextV4(accountID:"account",cloudSpaceID:"cloud",phoneID:"phone",activationEpoch:1,environment:.development)
    let body:[String:Any] = ["version":1,"requestID":"original-watch","watchID":"watch","watchPublicKey":publicKey,"challengeID":"original-challenge","challengeSHA256":hash]
    let raw=try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys,.withoutEscapingSlashes]),signature=try key.signature(for:AuthorityWire.signedInput("football-record.device.challenge.v1",body:raw))
    return try WatchRegistrationAttemptV4(context:context,payload:WatchRegistrationPayloadV4(requestID:"original-watch",watchID:"watch",watchPublicKey:publicKey,challengeID:"original-challenge",deviceProof:AuthorityWire.base64URL(signature)),challengeRequestID:"challenge-request",challengeSHA256:hash)
  }
}
private struct InboxWatchForward:Codable {let attempt:WatchRegistrationAttemptV4;let action:WatchRegistrationAction}
private actor InboxFlag {private(set)var value=false;func set(){value=true}}
private actor InboxAuthorizer:WatchRegistrationAuthorizing {
  private var failure:String?
  private var held:Bool,fail:Bool,entered=false,waiter:CheckedContinuation<Void,Never>?,blocked:CheckedContinuation<Void,Never>?
  private(set)var actions:[WatchRegistrationAction]=[],canonical:[Data]=[]
  init(held:Bool=false,fail:Bool=false,failure:String?=nil){self.held=held;self.fail=fail;self.failure=failure}
  func registrationContext() async throws ->WatchRegistrationContextV4 {
    entered=true;waiter?.resume();waiter=nil
    if held {await withCheckedContinuation{blocked=$0}}
    if fail {throw AuthorityError.unavailable}
    if let failure {
      if failure=="timeout" {throw URLError(.timedOut)}
      throw try JSONDecoder().decode(AuthorityHTTPFailure.self,from:JSONSerialization.data(withJSONObject:["code":failure,"requestID":"original-request","retryable":false]))
    }
    return try WatchRegistrationContextV4(accountID:"account",cloudSpaceID:"cloud",phoneID:"phone",activationEpoch:1,environment:.development)
  }
  func authorizeRegistration(_ attempt:WatchRegistrationAttemptV4,action:WatchRegistrationAction) async throws ->Data {actions.append(action);canonical.append(attempt.canonicalRequest);return Data([0,255,7,128])}
  func waitForEntry() async {if entered{return};await withCheckedContinuation{waiter=$0}}
  func release(){held=false;blocked?.resume();blocked=nil}
}
#if os(macOS)
private struct InboxOriginalDevice:Sendable {
  let root:URL,material:DevelopmentAuthorityDeviceMaterial,repository:SQLiteSessionRepository,session:MatchSession,clients:DevelopmentAuthorityProtocolClients,client:AuthorityClient
}
private final class InboxNodeFixture:@unchecked Sendable {
  let process=Process(),input=Pipe(),output=Pipe(),lock=NSRecursiveLock()
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),subject="inbox-"+UUID().uuidString
  let baseURL:String,keyID:String,publicKey:String
  init() throws {
    var repo=URL(fileURLWithPath:#filePath);for _ in 0..<6 {repo.deleteLastPathComponent()}
    process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["node",repo.appendingPathComponent("native/Modules/AccountKit/Tests/AccountKitTests/Support/authority-fixture.mjs").path,repo.path];process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.standardError
    try process.run();let meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Self.line(output.fileHandleForReading)) as? [String:Any])
    baseURL=try XCTUnwrap(meta["baseURL"] as? String);keyID=try XCTUnwrap(meta["keyID"] as? String);publicKey=try XCTUnwrap(meta["publicKey"] as? String)
    _=try command(["op":"clock","now":Int(Date().timeIntervalSince1970)])
  }
  static func line(_ h:FileHandle) throws ->Data {var bytes=Data();while let b=try h.read(upToCount:1),!b.isEmpty {if b[0]==10{return bytes};guard bytes.count<1_048_576 else{throw AuthorityError.invalidWire};bytes.append(b)};throw AuthorityError.unavailable}
  func command(_ body:[String:Any]) throws ->[String:Any] {try lock.withLock {try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:body)+Data([10]));return try XCTUnwrap(JSONSerialization.jsonObject(with:Self.line(output.fileHandleForReading)) as? [String:Any])}}
  func device(role:String) async throws ->InboxOriginalDevice {
    let dirRoot=root.appendingPathComponent(role),namespace="m4-ui-original-"+role,directory=dirRoot.appendingPathComponent(namespace),identity=directory.appendingPathComponent("device.identity")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    if !FileManager.default.fileExists(atPath:identity.path) {try Data(("football-record.identity.v1:"+UUID().uuidString).utf8).write(to:identity)}
    let text=try String(contentsOf:identity,encoding:.utf8),deviceID=String(text.dropFirst("football-record.identity.v1:".count))
    let config=DevelopmentAuthorityConfiguration(dataset:"original",namespace:namespace,baseURL:baseURL,keyID:keyID,publicKey:publicKey,cloudSpaceID:"cloud",subject:subject,role:role)
    let material=try DevelopmentAuthorityScenario.deviceMaterial(configuration:config,namespaceDirectory:directory,installationID:deviceID)
    let trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:[keyID:publicKey]),repository=try SQLiteSessionRepository(rootDirectory:dirRoot,databaseNamespace:namespace,authorityTrust:trust)
    let provider=PersistentDeviceIdentityProvider(url:identity,repository:repository),session=MatchSession(store:repository,deviceIdentity:provider,clock:SystemSessionClock(),ids:UUIDSessionIDFactory(),permits:UnavailableStartPermitProvider(),workout:UnavailableWorkoutGateway(),environment:.development(databaseNamespace:namespace))
    let clients=try DevelopmentAuthorityScenario.protocolClients(configuration:config,rootDirectory:dirRoot),client=AuthorityClient(relay:clients,vault:material.vault,signer:material.signer,trust:trust)
    return InboxOriginalDevice(root:dirRoot,material:material,repository:repository,session:session,clients:clients,client:client)
  }
  func close(){guard process.isRunning else{return};_=try? command(["op":"close"]);try? input.fileHandleForWriting.close();process.waitUntilExit();try? FileManager.default.removeItem(at:root)}
}
private struct InboxNodeApple:AppleSignInDriver {
  let host:InboxNodeFixture
  func authorize(nonceSHA256:String) async throws ->AppleAuthorization {let result=try host.command(["op":"apple","nonce":nonceSHA256,"subject":host.subject]);return AppleAuthorization(identityToken:try XCTUnwrap(result["identityToken"] as? String),authorizationCode:result["authorizationCode"] as? String ?? "controlled-inbox-code")}
}
private actor InboxOriginalPhoneHandler:WatchRegistrationAuthorizing {
  let service:PhoneWatchRegistrationService,accountID:String
  private(set)var identityChecks=0,actions:[WatchRegistrationAction]=[],canonical:[Data]=[]
  init(service:PhoneWatchRegistrationService,accountID:String){self.service=service;self.accountID=accountID}
  func registrationContext() async throws ->WatchRegistrationContextV4 {identityChecks+=1;try await service.admitCurrentIdentity(accountID:accountID);return try await service.registrationContext()}
  func authorizeRegistration(_ attempt:WatchRegistrationAttemptV4,action:WatchRegistrationAction) async throws ->Data {identityChecks+=1;try await service.admitCurrentIdentity(accountID:accountID);actions.append(action);canonical.append(attempt.canonicalRequest);return try await service.authorizeRegistration(attempt,action:action)}
}
/// Test-only byte forwarding of the existing mailbox wire, not a second production transport.
private actor InboxWireBroker {
  let phone:URL,watch:URL
  private var task:Task<Void,Never>?
  private var replied:Set<String>=[]
  init(phone:URL,watch:URL){self.phone=phone;self.watch=watch}
  func start(){guard task==nil else{return};task=Task{while !Task.isCancelled {self.turn();do{try await Task.sleep(for:.milliseconds(2))}catch{return}}}}
  private func turn() {
    let outgoing=watch.appendingPathComponent("development/mailbox/outgoing"),incoming=phone.appendingPathComponent("development/mailbox/incoming")
    for file in (try? FileManager.default.contentsOfDirectory(at:outgoing,includingPropertiesForKeys:nil)) ?? [] {
      do {
        let bytes=try Data(contentsOf:file),object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]),id=try XCTUnwrap(object["id"] as? String)
        guard UUID(uuidString:id) != nil,!replied.contains(id) else{continue}
        let destination=incoming.appendingPathComponent(id+".json"),reply=phone.appendingPathComponent("development/mailbox/incoming-responses/"+id+".json"),target=watch.appendingPathComponent("development/mailbox/responses/"+id+".json")
        if FileManager.default.fileExists(atPath:target.path){continue}
        if !FileManager.default.fileExists(atPath:destination.path){try bytes.write(to:destination,options:.withoutOverwriting)}
        if let raw=try? Data(contentsOf:reply){try raw.write(to:target,options:.withoutOverwriting);try FileManager.default.removeItem(at:destination);try FileManager.default.removeItem(at:reply);replied.insert(id)}
      } catch { /* Caller cleanup can race a directory snapshot; preserve all unclaimed files. */ }
    }
  }
  func close() async {let pending=task;pending?.cancel();await pending?.value;task=nil}
}
#endif
#endif
