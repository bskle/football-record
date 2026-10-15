import MatchCore
import SwiftUI

@main
struct FootballRecordApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(AppIdentity.chineseName)
                        .font(.largeTitle.bold())
                    Text(AppIdentity.englishName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ContentUnavailableView {
                    Label("开发预览", systemImage: "soccerball")
                } description: {
                    Text("尚未开始记录。比赛记录功能正在开发中。")
                }
            }
            .padding()
        }
    }
}
