#if os(iOS) || os(watchOS)
import Foundation
import Observation
import MatchSession
import MatchPresentation
import WorkoutCapture
import DeviceSync

@MainActor public enum AppRecoverySignal { public static let shared = RecoveryInbox() }
@MainActor private final class DeviceCaptureResources {
  let channel: LiveMetricsChannel
  let factory: AppleWorkoutDriverFactory
  let gateway: AppleWorkoutGateway
  init() {
    let channel = LiveMetricsChannel()
    // Gateway and displayed metrics must use the same channel.
    self.channel = channel
    self.factory = AppleWorkoutDriverFactory(metrics: channel)
    gateway = AppleWorkoutGateway(factory: self.factory)
  }
}

/// App composition only. One current context; replacement joins old listeners and
/// releases its capture/transport resources before constructing the next context.
@MainActor @Observable public final class AppAssembly {
  public private(set) var model: RecordingModel?
  public private(set) var mode: IntegrationMode = .production
  public private(set) var message: String?
  public private(set) var localDeviceID: String?
  public private(set) var peerStatus: String?
  public private(set) var initializing = false
  public private(set) var switching = false
  @ObservationIgnored private var preferences = EnvironmentPreferences()
  @ObservationIgnored private let gate = DeviceDatasetGate()
  @ObservationIgnored private let recovery: RecoveryInbox
  @ObservationIgnored private let lifecycle = IntegrationLifecycle()
  @ObservationIgnored private var capture: DeviceCaptureResources?
  @ObservationIgnored private var metricsTask: Task<Void, Never>?
  @ObservationIgnored private var arguments: [String] = []
  public init(recovery: RecoveryInbox = AppRecoverySignal.shared) {
    self.recovery = recovery
    recovery.attach(isReady: { [weak self] in
      guard let self, let model else { return false }
      return !initializing && !switching && !model.busy
    }, recover: { [weak self] in await self?.recoverFromSystem() })
  }
  public func initialize(arguments: [String] = ProcessInfo.processInfo.arguments) async {
    guard model == nil, !initializing else { return }
    self.arguments = arguments
    initializing = true; defer { initializing = false }
    do {
      #if DEBUG
      if let suite = argument("--integration-preferences-suite"), suite.hasPrefix("football-record-integration-acceptance-"), let defaults = UserDefaults(suiteName: suite) { preferences = EnvironmentPreferences(defaults: defaults) }
      let safe = try await gate.isSafeToLeave()
      if arguments.contains("--ui-testing"), let dataset = argument("--ui-dataset"), safe {
        let selected = IntegrationMode.uiSimulation(dataset: dataset.lowercased())
        try selected.validate(); try await replace(selected, testFixture: true); return
      }
      let preferred = try preferences.load()
      let selected: IntegrationMode = !safe || arguments.contains("--device-acceptance") ? .deviceAcceptance : preferred
      try await replace(selected); try preferences.save(selected)
      if !safe && preferred != .deviceAcceptance { message = "已恢复仍需处理的设备验收记录，暂不能切换环境。" }
      #else
      try await replace(.production)
      #endif
    } catch { message = "暂时无法载入开发环境或记录，请保留本机数据后重试。" }
  }
  #if DEBUG
  public func select(_ next: IntegrationMode) async {
    guard next != mode, !switching, !initializing, model?.busy != true else { return }
    switching = true; defer { switching = false }
    let priorModel = model, generation = model?.snapshot?.store.business.generation
    let command = model?.pendingRequest?.commandID
    do {
      let active = lifecycle.current?.namespace == DeviceDatasetGate.namespace ? lifecycle.current?.repository : nil
      guard try await gate.isSafeToLeave(activeRepository: active) else {
        message = "设备验收仍有未结束、待核对或未释放的记录，不能切换或新建演练。结束后也须等待完整确认。"; return
      }
      guard priorModel === model, model?.busy != true, generation == model?.snapshot?.store.business.generation, command == model?.pendingRequest?.commandID else {
        message = "记录正在保存或更新，暂不能切换环境。"; return
      }
      if mode == .deviceAcceptance, model?.pendingRequest != nil || model?.readOnly == true {
        message = "设备验收记录仍需核对，已保留当前环境。"; return
      }
      try next.validate(); try preferences.save(next)
      try await replace(next); message = nil
    } catch { message = "无法确认记录已安全收尾，请保留数据并重新载入。" }
  }
  #endif
  public func newUISimulation() async {
    #if DEBUG
    await select(.uiSimulation(dataset: "manual-" + UUID().uuidString.lowercased()))
    #endif
  }
  public func recoverCurrent() async {
    guard let model, !model.busy, !initializing, !switching else { return }
    await model.load() // Ordinary wake/recovery never claims a new WC activation.
  }
  private func recoverFromSystem() async {
    #if DEBUG
    if mode != .deviceAcceptance {
      switching = true; defer { switching = false }
      do { try preferences.save(.deviceAcceptance); try await replace(.deviceAcceptance) }
      catch { message = "无法恢复设备验收记录，请保留数据并重试。"; return }
    }
    #endif
    await model?.load()
  }
  private func replace(_ selected: IntegrationMode, testFixture: Bool = false) async throws {
    try selected.validate()
    let oldMetrics = metricsTask; metricsTask = nil; oldMetrics?.cancel(); await oldMetrics?.value
    model = nil; localDeviceID = nil; peerStatus = nil
    let next = try await lifecycle.replace {
      // The lifecycle has joined the previous model/service/observer and closed its facade.
      self.capture = nil
      if case .uiSimulation(let dataset) = selected {
        #if DEBUG
        let value: RecordingModel
        if testFixture, let name = self.argument("--ui-scenario"), let scenario = DebugRecordingScenario(rawValue: name) { value = try await AppBootstrap.developmentScenario(scenario, dataset: dataset) }
        else { value = try AppBootstrap.development(dataset: dataset, failFirstScore: testFixture && self.arguments.contains("--ui-fail-first-score"), fixedClock: testFixture && self.arguments.contains("--ui-fixed-clock")) }
        return .simulation(value)
        #else
        throw SessionError.developmentIsolationRequired
        #endif
      }
      let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("football-record", isDirectory: true)
      let namespace = selected == .production ? "production" : DeviceDatasetGate.namespace
      let directory = root.appendingPathComponent(namespace, isDirectory: true)
      var trust: any RevocablePeerTrust = UnavailableRevocableTrust()
      #if DEBUG
      if selected == .deviceAcceptance {
        do {
          let requested: DevicePeerConfiguration?
          if let raw = self.argument("--sync-peer-config") {
            guard raw.utf8.count <= 8192 else { throw SessionError.invalidRequest }
            requested = try JSONDecoder().decode(DevicePeerConfiguration.self, from: Data(raw.utf8))
          } else { requested = nil }
          trust = try DevicePeerTrustProvider(directory: directory, namespace: namespace, requested: requested)
        } catch { self.message = "开发配对配置无效或已失效；保留本机记录，暂不传输。" }
      }
      #endif
      let resources = DeviceCaptureResources(); self.capture = resources
      let value = try await IntegrationContext.makeWithTransportFactory(root: root, namespace: namespace, development: selected == .deviceAcceptance, workout: resources.gateway, trust: trust) { try WCSessionTransport.system(applicationSupportDirectory: directory) }
      #if DEBUG
      if selected == .deviceAcceptance {
        if value.transportUnavailable { self.peerStatus = "同步传输不可用 · 仅保存本机" }
        else if (try? await trust.authorize(.route, remoteDeviceID: nil)) != nil { self.peerStatus = "开发配对 · 设备验收" }
        else { self.peerStatus = "开发配对未配置或已失效 · 仅保存本机" }
      }
      #endif
      return value
    }
    mode = selected; model = next.model; localDeviceID = next.localDeviceID
    next.model.metrics = LiveMetrics()
    if let channel = capture?.channel {
      metricsTask = Task { [weak value = next.model] in
        for await metrics in channel.updates() { guard !Task.isCancelled else { return }; value?.metrics = MetricsMapping.presentation(metrics) }
      }
    }
  }
  private func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }
}
#endif

// M4's formal App boundary is available to the host verifier as well as the two
// Apps. The legacy SDK assembly above stays isolated until its real gate passes.
import Foundation
import MatchPresentation

public enum M4ApplicationBootstrapError: Error, Sendable, Equatable { case unavailable }
@MainActor public final class M4ApplicationContext {
  public let context: AccountAppContext
  private let original: M4AccountComposition
  init(original: M4AccountComposition) { self.original = original; context = original.context }
  /// Formal App/replacement callers receive actual owner failures and retain the
  /// original context. The public Void context callback uses the same owner.
  public func shutdown() async throws { try await original.close() }
}
@MainActor public enum M4ApplicationBootstrap {
  /// Production providers/vault are intentionally unavailable. Do not inspect a
  /// private Debug config, adopt legacy files, or open a DB before that boundary.
  public static func production(arguments: [String] = ProcessInfo.processInfo.arguments, rootDirectory: URL? = nil) async throws -> M4ApplicationContext {
    throw M4ApplicationBootstrapError.unavailable
  }
}
