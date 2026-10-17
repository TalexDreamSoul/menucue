import Foundation

struct AlertMetricID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
  let rawValue: String

  init(rawValue: String) { self.rawValue = rawValue }
  init(stringLiteral value: String) { self.rawValue = value }
}

enum AlertMetricValueKind: String, Codable, Sendable {
  case number
  case severity
  case boolean
  case event
}

enum AlertMetricUnit: String, Codable, Sendable {
  case fraction
  case bytes
  case bytesPerSecond
  case operationsPerSecond
  case celsius
  case rpm
  case watts
  case percentPerHour
  case load
  case none
}

enum AlertMetricTargetKind: String, Codable, Sendable {
  case system
  case logicalCore
  case volumePath
  case interfaceName
  case thermalSensor
  case fanIndex
}

enum AlertMetricProviderKind: String, Codable, Hashable, Sendable {
  case system
  case cpuDetail
  case gpu
  case memoryDetail
  case storageDetail
  case networkDetail
  case thermal
  case battery
  case darkWake
}

enum AlertComparisonOperator: String, Codable, CaseIterable, Sendable {
  case above
  case below
  case atLeast
  case atMost
  case equal
  case notEqual
  case occurs
}

struct AlertMetricDefinition: Codable, Equatable, Sendable {
  let id: AlertMetricID
  let valueKind: AlertMetricValueKind
  let unit: AlertMetricUnit
  let targetKind: AlertMetricTargetKind
  let provider: AlertMetricProviderKind
  let operators: [AlertComparisonOperator]
  let minimumCadence: TimeInterval

  var supportsTargets: Bool { targetKind != .system }
}

enum AlertMetricCatalog {
  static let all: [AlertMetricDefinition] = [
    number("cpu.total.busy", .fraction, .system, .system, 10),
    number("cpu.total.user", .fraction, .system, .system, 10),
    number("cpu.total.system", .fraction, .system, .system, 10),
    number("cpu.total.idle", .fraction, .system, .system, 10),
    number("cpu.core.busy", .fraction, .logicalCore, .cpuDetail, 15),
    number("cpu.load.1m", .load, .system, .cpuDetail, 15),
    number("cpu.load.5m", .load, .system, .cpuDetail, 15),
    number("cpu.load.15m", .load, .system, .cpuDetail, 15),
    number("gpu.device.utilization", .fraction, .system, .gpu, 30),
    number("gpu.renderer.utilization", .fraction, .system, .gpu, 30),
    number("gpu.memory.inUse", .bytes, .system, .gpu, 30),
    number("memory.used", .bytes, .system, .system, 15),
    number("memory.used.percent", .fraction, .system, .system, 15),
    number("memory.app", .bytes, .system, .system, 15),
    number("memory.wired", .bytes, .system, .system, 15),
    number("memory.compressed", .bytes, .system, .system, 15),
    number("memory.cached", .bytes, .system, .system, 15),
    severity("memory.pressure", .system, .memoryDetail, 15),
    number("swap.used", .bytes, .system, .memoryDetail, 30),
    number("swap.used.percent", .fraction, .system, .memoryDetail, 30),
    number("storage.volume.used", .bytes, .volumePath, .storageDetail, 60),
    number("storage.volume.free", .bytes, .volumePath, .storageDetail, 60),
    number("storage.volume.usedPercent", .fraction, .volumePath, .storageDetail, 60),
    number("disk.read.rate", .bytesPerSecond, .system, .system, 15),
    number("disk.write.rate", .bytesPerSecond, .system, .system, 15),
    number("disk.read.operations", .operationsPerSecond, .system, .storageDetail, 30),
    number("disk.write.operations", .operationsPerSecond, .system, .storageDetail, 30),
    number("network.download.rate", .bytesPerSecond, .system, .system, 15),
    number("network.upload.rate", .bytesPerSecond, .system, .system, 15),
    number(
      "network.interface.downloadRate", .bytesPerSecond, .interfaceName, .networkDetail, 30),
    number(
      "network.interface.uploadRate", .bytesPerSecond, .interfaceName, .networkDetail, 30),
    number("sensor.cpu.temperature", .celsius, .system, .thermal, 30),
    number("sensor.thermal.temperature", .celsius, .thermalSensor, .thermal, 30),
    number("fan.speed", .rpm, .fanIndex, .thermal, 30),
    number("fan.load", .fraction, .fanIndex, .thermal, 30),
    number("battery.level", .fraction, .system, .battery, 30),
    number("battery.flow.watts", .watts, .system, .battery, 30),
    number("battery.flow.percentPerHour", .percentPerHour, .system, .battery, 30),
    boolean("battery.charging", .battery, 30),
    boolean("power.onAC", .battery, 30),
    event("event.darkWake", .darkWake),
  ]

