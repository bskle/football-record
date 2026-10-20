import AppIntegration
import MatchPresentation
import SwiftUI

@main
struct FootballRecordApp: App {
    var body: some Scene { WindowGroup { RecordingRoot() } }
}
private struct RecordingRoot: View {
    @State private var model: RecordingModel?
    @State private var context: AccountAppContext?
    @State private var applicationOwner: M4ApplicationContext?
    @State private var closeFailure: String?
    @State private var failure: String?
    @State private var replacing = false
    @State private var initializing = false
    var body: some View {
        Group {
            if let context {
                if context.account.canEnterRecording { PhoneMatchView(model: context.recording, enterDevelopment: enterDevelopment, context: context, reloadAccount: reload).id(ObjectIdentifier(context)) }
                else { AccountView(context: context, reload: reload).id(ObjectIdentifier(context)) }
            }
            else if let model { PhoneMatchView(model: model, enterDevelopment: enterDevelopment).id(ObjectIdentifier(model)) }
            else if let failure {
                VStack(spacing: 12) {
                    Text("账号服务尚未接通").font(.headline).accessibilityIdentifier("account-status")
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    Button("重试", action: reload).accessibilityIdentifier("account-retry")
                }.padding()
            }
            else { ProgressView("正在载入记录") }
        }.disabled(replacing || initializing)
          .safeAreaInset(edge: .top, spacing: 0) {
              if applicationOwner?.developmentSimulation == true {
                  Text("开发演练 · 模拟身份").font(.caption2).padding(.vertical, 4)
                      .frame(maxWidth: .infinity).background(.thinMaterial)
                      .accessibilityIdentifier("m4-controlled-identity-marker")
              }
          }
          .task { if model == nil && context == nil && applicationOwner == nil { await initialize() } }
          .alert("暂时无法关闭原记录", isPresented: Binding(get: { closeFailure != nil }, set: { if !$0 { closeFailure = nil } })) {
              Button("知道了", role: .cancel) {}
          } message: { Text(closeFailure ?? "") }
    }
    private func initialize() async {
        guard !initializing, model == nil, context == nil, applicationOwner == nil else { return }
        initializing = true; defer { initializing = false }
        do {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-testing"), let index = arguments.firstIndex(of: "--ui-dataset"), arguments.indices.contains(index + 1) {
                if let scenarioIndex = arguments.firstIndex(of: "--ui-scenario"), arguments.indices.contains(scenarioIndex + 1), let scenario = DebugRecordingScenario(rawValue: arguments[scenarioIndex + 1]) {
                    model = try await AppBootstrap.developmentScenario(scenario, dataset: arguments[index + 1])
                    return
                }
                model = try AppBootstrap.development(dataset: arguments[index + 1], failFirstScore: arguments.contains("--ui-fail-first-score"), fixedClock: arguments.contains("--ui-fixed-clock"))
                return
            }
            if arguments.contains("--m4-development") {
                let next = try await M4ApplicationBootstrap.controlledFromPrivateFile()
                // Retain the original throwing close owner before activation can
                // fail or be cancelled; reload must close it before another DB.
                applicationOwner = next
                try Task.checkCancellation(); try await next.activateControlled(); try Task.checkCancellation()
                context = next.context
                if arguments.contains("--m4-auto-signin"), let context { await context.account.perform(.signIn); await context.refresh() }
                return
            }
            #endif
            let next = try await M4ApplicationBootstrap.production()
            applicationOwner = next; await next.context.refresh(); context = next.context
        } catch M4ApplicationBootstrapError.unavailable {
            failure = "本机数据会保留。账号服务准备好后，请再重试。"
        } catch { failure = "暂时无法载入记录，请保留本机数据后重试。" }
    }
    private func reload() {
        guard !replacing else { return }; replacing = true
        Task {
            defer { replacing = false }
            do {
                if let applicationOwner { try await applicationOwner.shutdown() }
                else { await context?.shutdown() }
                await model?.shutdown(); applicationOwner = nil; context = nil; model = nil; failure = nil
                await initialize()
            } catch { closeFailure = "原记录尚未安全关闭，已保留当前数据。请重试。" }
        }
    }
    private func enterDevelopment() {
        #if DEBUG
        guard !replacing else { return }; replacing = true
        Task {
            defer { replacing = false }
            do {
                if let applicationOwner { try await applicationOwner.shutdown() }
                else { await context?.shutdown() }
                await model?.shutdown(); applicationOwner = nil; context = nil
                model = try AppBootstrap.development(dataset: UUID().uuidString)
            } catch { closeFailure = "原记录尚未安全关闭，已保留当前数据。请重试。" }
        }
        #endif
    }
}
