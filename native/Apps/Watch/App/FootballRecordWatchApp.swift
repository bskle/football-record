import MatchPresentation
import SwiftUI

@main
struct FootballRecordWatchApp: App {
    var body: some Scene { WindowGroup { RecordingRoot() } }
}
private struct RecordingRoot: View {
    @State private var model: RecordingModel?
    @State private var context: AccountAppContext?
    @State private var failure: String?
    @State private var replacing = false
    var body: some View {
        Group {
            if let context {
                if context.account.canEnterRecording { WatchMatchView(model: context.recording, enterDevelopment: enterDevelopment, context: context, reloadAccount: reload).id(ObjectIdentifier(context)) }
                else { WatchAccountView(context: context, reload: reload).id(ObjectIdentifier(context)) }
            }
            else if let model { WatchMatchView(model: model, enterDevelopment: enterDevelopment).id(ObjectIdentifier(model)) }
            else if let failure { Text(failure).padding() }
            else { ProgressView("正在载入记录") }
        }.disabled(replacing).task { if model == nil && context == nil { await initialize() } }
    }
    private func initialize() async {
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
                context = try await DevelopmentAuthorityScenario.fromPrivateFile()
                if arguments.contains("--m4-auto-signin"), let context { await context.account.perform(.registerWatch); await context.refresh() }
                return
            }
            #endif
            let next = try AppBootstrap.accountContext(); await next.refresh(); context = next
        } catch { failure = "暂时无法载入记录，请保留本机数据后重试。" }
    }
    private func reload() {
        guard !replacing else { return }; replacing = true
        Task {
            await context?.shutdown(); await model?.shutdown(); context = nil; model = nil; failure = nil
            await initialize(); replacing = false
        }
    }
    private func enterDevelopment() {
        #if DEBUG
        guard !replacing else { return }; replacing = true
        Task {
            defer { replacing = false }
            await context?.shutdown(); context = nil
            await model?.shutdown()
            do { model = try AppBootstrap.development(dataset: UUID().uuidString) }
            catch { failure = "无法建立独立开发演练。" }
        }
        #endif
    }
}
