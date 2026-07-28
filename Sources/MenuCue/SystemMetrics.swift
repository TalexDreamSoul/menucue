import Foundation

/// A single CPU load reading expressed as fractions of one wall-clock interval.
struct CPULoadSample: Equatable, Codable {
  var user: Double = 0
  var system: Double = 0
  var nice: Double = 0
  var idle: Double = 1

  /// Everything that is not idle, clamped to a valid fraction.
  var busy: Double {
    min(1, max(0, 1 - idle))
  }

  /// User and nice time share the same band in the chart; nice is rare and reads as user work.
  var userBand: Double {
    min(1, max(0, user + nice))
  }

  var systemBand: Double {
    min(1, max(0, system))
  }
}

struct MemoryUsage: Equatable, Codable {
  var appMemory: UInt64 = 0
  var wired: UInt64 = 0
  var compressed: UInt64 = 0
  var cached: UInt64 = 0
  var total: UInt64 = 0

  var used: UInt64 {
    appMemory &+ wired &+ compressed
  }

  var fraction: Double {
    total == 0 ? 0 : min(1, Double(used) / Double(total))
  }
}

struct DiskUsage: Equatable, Codable {
  var volumeName: String = "Macintosh HD"
  var used: UInt64 = 0
  var total: UInt64 = 0
  var readBytesPerSecond: Double = 0
  var writeBytesPerSecond: Double = 0

  var fraction: Double {
    total == 0 ? 0 : min(1, Double(used) / Double(total))
  }
}

struct NetworkUsage: Equatable, Codable {
  var downloadBytesPerSecond: Double = 0
  var uploadBytesPerSecond: Double = 0
  var interfaceName: String?
  var ipv4Address: String?
}

struct FanReading: Identifiable, Equatable, Codable {
  let index: Int
  let currentRPM: Double
  let minRPM: Double
  let maxRPM: Double

  var id: Int { index }

  /// How hard the fan is working between its idle floor and its ceiling.
  var loadFraction: Double {
    guard maxRPM > minRPM else { return 0 }
    return min(1, max(0, (currentRPM - minRPM) / (maxRPM - minRPM)))
  }
}

/// Everything the Status tab renders, refreshed as one atomic value.
struct SystemMetricsSnapshot: Equatable, Codable {
  var cpu = CPULoadSample()
  var memory = MemoryUsage()
  var disk = DiskUsage()
  var network = NetworkUsage()
  var fans: [FanReading] = []
  var cpuTemperature: Double?
  /// False until two counter samples exist, so rates are not shown as a misleading zero.
  var isPrimed = false
}

/// Hardware facts that never change while the app runs, so they are read once.
struct SystemHardwareInfo: Equatable {
  var chipName: String = "Mac"
  var physicalCores: Int = 0
  var logicalCores: Int = 0
  var performanceCores: Int = 0
  var efficiencyCores: Int = 0

  /// "10C · 4P + 6E" style summary, or a plain core count when the split is unknown.
  var coreSummary: String {
    if performanceCores > 0 && efficiencyCores > 0 {
      return "\(performanceCores)P + \(efficiencyCores)E"
    }
    if logicalCores > 0 {
      return L10n.format("%d cores", logicalCores)
    }
    return ""
  }
}

enum SystemMetricsFormatter {
  /// Capacities use decimal GB so the numbers line up with Finder and About This Mac.
  static func capacity(_ bytes: UInt64) -> String {
    byteText(Double(bytes), decimalsForGigabytes: 2)
  }

  static func rate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond >= 1 else { return "0 KB/s" }
    return byteText(bytesPerSecond, decimalsForGigabytes: 1) + "/s"
  }

  static func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
  }

  static func temperature(_ celsius: Double) -> String {
    String(format: "%.1f°C", celsius)
  }

  static func uptime(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60

    if days > 0 {
      return L10n.format("%dd %dh %dm", days, hours, minutes)
    }
    if hours > 0 {
      return L10n.format("%dh %dm", hours, minutes)
    }
    return L10n.format("%dm", minutes)
  }

  private static func byteText(_ value: Double, decimalsForGigabytes: Int) -> String {
    let units: [(threshold: Double, suffix: String, decimals: Int)] = [
      (1_000_000_000_000, "TB", decimalsForGigabytes),
      (1_000_000_000, "GB", decimalsForGigabytes),
      (1_000_000, "MB", 1),
      (1_000, "KB", 1),
    ]

    for unit in units where value >= unit.threshold {
      let scaled = value / unit.threshold
      // Three significant digits keep the column width stable as values grow.
      let decimals = scaled >= 100 ? 0 : (scaled >= 10 ? min(1, unit.decimals) : unit.decimals)
      return String(format: "%.\(decimals)f %@", scaled, unit.suffix)
    }
    return String(format: "%.0f B", value)
  }
}
