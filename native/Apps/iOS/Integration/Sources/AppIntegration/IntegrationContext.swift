import Foundation
import DeviceSync
import MatchSession
import MatchStore
import MatchSync
import MatchPresentation

/// One active facade/session/service/model. Shutting down is permanent; never cache
/// this context for a later environment switch.
@MainActor final class IntegrationContext {
  let repository: SQLiteSessionRepository?
  let session: MatchSession?
  let model: RecordingModel
  let coordinator: DeviceSyncCoordinator?
  let namespace: String?
  let localDeviceID: String?
  private(set) var transportUnavailable = false
  private(set) var transportDiagnostic: String?
  private var closed = false
  private init(repository: SQLiteSessionRepository?, session: MatchSession?, model: RecordingModel, coordinator: DeviceSyncCoordinator?, namespace: String?, localDeviceID: String?) {
    self.repository = repository; self.session = session; self.model = model; self.coordinator = coordinator; self.namespace = namespace; self.localDeviceID = localDeviceID
  }
  static func simulation(_ model: RecordingModel) -> IntegrationContext { IntegrationContext(repository: nil, session: nil, model: model, coordinator: nil, namespace: nil, localDeviceID: nil) }
  static func makeWithTransportFactory(root: URL, namespace: String, development: Bool, workout: any WorkoutGateway = UnavailableWorkoutGateway(), trust: any RevocablePeerTrust, transportFactory: () throws -> any SyncTransport & DeviceSyncEventSource) async throws -> IntegrationContext {
    let transport: any SyncTransport & DeviceSyncEventSource
    let effectiveTrust: any RevocablePeerTrust
    var diagnostic: String?
    do { transport = try transportFactory(); effectiveTrust = trust }
    catch {
      // Transport-owned baseline/files remain intact. Failure must not prevent
      // the only business facade from opening or restoring valid local facts.
      transport = UnavailableDeviceTransport(); effectiveTrust = UnavailableRevocableTrust()
      diagnostic = String(describing: error)
    }
    let value = try await make(root: root, namespace: namespace, development: development, workout: workout, transport: transport, trust: effectiveTrust)
    value.transportUnavailable = diagnostic != nil; value.transportDiagnostic = diagnostic
    return value
  }
  static func make(root: URL, namespace: String, development: Bool, workout: any WorkoutGateway = UnavailableWorkoutGateway(), transport: any SyncTransport & DeviceSyncEventSource, trust: any RevocablePeerTrust) async throws -> IntegrationContext {
    let composition = try AppBootstrap.composition(databaseNamespace: namespace, development: development, workout: workout, transport: transport, trust: trust, rootDirectory: root)
    do {
      let identity = PersistentDeviceIdentityProvider(url: root.appendingPathComponent(namespace).appendingPathComponent("device.identity"), repository: composition.repository)
      let localID = try await identity.localDeviceID()
      let coordinator = DeviceSyncCoordinator(events: transport, service: composition.sync, trust: trust)
      // Registration precedes any RecordingModel.load -> service.start -> SDK activation.
      await coordinator.observe()
      let model = RecordingModel(session: composition.session, repository: composition.repository, development: development, sync: coordinator)
      return IntegrationContext(repository: composition.repository, session: composition.session, model: model, coordinator: coordinator, namespace: namespace, localDeviceID: localID)
    } catch { try? await composition.repository.close(); throw error }
  }
  func shutdown() async {
    guard !closed else { return }; closed = true
    await model.shutdown()
    try? await repository?.close()
  }
}

/// A sequential replacement boundary shared by the App and host lifecycle tests.
@MainActor final class IntegrationLifecycle {
  private(set) var current: IntegrationContext?
  func replace(_ build: () async throws -> IntegrationContext) async throws -> IntegrationContext {
    var old = current; current = nil
    await old?.shutdown()
    old = nil
    // No factory/capture/transport for the next environment exists before old shutdown joins.
    let next = try await build(); current = next
    return next
  }
}

private struct UnavailableDeviceTransport: SyncTransport, DeviceSyncEventSource {
  func activate() async {}
  func deliveries() async -> AsyncStream<SyncDelivery> { AsyncStream { $0.finish() } }
  func send(_ bytes: Data, deliveryID: String) async throws { throw StoreError.syncTransportUnavailable }
  func events() async -> AsyncStream<DeviceSyncEvent> { AsyncStream { $0.finish() } }
}
