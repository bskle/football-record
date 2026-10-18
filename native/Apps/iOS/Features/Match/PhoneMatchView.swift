import SwiftUI
import MatchCore
import MatchSession
import MatchPresentation
import UIKit

struct PhoneMatchView: View {
  let model: RecordingModel
  let enterDevelopment: () -> Void
  var context: AccountAppContext? = nil
  var reloadAccount: () -> Void = {}
  @State private var abnormal = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var choosingStart = false
  @State private var controls = false
  private var surface: Color { scheme == .dark ? MatchColors.forest : MatchColors.surface }
  private var paper: Color { scheme == .dark ? MatchColors.watch : MatchColors.paper }
  var body: some View {
    TabView {
      match.tabItem { Label("比赛", systemImage: "soccerball") }.accessibilityIdentifier("match-tab")
      history.tabItem { Label("历史", systemImage: "clock") }
      placeholder("生涯", "完整保存的比赛将在后续版本汇总为生涯数据。").tabItem { Label("生涯", systemImage: "chart.bar") }
      settings.tabItem { Label("设置", systemImage: "gearshape") }
    }.tint(scheme == .dark ? MatchColors.accent : MatchColors.forest)
      .sheet(isPresented: $choosingStart) { StartChoiceView { starter in Task { await model.start(starter: starter) } }.presentationDetents([.medium, .large]) }
      .sheet(isPresented: $controls) { MatchControlView(paused: model.snapshot?.replay.state == .paused) { action in Task { await model.perform(action) } }.presentationDetents([.medium, .large]) }
      .task { await model.load() }
      .task(id: model.snapshot?.replay.matchID) { await context?.lifecycle.refresh(matchID: model.snapshot?.replay.matchID) }
      .alert("异常终结本场？", isPresented: $abnormal) {
        Button("继续保留", role: .cancel) {}
        Button("确认异常终结", role: .destructive) { if let context, let id = model.snapshot?.replay.matchID { Task { await context.lifecycle.perform(.abnormal(id), matchID: id) } } }
      } message: { Text("会请求后台释放比赛锁，并把比赛保留为不完整，不能当作完整同步成功。") }
      .onChange(of: model.feedbackCount) { old, new in if new > old { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
  }
  private var match: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) { Text("比赛").font(.largeTitle.bold()); if model.development { DevelopmentMarker() } }
        } else { HStack { Text("比赛").font(.largeTitle.bold()); Spacer(); if model.development { DevelopmentMarker() } } }
        if let s = model.snapshot, s.replay.state != .notStarted {
          TimelineView(.periodic(from: .now, by: 1)) { tick in
            let p = MatchProjection(snapshot: s, now: tick.date, authorityStatus: model.authorityStatus)
            VStack(alignment: .leading, spacing: 16) {
              if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                  Label { Text(p.status.replacingOccurrences(of: " · ", with: "\n")) } icon: { Image(systemName: p.paused ? "pause.circle" : p.terminal ? "clock.badge.checkmark" : "record.circle") }.font(.subheadline).accessibilityLabel(p.status).accessibilityIdentifier("match-status")
                  Text(p.onField ? "场上" : "场下").font(.subheadline.bold())
                }.frame(maxWidth: .infinity, alignment: .leading)
              } else { HStack { Label(p.status, systemImage: p.paused ? "pause.circle" : p.terminal ? "clock.badge.checkmark" : "record.circle").font(.subheadline).accessibilityIdentifier("match-status"); Spacer(); Text(p.onField ? "场上" : "场下").font(.subheadline.bold()) } }
              VStack(spacing: 12) {
                HStack { Text("本场比分"); Spacer(); Text("球历") }.font(.caption).foregroundStyle(.white.opacity(0.7))
                if typeSize.isAccessibilitySize {
                  VStack(spacing: 8) { score(p); HStack { Text("我方"); Spacer(); Text("对方") }.font(.subheadline) }
                } else { HStack(alignment: .firstTextBaseline) { Text("我方"); Spacer(); score(p); Spacer(); Text("对方") } }
              }.padding(20).foregroundStyle(.white).background(MatchColors.forest, in: RoundedRectangle(cornerRadius: 18))
              Group {
                if typeSize.isAccessibilitySize {
                  VStack(alignment: .leading, spacing: 16) { clock("比赛时间", p.matchClock, "match-clock"); Divider(); clock("上场时间", p.fieldClock, "field-clock") }.frame(maxWidth: .infinity, alignment: .leading)
                } else { HStack { clock("比赛时间", p.matchClock, "match-clock"); Spacer(); Divider(); Spacer(); clock("上场时间", p.fieldClock, "field-clock") } }
              }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 18))
              VStack(alignment: .leading, spacing: 16) {
                if typeSize.isAccessibilitySize {
                  VStack(alignment: .leading, spacing: 8) { Text("实时数据").font(.headline); Text(p.capture).font(.caption).foregroundStyle(.secondary) }
                  VStack(alignment: .leading, spacing: 14) { metric("心率", model.metrics.heartRate.text(unit: "bpm")); metric("距离", model.metrics.distance.text(unit: "km")); metric("速度", model.metrics.speed.text(unit: "km/h")); metric("GPS", model.metrics.gps) }
                } else {
                  HStack { Text("实时数据").font(.headline); Spacer(); Text(p.capture).font(.caption).foregroundStyle(.secondary) }
                  Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow { metric("心率", model.metrics.heartRate.text(unit: "bpm")); metric("距离", model.metrics.distance.text(unit: "km")) }
                    GridRow { metric("速度", model.metrics.speed.text(unit: "km/h")); metric("GPS", model.metrics.gps) }
                  }
                }
              }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier("missing-metrics")
              if let warning = p.captureWarning { Text(warning).font(.subheadline).accessibilityIdentifier("capture-warning") }
              if p.terminal {
                Text(model.canStartNext ? "本场已终结，可以开始下一场。" : "本场已保留。完整同步确认前不能开始新比赛。").font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 14))
                if model.canStartNext { Button("开始下一场") { choosingStart = true }.frame(minHeight: 52).buttonStyle(.borderedProminent).accessibilityIdentifier("start-next-match") }
                else if context?.lifecycle.available == true { Button("异常终结本场", role: .destructive) { abnormal = true }.frame(minHeight: 44).accessibilityIdentifier("abnormal-end") }
              } else {
                HStack(spacing: 12) {
                  Button(p.onField ? "下场" : "上场") { Task { await model.perform(p.onField ? .leaveField : .enterField) } }.frame(maxWidth: .infinity, minHeight: 56).foregroundStyle(.white).background(MatchColors.forest, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("field-toggle")
                  Button("比赛控制") { controls = true }.frame(maxWidth: .infinity, minHeight: 56).background(surface, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("open-controls")
                }.buttonStyle(.plain).font(.headline).disabled(!model.canRecord)
              }
              SyncStatusView(model: model, terminal: p.terminal, lifecycle: context?.lifecycle).padding(16).background(surface, in: RoundedRectangle(cornerRadius: 14))
              VStack(alignment: .leading, spacing: 14) {
                HStack { Text("最近操作").font(.headline); Spacer(); Text("已保存到本机").font(.caption).foregroundStyle(.secondary) }
                ForEach(p.recent, id: \.eventID) { event in HStack { Text(MatchProjection.clock(event.matchElapsed)).font(.caption).monospacedDigit().foregroundStyle(.secondary); Text(MatchProjection.title(event)).font(.subheadline); Spacer() } }
              }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 18))
            }
          }
        } else {
          VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "soccerball").font(.system(size: 42)).foregroundStyle(MatchColors.forest)
            Text("留下每一次上场").font(.title2.bold())
            Text("确认首发或替补后开始记录。运动数据缺失时，比赛事实仍会保留。").foregroundStyle(.secondary)
            Button("开始比赛") { choosingStart = true }.frame(maxWidth: .infinity, minHeight: 52).buttonStyle(.borderedProminent).accessibilityIdentifier("start-match").disabled(model.busy || model.pendingRequest != nil || model.readOnly)
          }.padding(22).background(surface, in: RoundedRectangle(cornerRadius: 20))
        }
        RecordingIssueView(model: model)
        if model.readOnly { Text("本机仅可查看记录").font(.subheadline) }
      }.padding(20)
    }.background(paper)
  }
  private var history: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("历史").font(.largeTitle.bold())
        if model.development { DevelopmentMarker() }
        if model.history.isEmpty { Text("还没有已保存的比赛事实。").foregroundStyle(.secondary) }
        ForEach(model.history, id: \.replay.matchID) { snapshot in
          let p = MatchProjection(snapshot: snapshot, now: .now)
          VStack(alignment: .leading, spacing: 8) { Text(snapshot.store.business.descriptor.startIntent.requestedAt, style: .date).font(.caption).foregroundStyle(.secondary); Text(p.score).font(.title2.bold()).monospacedDigit(); Text(p.status).font(.subheadline) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(surface, in: RoundedRectangle(cornerRadius: 16))
        }
        Text("完整筛选、赛后纠错与路线将在后续版本提供。").font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }.background(paper)
  }
  @ViewBuilder private var settings: some View {
    if let context { AccountView(context: context, reload: reloadAccount) }
    else { ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("设置").font(.largeTitle.bold()); Text("球历").font(.title2.bold()); Text("football-record").foregroundStyle(.secondary)
        Text("生产开赛服务、可信配对和真实运动采集仍在开发中。").font(.subheadline)
        if model.development { DevelopmentMarker(); Text("此演练使用独立记录，不代表真实开赛锁或真实运动数据。").font(.caption) }
        #if DEBUG
        Button("新建独立开发演练", action: enterDevelopment).frame(minHeight: 44).accessibilityIdentifier("enter-development")
        #endif
      }.padding(20)
    }.background(paper)
  }
  }
  private func placeholder(_ title: String, _ text: String) -> some View { ScrollView { VStack(alignment: .leading, spacing: 20) { Text(title).font(.largeTitle.bold()); Text(text).foregroundStyle(.secondary); if model.development { DevelopmentMarker() } }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }.background(paper) }
  private func score(_ p: MatchProjection) -> some View { Text(p.score).font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).accessibilityLabel("本场比分 \(p.score)").accessibilityIdentifier("match-score") }
  private func clock(_ title: String, _ value: String, _ id: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title.bold()).monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false).accessibilityIdentifier(id) } }
  private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine) }
}