  private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

  static func definition(for id: AlertMetricID) -> AlertMetricDefinition? {
    byID[id]
  }

  private static func number(
    _ id: AlertMetricID,
    _ unit: AlertMetricUnit,
    _ target: AlertMetricTargetKind,
    _ provider: AlertMetricProviderKind,
    _ cadence: TimeInterval
  ) -> AlertMetricDefinition {
    AlertMetricDefinition(
      id: id,
      valueKind: .number,
      unit: unit,
      targetKind: target,
      provider: provider,
      operators: [.above, .below],
      minimumCadence: cadence
    )
  }

  private static func severity(
    _ id: AlertMetricID,
    _ target: AlertMetricTargetKind,
    _ provider: AlertMetricProviderKind,
    _ cadence: TimeInterval
  ) -> AlertMetricDefinition {
    AlertMetricDefinition(
      id: id,
      valueKind: .severity,
      unit: .none,
      targetKind: target,
      provider: provider,
      operators: [.atLeast, .atMost],
      minimumCadence: cadence
    )
  }

  private static func boolean(
    _ id: AlertMetricID,
    _ provider: AlertMetricProviderKind,
    _ cadence: TimeInterval
  ) -> AlertMetricDefinition {
    AlertMetricDefinition(
      id: id,
      valueKind: .boolean,
      unit: .none,
      targetKind: .system,
      provider: provider,
      operators: [.equal, .notEqual],
      minimumCadence: cadence
    )
  }

  private static func event(
    _ id: AlertMetricID,
    _ provider: AlertMetricProviderKind
  ) -> AlertMetricDefinition {
    AlertMetricDefinition(
      id: id,
      valueKind: .event,
      unit: .none,
      targetKind: .system,
      provider: provider,
      operators: [.occurs],
      minimumCadence: 0
    )
  }
}
enum AlertEnergyLevel: Int, CaseIterable, Comparable, Sendable {
  case level1 = 1
  case level2 = 2
  case level3 = 3
  case level4 = 4
  case level5 = 5

  static func < (lhs: AlertEnergyLevel, rhs: AlertEnergyLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var title: String {
    switch self {
    case .level1: return L10n.string("Level 1 (Minimal)")
    case .level2: return L10n.string("Level 2 (Light)")
    case .level3: return L10n.string("Level 3 (Moderate)")
    case .level4: return L10n.string("Level 4 (Elevated)")
    case .level5: return L10n.string("Level 5 (Heavy)")
    }
  }

  var shortBadge: String {
    "\(rawValue)级"
  }

  var description: String {
    switch self {
    case .level1: return "事件驱动，平时零唤醒，能耗极轻。"
    case .level2: return "读取内核 Mach 瞬时快照，开销微秒级，轻量省电。"
    case .level3: return "查询硬件子系统与驱动，开销中等。"
    case .level4: return "频繁轮询存储 I/O 计数器，后台活动较高。"
    case .level5: return "遍历并排序全系统所有进程，能耗与 CPU 占用最高。"
    }
  }

  static func level(for metricID: AlertMetricID) -> AlertEnergyLevel {
    let raw = metricID.rawValue.lowercased()
    if raw.contains("process") {
      return .level5
    }
    if raw.contains("disk") || raw.contains("io.") {
      return .level4
    }
    if raw.contains("gpu") || raw.contains("network") || raw.contains("thermal") || raw.contains("fan") || raw.contains("temperature") {
      return .level3
    }
    if raw.contains("darkwake") || raw.contains("battery") {
      return .level1
    }
    return .level2
  }
}
