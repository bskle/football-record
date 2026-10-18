import XCTest
import Foundation
@testable import AccountKit

final class ManualAppleTransport: AppleAuthorizationTransport, @unchecked Sendable {
    let lock=NSLock()
    var onStart: (@Sendable () -> Void)?
    private var calls: [(AppleFlowRequest, @Sendable (Result<AppleFlowResponse, AppleAdapterError>) -> Void)]=[]
    func start(_ request: AppleFlowRequest, isCurrent: @escaping @Sendable () -> Bool, completion: @escaping @Sendable (Result<AppleFlowResponse, AppleAdapterError>) -> Void) {
        guard isCurrent() else { return }; lock.withLock { calls.append((request,completion)) }; onStart?()
    }
    private var cancelled: Set<UUID>=[]
    func cancel(_ id: UUID) {lock.withLock {_ = cancelled.insert(id)}}
    func wasCancelled(_ id:UUID)->Bool {lock.withLock {cancelled.contains(id)}}
    func request(_ i: Int=0) -> AppleFlowRequest? { lock.withLock { calls.indices.contains(i) ? calls[i].0 : nil } }
    func reply(_ result: Result<AppleFlowResponse,AppleAdapterError>, index: Int=0) { let callback=lock.withLock { calls[index].1 }; callback(result) }
}
final class AppleSignInAdapterTests: XCTestCase, @unchecked Sendable {
    let nonce=String(repeating:"a",count:64)
    func testNonceIsPassedOnceAndOnlyTransientUTF8AuthorizationReturns() async throws {
        let d=ManualAppleTransport(), a=AppleSignInAdapter(transport:d), started=expectation(description:"start")
        d.onStart={started.fulfill()}; let task=Task {try await a.authorize(nonceSHA256:nonce)}
        await fulfillment(of:[started],timeout:1); let request=try XCTUnwrap(d.request()); XCTAssertEqual(request.nonceSHA256,nonce)
        d.reply(.success(AppleFlowResponse(state:request.state,identityToken:Data("jwt".utf8),authorizationCode:Data("once".utf8))))
        let value=try await task.value; XCTAssertEqual(value.identityToken,"jwt"); XCTAssertEqual(value.authorizationCode,"once")
        d.reply(.failure(.invalidResponse))
    }
    func testWrongStateOrEmptyAuthorizationCannotReturnCredential() async throws {
        for wrongState in [true,false] {
            let d=ManualAppleTransport(), a=AppleSignInAdapter(transport:d), started=expectation(description:"start")
            d.onStart={started.fulfill()}; let task=Task {try await a.authorize(nonceSHA256:nonce)}
            await fulfillment(of:[started],timeout:1); let r=try XCTUnwrap(d.request())
            d.reply(.success(AppleFlowResponse(state:wrongState ? "wrong" : r.state,identityToken:Data("jwt".utf8),authorizationCode:wrongState ? Data("once".utf8) : Data())))
            do {_=try await task.value;XCTFail()}catch{}
        }
    }
    func testCancellationAndIdentityFenceRejectLateCallbacks() async throws {
        for cancel in [true,false] {
            let d=ManualAppleTransport(), a=AppleSignInAdapter(transport:d), started=expectation(description:"start")
            d.onStart={started.fulfill()}; let task=Task {try await a.authorize(nonceSHA256:nonce)}
            await fulfillment(of:[started],timeout:1); let r=try XCTUnwrap(d.request())
            if cancel { task.cancel() } else { try a.advanceIdentityFence(to:1) }
            d.reply(.success(AppleFlowResponse(state:r.state,identityToken:Data("jwt".utf8),authorizationCode:Data("once".utf8))))
            do {_=try await task.value;XCTFail("late callback accepted")}catch{}
            XCTAssertTrue(d.wasCancelled(r.id),"fencing must also retire the SDK operation")
        }
    }
    func testDefaultExecutionAndMalformedNonceFailWithoutAuthorization() async throws {
        let a=AppleSignInAdapter()
        do {_=try await a.authorize(nonceSHA256:nonce);XCTFail()}catch{}
        let d=ManualAppleTransport(), controlled=AppleSignInAdapter(transport:d)
        do {_=try await controlled.authorize(nonceSHA256:"raw challenge");XCTFail()}catch{}
        XCTAssertNil(d.request())
    }
}
