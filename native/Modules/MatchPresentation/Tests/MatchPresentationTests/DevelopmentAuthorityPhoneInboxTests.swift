#if DEBUG
import Foundation
import CryptoKit
import XCTest
import AccountKit
import MatchStore
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
#endif
