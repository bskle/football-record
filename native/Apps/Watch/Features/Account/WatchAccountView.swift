import SwiftUI
import MatchPresentation

struct WatchAccountView: View {
  let context: AccountAppContext
  var reload: () -> Void = {}
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("球历账号").font(.headline)
        Text(context.account.title).font(.subheadline.bold()).accessibilityIdentifier("account-status")
        Text(context.account.detail).font(.caption).foregroundStyle(.secondary)
        if context.account.development {
          DevelopmentMarker()
          Text("开发账号 · 开发配对 · 开发云").font(.caption2).accessibilityIdentifier("m4-development-marker")
          Text("通过 Mac 私有邮箱转交登记；真实 WatchConnectivity 待验收。").font(.caption2).foregroundStyle(.secondary)
        }
        if let binding = context.account.binding { Text(binding.deviceID).font(.caption2.monospaced()).accessibilityIdentifier("account-device-id") }
        if context.account.phase != .unavailable {
          Button(context.account.phase == .signedOut ? "通过 iPhone 登记" : "继续原登记") { run(context.account.phase == .signedOut ? .registerWatch : .recover) }.accessibilityIdentifier("account-sign-in")
          Button("重新登记验证") { run(.renew) }.accessibilityIdentifier("account-renew")
        }
        Button("刷新账号状态") { Task { await context.refresh() } }.accessibilityIdentifier("account-refresh")
        Button("重新载入记录", action: reload).accessibilityIdentifier("account-reload")
        if let issue = context.account.issue { Text(issue).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("account-issue") }
        Text(context.lifecycle.cloudLabel).font(.caption2).accessibilityIdentifier("account-cloud-status")
        Text(context.lifecycle.backendLabel).font(.caption2)
        Text("设备迁移、账号删除与统计设置请在 iPhone 核对。").font(.caption2).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
    }.buttonStyle(.bordered).disabled(context.account.busy).task { await context.refresh() }
  }
  private func run(_ action: AccountUserAction) { Task { await context.account.perform(action); await context.refreshRecording() } }
}
