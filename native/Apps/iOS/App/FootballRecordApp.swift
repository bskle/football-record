import AppIntegration
import MatchPresentation
import SwiftUI

@main
struct FootballRecordApp: App {
    var body: some Scene { WindowGroup { RecordingRoot() } }
}
private struct RecordingRoot: View {
    @State private var assembly = AppAssembly()
    @State private var environments = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let model = assembly.model {
                PhoneMatchView(model: model, enterDevelopment: { Task { await assembly.newUISimulation() } }, openEnvironment: { environments = true }, environmentTitle: assembly.mode.title).id(ObjectIdentifier(model)).disabled(assembly.switching || assembly.initializing)
            } else if let message = assembly.message {
                VStack { Text(message); Button("重试载入") { Task { await assembly.initialize() } } }.padding()
            } else { ProgressView("正在载入记录") }
        }.task { await assembly.initialize() }
          .sheet(isPresented: $environments) { EnvironmentSelectionView(assembly: assembly) }
          .onChange(of: phase) { _, next in if next == .active { Task { await assembly.recoverCurrent() } } }
    }
}
