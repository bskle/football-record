import SwiftUI
import MatchPresentation

struct MigrationView: View {
  let context: AccountAppContext
  @State private var target = ""
  @State private var confirmLost = false
  @State private var confirmTermination = false
  var body: some View {
    Form {
      Section("当前进度") {
        Text(context.lifecycle.migrationTitle).accessibilityIdentifier("migration-status")
        if context.account.development { Text("开发迁移演练 · 原签名凭据与云检查点").font(.caption) }
        if let migration = context.lifecycle.migration {
          Text(migration.migrationID).font(.caption.monospaced()).textSelection(.enabled)
          if let remaining = context.lifecycle.remainingWait(now: .now) {
            Text("后台七天等待期：约剩 \(Int(ceil(remaining / 3600))) 小时。以后台签名期限为准，修改本机时间不能提前。").accessibilityIdentifier("migration-wait")
          }
        }
        if let issue = context.lifecycle.issue { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("lifecycle-issue") }
      }
      Section("旧手机仍可使用") {
        TextField("新手机的本机设备 ID", text: $target).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("migration-target")
        Button("准备正常迁移") { run(.prepareMigration(target)) }.disabled(target.isEmpty).accessibilityIdentifier("migration-prepare")
        Button("保存最终云检查点并停用旧手机") { run(.checkpoint) }.accessibilityIdentifier("migration-checkpoint")
        Button("在新手机接收迁移凭据") { run(.importMigration) }.accessibilityIdentifier("migration-import")
        Button("校验云记录并激活新手机") { run(.activateMigration) }.accessibilityIdentifier("migration-activate")
        Text("先处理待终结比赛与云冲突；新手机激活后仍需重新验证身份。激活不会恢复旧手机的写入资格。").font(.caption).foregroundStyle(.secondary)
      }.disabled(!context.lifecycle.available || context.lifecycle.busy)
      Section("旧手机已经丢失") {
        Text("先重新验证 Apple 身份，再明确申请丢失迁移。后台需要七天等待期；仍持有的比赛锁必须另行确认终结。").font(.subheadline)
        Button("申请丢失设备迁移", role: .destructive) { confirmLost = true }.accessibilityIdentifier("migration-lost")
        Button("确认丢失比赛并请求终结", role: .destructive) { confirmTermination = true }.accessibilityIdentifier("migration-lost-end")
        Button("等待期后激活新手机") { run(.forceMigration) }.accessibilityIdentifier("migration-force")
      }.disabled(!context.lifecycle.available || context.lifecycle.busy)
    }.navigationTitle("设备迁移").task { await context.lifecycle.refresh(matchID: context.recording.snapshot?.replay.matchID) }
      .alert("申请丢失迁移？", isPresented: $confirmLost) {
        Button("取消", role: .cancel) {}
        Button("确认申请", role: .destructive) { run(.requestLost) }
      } message: { Text("这会向后台保留原迁移请求，不能跳过七天等待期。") }
      .alert("终结丢失设备上的比赛？", isPresented: $confirmTermination) {
        Button("取消", role: .cancel) {}
        Button("确认终结", role: .destructive) { run(.confirmLostEnd) }
      } message: { Text("必须找到原比赛锁的可验证凭据；未保存的运动数据无法补回，不能标成完整比赛。") }
  }
  private func run(_ action: LifecycleUserAction) { Task { await context.lifecycle.perform(action, matchID: context.recording.snapshot?.replay.matchID) } }
}
