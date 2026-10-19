import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

public enum AppleAdapterError: Error, Sendable, Equatable { case disabled, invalidResponse, cancelled, identityChanged, busy }
struct AppleFlowRequest: Sendable { let id: UUID; let nonceSHA256, state: String }
struct AppleFlowResponse: Sendable { let state: String; let identityToken, authorizationCode: Data }
protocol AppleAuthorizationTransport: Sendable {
    func start(_ request: AppleFlowRequest, isCurrent: @escaping @Sendable () -> Bool, completion: @escaping @Sendable (Result<AppleFlowResponse, AppleAdapterError>) -> Void)
    func cancel(_ id: UUID)
}
// Shared value-only callback gate. No SDK object or authorization enters a durable DTO.
final class SDKResultLatch<Value: Sendable>: @unchecked Sendable {
    private let lock=NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    func finish(_ result: Result<Value, any Error>) {
        lock.withLock { guard self.result==nil else {return}; self.result=result;continuation?.resume(with:result);continuation=nil }
    }
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { c in lock.withLock { if let result {c.resume(with:result)} else {continuation=c} } }
    }
}
final class SDKResultGate<Value: Sendable>: @unchecked Sendable {
    struct Ticket: Sendable {let id:UUID;let generation:Int64;let latch:SDKResultLatch<Value>}
    private let lock=NSLock()
    private var generation:Int64=0
    private var pending:[UUID:SDKResultLatch<Value>]=[:]
    func begin(exclusive:Bool=false) throws -> Ticket {
        try lock.withLock {
            guard !exclusive || pending.isEmpty else {throw AppleAdapterError.busy}
            let id=UUID(),latch=SDKResultLatch<Value>();pending[id]=latch;return Ticket(id:id,generation:generation,latch:latch)
        }
    }
    func current(_ ticket:Ticket)->Bool {lock.withLock {generation==ticket.generation && pending[ticket.id] != nil}}
    func finish(_ ticket:Ticket,_ result:Result<Value,any Error>) {
        lock.withLock {guard generation==ticket.generation,let latch=pending.removeValue(forKey:ticket.id) else {return};latch.finish(result)}
    }
    func cancel(_ ticket:Ticket,error:any Error) {lock.withLock {pending.removeValue(forKey:ticket.id)?.finish(.failure(error))}}
    func advance(to value:Int64,error:any Error) throws -> [UUID] {
        try lock.withLock {
            guard value>=generation,value<=9_007_199_254_740_991 else {throw error}
            guard value>generation else {return []};generation=value
            let ids=Array(pending.keys);for latch in pending.values {latch.finish(.failure(error))};pending.removeAll();return ids
        }
    }
}
private struct DisabledAppleTransport:AppleAuthorizationTransport {
    func start(_ request:AppleFlowRequest,isCurrent:@escaping @Sendable ()->Bool,completion:@escaping @Sendable (Result<AppleFlowResponse,AppleAdapterError>)->Void) {completion(.failure(.disabled))}
    func cancel(_ id:UUID) {}
}
public final class AppleSignInAdapter: AppleSignInDriver, @unchecked Sendable {
    private let transport:any AppleAuthorizationTransport
    private let gate=SDKResultGate<AppleAuthorization>()
    public convenience init(executionEnabled:Bool=false) {
        #if canImport(AuthenticationServices)
        self.init(transport:executionEnabled ? AppleSDKTransport() : DisabledAppleTransport())
        #else
        self.init(transport:DisabledAppleTransport())
        #endif
    }
    #if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
    public convenience init(executionEnabled:Bool=false,presentationAnchor:@escaping @MainActor @Sendable ()->ASPresentationAnchor) {
        self.init(transport:executionEnabled ? AppleSDKTransport(anchor:presentationAnchor) : DisabledAppleTransport())
    }
    #endif
    init(transport:any AppleAuthorizationTransport) {self.transport=transport}
    public func advanceIdentityFence(to generation:Int64) throws {for id in try gate.advance(to:generation,error:AppleAdapterError.identityChanged) {transport.cancel(id)}}
    public func authorize(nonceSHA256:String) async throws->AppleAuthorization {
        guard nonceSHA256.utf8.count==64,nonceSHA256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw AppleAdapterError.invalidResponse}
        let ticket=try gate.begin(exclusive:true),request=AppleFlowRequest(id:ticket.id,nonceSHA256:nonceSHA256,state:UUID().uuidString)
        return try await withTaskCancellationHandler {
            if Task.isCancelled {gate.cancel(ticket,error:AppleAdapterError.cancelled)}
            if gate.current(ticket) {
                transport.start(request,isCurrent:{[gate] in gate.current(ticket)}) {[gate] result in
                    do {
                        let response=try result.get()
                        guard response.state==request.state,response.identityToken.count+response.authorizationCode.count<=12000,
                              !response.identityToken.isEmpty,!response.authorizationCode.isEmpty,
                              let token=String(data:response.identityToken,encoding:.utf8),let code=String(data:response.authorizationCode,encoding:.utf8),
                              !token.utf8.contains(0),!code.utf8.contains(0) else {throw AppleAdapterError.invalidResponse}
                        gate.finish(ticket,.success(AppleAuthorization(identityToken:token,authorizationCode:code)))
                    } catch {gate.finish(ticket,.failure(error))}
                }
            }
            return try await ticket.latch.value()
        } onCancel: {[gate,transport] in gate.cancel(ticket,error:AppleAdapterError.cancelled);transport.cancel(ticket.id)}
    }
}
#if canImport(AuthenticationServices)
#if os(iOS) || os(macOS)
private typealias AppleAnchorProvider = @MainActor @Sendable ()->ASPresentationAnchor
#endif
private final class AppleSDKTransport:AppleAuthorizationTransport,@unchecked Sendable {
    @MainActor private var ui:AppleAuthorizationUI?
    #if os(iOS) || os(macOS)
    private let anchor:AppleAnchorProvider?
    init(anchor:AppleAnchorProvider?=nil) {self.anchor=anchor}
    #endif
    func start(_ request:AppleFlowRequest,isCurrent:@escaping @Sendable ()->Bool,completion:@escaping @Sendable (Result<AppleFlowResponse,AppleAdapterError>)->Void) {
        Task {@MainActor in
            guard isCurrent() else {return}
            if ui==nil {
                #if os(iOS) || os(macOS)
                ui=AppleAuthorizationUI(anchor:anchor)
                #else
                ui=AppleAuthorizationUI()
                #endif
            }
            ui?.start(request,completion:completion)
        }
    }
    func cancel(_ id:UUID) {Task {@MainActor in ui?.cancel(id)}}
}
@MainActor private final class AppleAuthorizationUI:NSObject,ASAuthorizationControllerDelegate {
    private var flows:[ObjectIdentifier:(UUID,@Sendable (Result<AppleFlowResponse,AppleAdapterError>)->Void)]=[:]
    private var controllers:[UUID:ASAuthorizationController]=[:]
    #if os(iOS) || os(macOS)
    let anchor:AppleAnchorProvider?
    init(anchor:AppleAnchorProvider?) {self.anchor=anchor;super.init()}
    #endif
    func start(_ flow:AppleFlowRequest,completion:@escaping @Sendable (Result<AppleFlowResponse,AppleAdapterError>)->Void) {
        #if os(iOS) || os(macOS)
        guard anchor != nil else {completion(.failure(.disabled));return}
        #endif
        let request=ASAuthorizationAppleIDProvider().createRequest();request.nonce=flow.nonceSHA256;request.state=flow.state;request.requestedScopes=[]
        let controller=ASAuthorizationController(authorizationRequests:[request]);controller.delegate=self
        #if os(iOS) || os(macOS)
        controller.presentationContextProvider=self
        #endif
        flows[ObjectIdentifier(controller)]=(flow.id,completion);controllers[flow.id]=controller;controller.performRequests()
    }
    func cancel(_ id:UUID) {
        guard let controller=controllers.removeValue(forKey:id) else {return};flows[ObjectIdentifier(controller)]=nil
        #if os(iOS) || os(macOS)
        controller.cancel()
        #endif
    }
    func authorizationController(controller:ASAuthorizationController,didCompleteWithAuthorization authorization:ASAuthorization) {
        guard let entry=flows.removeValue(forKey:ObjectIdentifier(controller)) else {return};controllers[entry.0]=nil
        guard let c=authorization.credential as? ASAuthorizationAppleIDCredential,let state=c.state,let token=c.identityToken,let code=c.authorizationCode else {entry.1(.failure(.invalidResponse));return}
        entry.1(.success(AppleFlowResponse(state:state,identityToken:token,authorizationCode:code)))
    }
    func authorizationController(controller:ASAuthorizationController,didCompleteWithError error:any Error) {
        guard let entry=flows.removeValue(forKey:ObjectIdentifier(controller)) else {return};controllers[entry.0]=nil
        entry.1(.failure((error as? ASAuthorizationError)?.code == .canceled ? .cancelled : .invalidResponse))
    }
}
#if os(iOS) || os(macOS)
extension AppleAuthorizationUI:ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller:ASAuthorizationController)->ASPresentationAnchor {anchor!()}
}
#endif
#endif
