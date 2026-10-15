import MatchCore
import SwiftUI

@main
struct FootballRecordWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 12) {
                    Text(AppIdentity.chineseName)
                        .font(.title2.bold())
                    Text(AppIdentity.englishName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("开发预览")
                        .font(.headline)
                    Text("尚未开始记录。")
                    Text("比赛记录功能正在开发中。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding()
            }
        }
    }
}
