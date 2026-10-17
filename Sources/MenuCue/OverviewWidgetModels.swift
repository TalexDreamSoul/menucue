import Foundation
import SwiftUI

enum OverviewWidgetKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case today
  case systemMetrics
  case quickActions
  case batteryFlow
  case processEnergy
  case upcomingEvents

  var id: String { rawValue }

  var title: String {
    switch self {
    case .today: return L10n.string("Today")
    case .systemMetrics: return L10n.string("Hardware Monitor")
    case .quickActions: return L10n.string("Quick Actions")
    case .batteryFlow: return L10n.string("Battery Flow")
    case .processEnergy: return L10n.string("Process Energy")
    case .upcomingEvents: return L10n.string("Upcoming Events")
    }
  }

  var subtitle: String {
    switch self {
    case .today: return "融合多时区、实时跳动时钟、农历与近期日程"
    case .systemMetrics: return "CPU、内存、磁盘读写、风扇与网络实时波形"
    case .quickActions: return "一键快捷动作、脚本执行与深色模式切换"
    case .batteryFlow: return "电池流向、充放电实时功率 (W) 与续航预估"
    case .processEnergy: return "前台应用能耗占用排行与高能耗进程洞察"
    case .upcomingEvents: return "未来几小时与全天事件快速预览与倒计时"
    }
  }

  var systemImage: String {
    switch self {
    case .today: return "calendar"
    case .systemMetrics: return "cpu"
    case .quickActions: return "bolt.fill"
    case .batteryFlow: return "battery.100percent"
    case .processEnergy: return "flame.fill"
    case .upcomingEvents: return "clock.badge.checkmark"
    }
  }

  var accentTint: Color {
    switch self {
    case .today: return .red
    case .systemMetrics: return .blue
    case .quickActions: return .yellow
    case .batteryFlow: return .green
    case .processEnergy: return .orange
    case .upcomingEvents: return .purple
    }
  }
}

struct OverviewWidgetConfig: Codable, Equatable, Identifiable, Sendable {
  let kind: OverviewWidgetKind
  var isEnabled: Bool

  var id: String { kind.rawValue }

  init(kind: OverviewWidgetKind, isEnabled: Bool = true) {
    self.kind = kind
    self.isEnabled = isEnabled
  }

  static let `default`: [OverviewWidgetConfig] = [
    OverviewWidgetConfig(kind: .today, isEnabled: true),
    OverviewWidgetConfig(kind: .systemMetrics, isEnabled: true),
    OverviewWidgetConfig(kind: .quickActions, isEnabled: true),
    OverviewWidgetConfig(kind: .batteryFlow, isEnabled: true),
    OverviewWidgetConfig(kind: .processEnergy, isEnabled: false),
    OverviewWidgetConfig(kind: .upcomingEvents, isEnabled: false),
  ]

  static func normalized(from rawConfigs: [OverviewWidgetConfig]) -> [OverviewWidgetConfig] {
    var seen = Set<OverviewWidgetKind>()
    var result: [OverviewWidgetConfig] = []
    for item in rawConfigs {
      if seen.insert(item.kind).inserted {
        result.append(item)
      }
    }
    for def in Self.default where !seen.contains(def.kind) {
      result.append(def)
      seen.insert(def.kind)
    }
    return result
  }
}
