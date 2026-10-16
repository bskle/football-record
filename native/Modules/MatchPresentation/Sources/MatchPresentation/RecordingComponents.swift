#if canImport(SwiftUI)
import SwiftUI
import MatchCore
import MatchSession

public enum MatchColors {
  public static let forest = Color(red: 21/255, green: 49/255, blue: 47/255)
  public static let paper = Color(red: 246/255, green: 243/255, blue: 236/255)
  public static let surface = Color(red: 255/255, green: 253/255, blue: 250/255)
  public static let ink = Color(red: 11/255, green: 28/255, blue: 38/255)
  public static let secondary = Color(red: 89/255, green: 105/255, blue: 101/255)
  public static let accent = Color(red: 213/255, green: 255/255, blue: 96/255)
  public static let watch = Color(red: 8/255, green: 19/255, blue: 15/255)
}
public struct DevelopmentMarker: View {
  public init() {}
  public var body: some View {
    Text("开发模拟锁").font(.caption2.bold()).foregroundStyle(MatchColors.accent)
      .padding(.horizontal, 6).padding(.vertical, 2).background(MatchColors.forest, in: Capsule())
      .accessibilityIdentifier("development-marker")
  }
}
public struct StartChoiceView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var starter = true
  let confirm: (Bool) -> Void
  public init(confirm: @escaping (Bool) -> Void) { self.confirm = confirm }
  public var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        Text("本场如何出场？").font(.headline)
        Button { starter = true } label: { Label("首发", systemImage: starter ? "checkmark.circle.fill" : "circle").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityIdentifier("choose-starter")
        Button { starter = false } label: { Label("替补", systemImage: starter ? "circle" : "checkmark.circle.fill").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityIdentifier("choose-substitute")
        Text(starter ? "开赛后自动上场" : "开赛后先在场下").font(.caption).foregroundStyle(.secondary)
        Button("确认开赛") { dismiss(); confirm(starter) }.frame(minHeight: 44).buttonStyle(.borderedProminent).accessibilityIdentifier("confirm-start")
        Button("取消", role: .cancel) { dismiss() }.frame(minHeight: 44).accessibilityIdentifier("cancel-start")
      }.padding()
    }
  }
}
public struct MatchControlView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var confirmEnd = false
  let paused: Bool
  let action: (SessionAction) -> Void
  public init(paused: Bool, action: @escaping (SessionAction) -> Void) { self.paused = paused; self.action = action }
  public var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        Text("比赛控制").font(.headline)
        Button(paused ? "继续比赛" : "暂停比赛") { dismiss(); action(paused ? .resume : .pause) }.frame(minHeight: 44).accessibilityIdentifier("pause-resume")
        Text("暂停会冻结比赛和上场时间，上下场仅影响上场时间。").font(.caption).foregroundStyle(.secondary)
        Button("结束比赛", role: .destructive) { confirmEnd = true }.frame(minHeight: 44).accessibilityIdentifier("request-end")
        Button("返回", role: .cancel) { dismiss() }.frame(minHeight: 44).accessibilityIdentifier("close-controls")
      }.padding()
    }
    .alert("结束本场比赛？", isPresented: $confirmEnd) {
      Button("继续比赛", role: .cancel) { dismiss() }.accessibilityIdentifier("cancel-end")
      Button("结束并保存", role: .destructive) { dismiss(); action(.end) }.accessibilityIdentifier("confirm-end")
    } message: { Text("结束后保留本场记录，等待完整同步。") }
  }
}
public struct RecordingIssueView: View {
  let model: RecordingModel
  public init(model: RecordingModel) { self.model = model }
  public var body: some View {
    if let issue = model.issue {
      VStack(spacing: 6) {
        Text(issue).font(.caption).accessibilityIdentifier("recording-issue")
        if model.pendingRequest != nil && !model.readOnly {
          Button("重试保存") { Task { await model.retry() } }.frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("retry-save")
        }
      }.padding(8).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}
#endif
