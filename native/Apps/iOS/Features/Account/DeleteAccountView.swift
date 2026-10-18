import SwiftUI
import MatchPresentation

struct DeleteAccountView: View {
  let context: AccountAppContext
  @State private var cloud = false
  @State private var local = false
  @State private var health = false
  @State private var healthConfirmed = false
  @State private var confirm = false
  var body: some View {
    Form {
      Section("分别选择数据处理方式") {
        Text("后台账号与 Apple 授权会申请删除与撤销。其余三项独立选择；每一项会分别显示完成、保留或失败。")
        Toggle("删除 CloudKit 比赛数据", isOn: $cloud).accessibilityIdentifier("delete-cloud-choice")
        Toggle("删除本地数据", isOn: $local).accessibilityIdentifier("delete-local-choice")
        Toggle("删除 App 创建的健康运动", isOn: $health).accessibilityIdentifier("delete-health-choice")
        if health {
          Toggle("我确认仅删除球历创建的健康运动", isOn: $healthConfirmed).accessibilityIdentifier("delete-health-confirm")
          Text("健康数据需要独立授权。当前环境未接通真实 Health 删除，会保留失败状态供后续重试。").font(.caption).foregroundStyle(.secondary)
        }
        if context.account.development { Text("开发演练范围：当前独立记录与已登记的一个云传输台账；无资源暂存目录。其他安装与真实云空间尚未纳入。").font(.caption).accessibilityIdentifier("deletion-development-scope") }
        Button("申请删除账号", role: .destructive) { confirm = true }
          .disabled(!context.lifecycle.available || context.lifecycle.busy || (health && !healthConfirmed)).accessibilityIdentifier("request-account-delete")
      }
      if let issue = context.lifecycle.issue { Section { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("lifecycle-issue") } }
      ForEach(context.lifecycle.deletions, id: \.intent.requestID) { saga in
        Section("原删除请求进度") {
          ForEach(LifecycleStatusModel.deletionRows(saga), id: \.id) { row in
            VStack(alignment: .leading, spacing: 4) { Text(row.title).font(.headline); Text(row.detail).foregroundStyle(.secondary) }.accessibilityElement(children: .combine).accessibilityIdentifier("deletion-" + row.id)
          }
          Text(saga.finished ? "所有所选步骤已处理。" : "仍有步骤未完成，原请求会保留。").accessibilityIdentifier("deletion-summary")
          Button("继续原删除请求") { Task { await context.lifecycle.perform(.resumeDeletion(saga.intent.requestID)) } }
            .disabled(context.lifecycle.busy).accessibilityIdentifier("resume-account-delete")
        }
      }
    }.navigationTitle("删除账号与数据").task { await context.lifecycle.refresh() }
      .alert("确认申请删除？", isPresented: $confirm) {
        Button("保留账号", role: .cancel) {}
        Button("确认删除", role: .destructive) { Task { await context.lifecycle.perform(.delete(cloud: cloud ? .delete : .keep, local: local ? .delete : .keep, health: health ? .delete : .keep, healthConfirmed: healthConfirmed)); await context.account.refresh() } }.accessibilityIdentifier("confirm-account-delete")
      } message: { Text("请先重新验证 Apple 身份。删除结果将按四项分别保留，部分失败不会被显示为全部成功。") }
  }
}
