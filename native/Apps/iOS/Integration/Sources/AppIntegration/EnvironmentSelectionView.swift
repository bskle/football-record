#if os(iOS) || os(watchOS)
import SwiftUI
import MatchPresentation

public struct EnvironmentSelectionView: View {
  @Environment(\.dismiss) private var dismiss
  let assembly: AppAssembly
  public init(assembly: AppAssembly) { self.assembly = assembly }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("开发环境").font(.headline)
        Button("返回记录") { dismiss() }.accessibilityIdentifier("environment-close")
        Text(assembly.mode.title).accessibilityIdentifier("integration-mode")
        if assembly.model?.development == true { DevelopmentMarker() }
        Text("真实设备验收会请求运动写入与定位；仍使用开发模拟锁，不能代表正式开赛服务。纯界面演练不采集运动数据。").font(.caption)
        #if DEBUG
        Button("真实设备验收") { Task { await assembly.select(.deviceAcceptance) } }.accessibilityIdentifier("environment-device")
        Button("新建纯界面演练") { Task { await assembly.newUISimulation() } }.accessibilityIdentifier("environment-ui")
        Button("正式入口") { Task { await assembly.select(.production) } }.accessibilityIdentifier("environment-production")
        #endif
        Button("重新核对当前记录") { Task { await assembly.recoverCurrent() } }.accessibilityIdentifier("environment-recover")
        if let message = assembly.message { Text(message).font(.caption).accessibilityIdentifier("environment-issue") }
        Text("验收记录需完整确认后才能切换；暂未实现正式解锁服务，已结束仍可能保留本场。").font(.caption)
      }.buttonStyle(.bordered).disabled(assembly.switching).padding()
    }
  }
}
#endif
