import SwiftUI
import MatchCore
import MatchSession
import MatchPresentation
import WatchKit

struct WatchMatchView: View {
  let model: RecordingModel
  let enterDevelopment: () -> Void
  var context: AccountAppContext? = nil
  var reloadAccount: () -> Void = {}
  @State private var account = false
  @State private var choosingStart = false
  @State private var controls = false
  @State private var page = 0
  var body: some View {
    Group {
      if let snapshot = model.snapshot, snapshot.replay.state != .notStarted {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
          let p = MatchProjection(snapshot: snapshot, now: tick.date, authorityStatus: model.authorityStatus)
          TabView(selection: $page) {
            ScrollView { overview(p).padding(.horizontal, 4) }.contentMargins(.vertical, 0, for: .scrollContent).tag(0).accessibilityIdentifier("watch-overview")
            ScrollView { quickPage(p).padding(.horizontal, 4) }.contentMargins(.vertical, 0, for: .scrollContent).tag(1).accessibilityIdentifier("watch-quick-page")
          }.tabViewStyle(.page(indexDisplayMode: .automatic))
          .sheet(isPresented: $controls) { MatchControlView(paused: p.paused) { action in Task { await model.perform(action) } } }
        }
      } else {
        ScrollView {
          VStack(spacing: 12) {
            Text("球历").font(.title2.bold())
            if model.development { DevelopmentMarker() }
            Text("用事实留下每一次上场").font(.caption).foregroundStyle(.secondary)
            Button("开始比赛") { choosingStart = true }.frame(minHeight: 44).tint(MatchColors.accent).accessibilityIdentifier("start-match").disabled(model.busy || model.pendingRequest != nil || model.readOnly)
            if context != nil { Button("账号与数据") { account = true }.accessibilityIdentifier("open-account") }
            RecordingIssueView(model: model)
            #if DEBUG
            if !model.development { Button("开发演练", action: enterDevelopment).frame(minHeight: 44).accessibilityIdentifier("enter-development") }
            #endif
          }.padding(.horizontal, 8)
        }
      }
    }
    .background(MatchColors.watch)
    .sheet(isPresented: $choosingStart) { StartChoiceView { starter in Task { await model.start(starter: starter) } } }
    .sheet(isPresented: $account) { if let context { WatchAccountView(context: context, reload: reloadAccount) } }
    .task { await model.load() }
    .task(id: model.snapshot?.replay.matchID) { await context?.lifecycle.refresh(matchID: model.snapshot?.replay.matchID) }
    .onChange(of: model.feedbackCount) { old, new in if new > old { WKInterfaceDevice.current().play(.success) } }
  }
  @ViewBuilder private func overview(_ p: MatchProjection) -> some View {
    VStack(spacing: 3) {
      HStack { if model.development { DevelopmentMarker(compact: true) }; Spacer(); Text(p.status).font(.system(size: 9, weight: .semibold)).foregroundStyle(MatchColors.accent).accessibilityIdentifier("match-status") }
      HStack(alignment: .firstTextBaseline) {
        Text("我方").font(.system(size: 10)).foregroundStyle(.secondary)
        Spacer(minLength: 3)
        Text(p.score).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
        Spacer(minLength: 3)
        Text("对方").font(.system(size: 10)).foregroundStyle(.secondary)
      }.accessibilityElement(children: .combine).accessibilityLabel("本场比分 \(p.score)").accessibilityIdentifier("match-score")
      HStack {
        clock("比赛时间", p.matchClock, "match-clock")
        Spacer(minLength: 4)
        clock("上场时间", p.fieldClock, "field-clock")
      }
      Divider()
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) { metric("心率", model.metrics.heartRate.text(unit: "bpm")); metric("速度", model.metrics.speed.text(unit: "km/h")) }
        Spacer(minLength: 4)
        VStack(alignment: .leading, spacing: 3) { metric("距离", model.metrics.distance.text(unit: "km")); metric("GPS", model.metrics.gps) }
      }.accessibilityIdentifier("missing-metrics")
      if p.terminal {
        Text(p.capture).font(.caption2).foregroundStyle(.secondary)
        Text(model.canStartNext ? "本场已终结" : "完整同步前保留本场").font(.caption2)
        if model.canStartNext { Button("开始下一场") { choosingStart = true }.accessibilityIdentifier("start-next-match") }
      } else {
        HStack(spacing: 6) {
          Button(p.onField ? "下场" : "上场") { Task { await model.perform(p.onField ? .leaveField : .enterField) } }
            .frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(MatchColors.watch).background(MatchColors.accent, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("field-toggle")
          Button("比赛控制") { controls = true }.frame(maxWidth: .infinity, minHeight: 44).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("open-controls")
        }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).disabled(!model.canRecord)
      }
      SyncStatusView(model: model, terminal: p.terminal, compact: true, lifecycle: context?.lifecycle)
      if context != nil { Button("账号与数据") { account = true }.accessibilityIdentifier("open-account") }
      if let warning = p.captureWarning { Text(warning).font(.caption2).accessibilityIdentifier("capture-warning") }
      if model.issue != nil { RecordingIssueView(model: model) }
      if model.readOnly { Text("另一台设备记录 · 仅可查看").font(.caption2) }
    }.padding(.bottom, 2)
  }
  private func clock(_ title: String, _ value: String, _ id: String) -> some View {
    VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 9)).foregroundStyle(.secondary); Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit().foregroundStyle(MatchColors.accent).accessibilityIdentifier(id) }
  }
  private func metric(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) { Text(title).font(.system(size: 9)).foregroundStyle(.secondary); Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit() }.accessibilityElement(children: .combine)
  }
  private func quickPage(_ p: MatchProjection) -> some View {
    VStack(spacing: 3) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 1) {
          if model.development { DevelopmentMarker(compact: true) }
          Text("进球 \(p.goals) · 助攻 \(p.assists)").font(.system(size: 9)).accessibilityIdentifier("personal-stats")
        }
        Spacer(minLength: 3)
        Text(p.score).font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(MatchColors.accent).accessibilityLabel("本场比分 \(p.score)").accessibilityIdentifier("quick-score")
      }
      VStack(spacing: 6) {
        HStack(spacing: 6) { quick(.myGoal); quick(.myAssist) }
        HStack(spacing: 6) { quick(.teamGoal); quick(.conceded) }
      }.disabled(!model.canRecord)
      HStack(spacing: 4) {
        if let id = model.snapshot?.lastUndoableQuickEventID, let e = model.snapshot?.store.business.events.first(where: { $0.eventID == id }) {
          VStack(alignment: .leading, spacing: 2) { Text("已记：\(MatchProjection.title(e))").foregroundStyle(MatchColors.accent).accessibilityIdentifier("last-quick"); Text("仅撤销最后一次快记").foregroundStyle(.secondary) }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
          Button("撤销") { Task { await model.perform(.undoLastQuick) } }.font(.system(size: 12)).frame(minWidth: 44, minHeight: 44).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)).buttonStyle(.plain).accessibilityIdentifier("undo-quick").disabled(!model.canRecord)
        } else { Text(p.terminal ? "本场已结束 · 待同步" : "一点即记，保存后反馈").font(.system(size: 10)).foregroundStyle(.secondary).frame(minHeight: 44) }
      }
      if model.issue != nil { RecordingIssueView(model: model) }
    }.padding(.bottom, 2)
  }
  private func quick(_ action: QuickRecordAction) -> some View {
    Button { Task { await model.perform(.quick(action)) } } label: {
      Text(MatchProjection.title(action)).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
        .foregroundStyle(action == .conceded ? Color(red: 1, green: 0.72, blue: 0.61) : action == .myGoal || action == .myAssist ? MatchColors.accent : .white)
        .background(action == .conceded ? Color.orange.opacity(0.14) : .white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18)))
    }.buttonStyle(.plain).accessibilityIdentifier("quick-" + action.rawValue)
  }
}
