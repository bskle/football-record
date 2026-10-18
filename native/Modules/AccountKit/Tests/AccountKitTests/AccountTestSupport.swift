import Foundation
import MatchCore
import MatchStore
import MatchSession
import AccountKit

final class NodeAuthorityFixture: @unchecked Sendable {
    let process=Process(),input=Pipe(),output=Pipe()
    let metadata:Metadata
    struct Metadata:Decodable { let baseURL,publicKey,keyID,privateKey:String;let credential:DeviceCredential;let now:Int64 }
    init() throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["node",Bundle.module.url(forResource:"authority-fixture",withExtension:"mjs",subdirectory:"Support")!.path,source.path]
        process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.standardError
        try process.run();metadata=try JSONDecoder().decode(Metadata.self,from:Self.line(output.fileHandleForReading))
    }
    static func line(_ handle:FileHandle) throws -> Data {
        var data=Data()
        while let byte=try handle.read(upToCount:1),!byte.isEmpty { if byte[0]==10 { return data };data.append(byte) }
        throw AuthorityError.unavailable
    }
    func command(_ object:[String:Any]) throws -> [String:Any] {
        try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:object)+Data([10]))
        return try JSONSerialization.jsonObject(with:Self.line(output.fileHandleForReading)) as! [String:Any]
    }
    func close() { if process.isRunning { _=try? command(["op":"close"]);process.waitUntilExit() } }
    deinit { if process.isRunning { process.terminate() } }
    func client() throws -> AuthorityClient {
        let trust=try AuthorityTrustConfiguration(environment:.development,publicKeys:[metadata.keyID:metadata.publicKey])
        let signer=try DevelopmentDeviceSigner(namespace:"account-tests",rawRepresentation:AuthorityWire.decodeBase64URL(metadata.privateKey,count:32))
        let fixed=Date(timeIntervalSince1970:Double(metadata.now))
        return AuthorityClient(relay:try URLSessionAuthorityRelay(baseURL:URL(string:metadata.baseURL)!,environment:.development),vault:MemoryDeviceCredentialVault(metadata.credential),signer:signer,trust:trust,now:{fixed})
    }
}
struct FixedClock:SessionClock { let date:Date;func now()->Date {date} }
struct FixedIdentity:DeviceIdentityProvider { let value:String;func localDeviceID() async throws->String {value} }

actor TrackingGateway:WorkoutGateway {
    var operations:[CaptureOperation]=[]
    var suspendRecovery:Bool
    var recoveryContinuation:CheckedContinuation<Void,Never>?
    init(suspendRecovery:Bool=false){self.suspendRecovery=suspendRecovery}
    func releaseRecovery(){suspendRecovery=false;recoveryContinuation?.resume();recoveryContinuation=nil}
    func perform(_ operation:CaptureOperation) async->WorkoutObservation {
        operations.append(operation)
        if operation.action == .recover,suspendRecovery {await withCheckedContinuation {recoveryContinuation=$0}}
        let outcome:WorkoutOutcome
        let failure:CaptureFailure?
        switch operation.action {
        case .finish:outcome = .linked(workoutID:"original-workout");failure=nil
        case .recover:outcome = .stopped;failure = .recoveryUnavailable
        case .pause:outcome = .paused;failure=nil
        default:outcome = .running;failure=nil
        }
        return try! WorkoutObservation(operationID:operation.id,binding:operation.binding,externalToken:operation.externalToken,observedAt:operation.requestedAt,outcome:outcome,window:CaptureWindow(start:nil,end:nil),failure:failure)
    }
    func reconcile(_ operation:CaptureOperation) async->WorkoutObservation {await perform(operation)}
}
func waitForCapture(_ repo:SQLiteSessionRepository,matchID:String) async throws {
    let until=ContinuousClock.now.advanced(by:.seconds(3))
    while ContinuousClock.now<until {
        let s=try await repo.snapshotV2(matchID:matchID)
        if !s.captureOperations.isEmpty,s.captureOperations.allSatisfy({$0.state == .settled || $0.state == .failed || $0.state == .cancelled}) {return}
        try await Task.sleep(for:.milliseconds(5))
    };throw AuthorityError.unavailable
}
