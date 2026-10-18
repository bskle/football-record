import SwiftUI
import MatchPresentation

struct AccountView: View {
  let context: AccountAppContext
  var reload: () -> Void = {}
  @State private var confirmIdentityChange = false
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("球历", systemImage: "soccerball").font(.title2.bold())
          Text(context.account.title).font(.headline).accessibilityIdentifier("account-status")
          Text(context.account.detail).foregroundStyle(.secondary)
          if context.account.development {
            DevelopmentMarker()
            Text("开发账号 · 开发配对 · 开发云").font(.caption).accessibilityIdentifier("m4-development-marker")
            Text("本次只演练独立数据库与已登记云台账。真实 Apple、设备通信和健康权限待验收。").font(.caption).foregroundStyle(.secondary)
          }
          if let binding = context.account.binding {
            LabeledContent("设备角色", value: String(describing: binding.role))
            LabeledContent("账号代次", value: String(binding.activationEpoch))
            Text(binding.deviceID).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("account-device-id")
          }
        }
        Section("账号验证") {
          if context.account.phase != .unavailable {
            if context.account.phase == .signedOut {
              Button("通过 Apple 登录") { run(.signIn) }.accessibilityIdentifier("account-sign-in")
              if context.account.issue != nil { Button("明确重新验证 Apple 身份") { run(.renew) }.accessibilityIdentifier("account-renew") }
            } else {
              Button("继续确认原请求") { run(.recover) }.accessibilityIdentifier("account-recover")
              Button("重新验证 Apple 身份") { run(.renew) }.accessibilityIdentifier("account-renew")
            }
          }
          Button("刷新持久状态") { Task { await context.refresh() } }.accessibilityIdentifier("account-refresh")
          Button("重新载入本机记录", action: reload).accessibilityIdentifier("account-reload")
          if let issue = context.account.issue { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("account-issue") }
        }.disabled(context.account.busy)
        Section("数据与设备") {
          NavigationLink("迁移到另一台 iPhone") { MigrationView(context: context) }.accessibilityIdentifier("account-migration")
          NavigationLink("删除账号与数据") { DeleteAccountView(context: context) }.accessibilityIdentifier("account-delete")
          Toggle("允许匿名使用统计", isOn: Binding(get: { context.lifecycle.analyticsEnabled == true }, set: { enabled in Task { await context.lifecycle.perform(.analytics(enabled)) } }))
            .disabled(!context.lifecycle.available || context.lifecycle.busy || context.lifecycle.analyticsEnabled == nil).accessibilityIdentifier("analytics-toggle")
          Text(context.lifecycle.analyticsEnabled == nil ? "统计设置待确认。" : "统计默认关闭；关闭后清除尚未发送的统计队列。").font(.caption).foregroundStyle(.secondary)
          if let issue = context.lifecycle.issue { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("account-lifecycle-issue") }
        }
        if context.account.development {
          Section("开发身份检查") {
            Button("模拟账号或云身份变化", role: .destructive) { confirmIdentityChange = true }.accessibilityIdentifier("account-identity-change")
          }
        }
      }.navigationTitle("账号与数据")
        .task { await context.refresh() }
        .alert("暂停当前身份？", isPresented: $confirmIdentityChange) {
          Button("取消", role: .cancel) {}
          Button("确认身份变化", role: .destructive) { run(.identityChanged) }
        } message: { Text("会暂停当前写入并保留记录，随后需要重新验证并载入。") }
    }
  }
  private func run(_ action: AccountUserAction) { Task { await context.account.perform(action); if context.account.issue == nil { await context.refreshRecording() } } }
}
