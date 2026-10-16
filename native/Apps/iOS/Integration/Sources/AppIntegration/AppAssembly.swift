#if os(iOS) || os(watchOS)
import Foundation
import Observation
import MatchSession
import MatchPresentation
import WorkoutCapture

@MainActor public enum AppRecoverySignal { public static let shared = RecoveryInbox() }

@MainActor private final class DeviceCaptureResources {
  let channel: LiveMetricsChannel
  let factory: AppleWorkoutDriverFactory
  let gateway: AppleWorkoutGateway
  init() {
    let channel = LiveMetricsChannel()
    let factory = AppleWorkoutDriverFactory(metrics: channel)
    self.channel = channel; self.factory = factory
    gateway = AppleWorkoutGateway(factory: factory)
  }
}

/// App composition only. It never builds permits, drives SDK operations or selects a current match.
@MainActor @Observable public final class AppAssembly {
  public private(set) var model: RecordingModel?
  public private(set) var mode: IntegrationMode = .production
  public private(set) var message: String?
  public private(set) var initializing = false
  public private(set) var switching = false
  @ObservationIgnored private var preferences = EnvironmentPreferences()
  @ObservationIgnored private let gate = DeviceDatasetGate()
  @ObservationIgnored private let recovery: RecoveryInbox
  @ObservationIgnored private lazy var capture = DeviceCaptureResources()
  @ObservationIgnored private var models: [IntegrationMode: RecordingModel] = [:]
  @ObservationIgnored private var metricsTask: Task<Void, Never>?
  public init(recovery: RecoveryInbox = AppRecoverySignal.shared) {
    self.recovery = recovery
    recovery.attach(isReady: { [weak self] in
      guard let self, let model else { return false }
      return !initializing && !switching && !model.busy
    }, recover: { [weak self] in await self?.recoverFromSystem() })
  }
  public func initialize(arguments: [String] = ProcessInfo.processInfo.arguments) async {
    guard model == nil, !initializing else { return }
    initializing = true; defer { initializing = false }
    do {
      #if DEBUG
      if let suite = argument("--integration-preferences-suite", arguments), suite.hasPrefix("football-record-integration-acceptance-"), let defaults = UserDefaults(suiteName: suite) { preferences = EnvironmentPreferences(defaults: defaults) }
      let safe = try await gate.isSafeToLeave()
      if arguments.contains("--ui-testing"), let dataset = argument("--ui-dataset", arguments), safe {
        let dataset = dataset.lowercased()
        try IntegrationMode.uiSimulation(dataset: dataset).validate()
        let value: RecordingModel
        if let name = argument("--ui-scenario", arguments), let scenario = DebugRecordingScenario(rawValue: name) { value = try await AppBootstrap.developmentScenario(scenario, dataset: dataset) }
        else { value = try AppBootstrap.development(dataset: dataset, failFirstScore: arguments.contains("--ui-fail-first-score"), fixedClock: arguments.contains("--ui-fixed-clock")) }
        mode = .uiSimulation(dataset: dataset); model = value
        return
      }
      let preferred = try preferences.load()
      let selected: IntegrationMode = !safe || arguments.contains("--device-acceptance") ? .deviceAcceptance : preferred
      let value = try assemble(selected)
      try preferences.save(selected); activate(value, mode: selected)
      if !safe && preferred != .deviceAcceptance { message = "已恢复仍需处理的设备验收记录，暂不能切换环境。" }
      #else
      // Production authorization stays unavailable inside AppBootstrap until M4.
      let value = try AppBootstrap.production(workout: capture.gateway)
      activate(value, mode: .production)
      #endif
    } catch { message = "暂时无法载入开发环境或记录，请保留本机数据后重试。" }
  }
  #if DEBUG
  public func select(_ next: IntegrationMode) async {
    guard !switching, !initializing, model?.busy != true else { return }
    switching = true; defer { switching = false }
    let priorModel = model
    let generation = model?.snapshot?.store.business.generation
    let command = model?.pendingRequest?.commandID
    do {
      if next != mode, !(try await gate.isSafeToLeave()) {
        message = "设备验收仍有未结束、待核对或未释放的记录，不能切换或新建演练。结束后也须等待完整确认。"
        return
      }
      guard priorModel === model, model?.busy != true, generation == model?.snapshot?.store.business.generation, command == model?.pendingRequest?.commandID else {
        message = "记录正在保存或更新，暂不能切换环境。"; return
      }
      if mode == .deviceAcceptance, model?.pendingRequest != nil || model?.readOnly == true {
        message = "设备验收记录仍需核对，已保留当前环境。"; return
      }
      let value = try assemble(next)
      try preferences.save(next); activate(value, mode: next); message = nil
    } catch { message = "无法确认记录已安全收尾，已保留当前环境，请先核对。" }
  }
  #endif
  public func newUISimulation() async {
    #if DEBUG
    await select(.uiSimulation(dataset: "manual-" + UUID().uuidString.lowercased()))
    #endif
  }
  public func recoverCurrent() async {
    guard let model, !model.busy, !initializing, !switching else { return }
    await model.load()
  }
  private func recoverFromSystem() async {
    #if DEBUG
    if mode != .deviceAcceptance {
      // A system recovery signal reopens the fixed real database; never routes it into a UI fixture.
      do {
        let value = try assemble(.deviceAcceptance)
        try preferences.save(.deviceAcceptance); activate(value, mode: .deviceAcceptance)
      } catch { message = "无法恢复设备验收记录，请保留数据并重试。"; return }
    }
    #endif
    await model?.load()
  }
  private func assemble(_ selected: IntegrationMode) throws -> RecordingModel {
    try selected.validate()
    if let existing = models[selected] { return existing }
    let value: RecordingModel
    switch selected {
    case .production: value = try AppBootstrap.production(workout: capture.gateway)
    #if DEBUG
    case .deviceAcceptance: value = try AppBootstrap.development(dataset: "device-acceptance-v1", workout: capture.gateway)
    case .uiSimulation(let dataset): value = try AppBootstrap.development(dataset: dataset) // Unavailable, separate from real capture.
    #else
    case .deviceAcceptance, .uiSimulation: throw SessionError.developmentIsolationRequired
    #endif
    }
    models[selected] = value
    return value
  }
  private func activate(_ value: RecordingModel, mode: IntegrationMode) {
    metricsTask?.cancel(); metricsTask = nil
    self.mode = mode; model = value; value.metrics = LiveMetrics()
    if case .uiSimulation = mode { return }
    let channel = capture.channel
    metricsTask = Task { [weak value] in
      for await metrics in channel.updates() {
        guard !Task.isCancelled else { return }
        value?.metrics = MetricsMapping.presentation(metrics)
      }
    }
  }
  private func argument(_ flag: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }
}
#endif
