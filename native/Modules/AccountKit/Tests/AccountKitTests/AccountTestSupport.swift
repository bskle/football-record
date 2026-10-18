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
