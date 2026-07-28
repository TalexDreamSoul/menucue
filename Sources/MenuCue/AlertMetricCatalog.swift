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
