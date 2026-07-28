import Foundation

/// One tab of the Dashboard pane. Ordering here is the tab-bar ordering.
enum DashboardSection: String, CaseIterable, Identifiable {
  case cpu
  case gpu
  case memory
  case storage
  case network
  case sensors

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: return L10n.string("CPU")
    case .gpu: return L10n.string("GPU")
    case .memory: return L10n.string("Memory")
    case .storage: return L10n.string("Storage")
    case .network: return L10n.string("Network")
    case .sensors: return L10n.string("Sensors")
    }
  }

  var systemImage: String {
    switch self {
    case .cpu: return "cpu"
    case .gpu: return "cube.transparent"
    case .memory: return "memorychip"
    case .storage: return "internaldrive"
    case .network: return "globe"
    case .sensors: return "thermometer.medium"
    }
  }

  /// Which popover card opens this tab. GPU has no card and is reached from the tab bar.
  init(target: MetricDetailTarget) {
    switch target {
    case .cpu: self = .cpu
    case .memory: self = .memory
    case .disk: self = .storage
    case .network: self = .network
    case .fan: self = .sensors
    }
  }

  /// Only the visible tab's probes run. Fans and the base snapshot arrive from
  /// `SystemMetricsService` regardless, so they are not listed here.
  var probes: Set<DashboardProbeKind> {
    switch self {
    case .cpu: return [.perCore, .loadAverage, .thermals]
    case .gpu: return [.gpu, .thermals]
    case .memory: return [.processes, .swap, .memoryPressure]
    case .storage: return [.volumes, .diskOperations]
    case .network: return [.interfaces]
    case .sensors: return [.thermals]
    }
  }
}

/// The individually gateable readings behind the Dashboard.
enum DashboardProbeKind: Hashable {
  case perCore
  case loadAverage
  case thermals
  case gpu
  case processes
  case swap
  case memoryPressure
  case volumes
  case diskOperations
  case interfaces
}

// MARK: - CPU

/// Which cluster a logical core belongs to. `unspecified` is used whenever the
/// topology cannot be established, so cores are never *mis*labelled.
enum CoreCluster: String, Equatable, Codable {
  case performance
  case efficiency
  case unspecified

  var title: String {
    switch self {
    case .performance: return L10n.string("Performance")
    case .efficiency: return L10n.string("Efficiency")
    case .unspecified: return L10n.string("Core")
    }
  }
}

struct CoreLoad: Identifiable, Equatable {
  let index: Int
  let busy: Double
  let cluster: CoreCluster

  var id: Int { index }
}

struct LoadAverage: Equatable {
  var one: Double = 0
  var five: Double = 0
  var fifteen: Double = 0
}

// MARK: - Memory

struct SwapUsage: Equatable {
  var used: UInt64 = 0
  var total: UInt64 = 0
  var isEncrypted = false

  /// A Mac that has never swapped reports a zero-sized file; that is "unused",
  /// not "unavailable", and the view says so rather than drawing an empty bar.
  var isInUse: Bool { total > 0 }

  var fraction: Double {
    total == 0 ? 0 : min(1, Double(used) / Double(total))
  }
}

/// Mirrors `kern.memorystatus_vm_pressure_level`. The kernel only ever reports
/// 1, 2 or 4; anything else decodes to `nil` so an unknown value is shown as
/// unknown instead of being rounded to a severity it might not have.
enum MemoryPressureLevel: Int, Equatable {
  case normal = 1
  case warning = 2
  case critical = 4

  static func decode(_ raw: Int32) -> MemoryPressureLevel? {
    MemoryPressureLevel(rawValue: Int(raw))
  }

  var title: String {
    switch self {
    case .normal: return L10n.string("Normal")
    case .warning: return L10n.string("Warning")
    case .critical: return L10n.string("Critical")
    }
  }
}

// MARK: - Storage

struct VolumeUsage: Identifiable, Equatable {
  let path: String
  let name: String
  let format: String
  let used: UInt64
  let total: UInt64
  let isInternal: Bool

  var id: String { path }

  var free: UInt64 { total > used ? total - used : 0 }

  var fraction: Double {
    total == 0 ? 0 : min(1, Double(used) / Double(total))
  }
}

/// Cumulative block-device counters. Rates are derived by the service, which owns
/// the previous sample.
struct DiskIOCounters: Equatable {
  var readOperations: UInt64 = 0
  var writeOperations: UInt64 = 0
  var readBytes: UInt64 = 0
  var writeBytes: UInt64 = 0
}

struct DiskIORates: Equatable {
  var readOperationsPerSecond: Double = 0
  var writeOperationsPerSecond: Double = 0
  var totalBytesRead: UInt64 = 0
  var totalBytesWritten: UInt64 = 0
}

// MARK: - Network

struct NetworkInterfaceInfo: Identifiable, Equatable {
  let name: String
  let ipv4Address: String?
  let macAddress: String?
  /// Raw octet counters from `if_data`. These are **32-bit and wrap every 4.29 GB**,
  /// so they are only ever differenced, never displayed — on a Mac with a few days of
  /// uptime the absolute value is meaningless. macOS exposes no public 64-bit
  /// equivalent: `RTM_IFINFO2`'s `if_data64` was measured to carry the same truncated
  /// value, so an honest "since boot" total is not available here at all.
  let counterIn: UInt64
  let counterOut: UInt64
  /// Derived by the service from two consecutive counter reads.
  var downloadBytesPerSecond: Double?
  var uploadBytesPerSecond: Double?

  var id: String { name }

  /// Worth listing when it has an address or has moved any traffic.
  var isActive: Bool {
    ipv4Address != nil || counterIn > 0 || counterOut > 0
  }
}

// MARK: - History

/// Fixed-size ring of samples, oldest first. Charts read `values` directly, so the
/// buffer keeps insertion order rather than wrapping in place.
struct MetricHistory: Equatable {
  private(set) var values: [Double] = []
  let capacity: Int

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  mutating func append(_ value: Double) {
    values.append(value)
    if values.count > capacity {
      values.removeFirst(values.count - capacity)
    }
  }
}

/// Everything the Dashboard renders on top of `SystemMetricsSnapshot`. Deliberately
/// not `Codable` and never persisted: widening the cached snapshot would invalidate
/// every stored cache, because a synthesized decoder requires all non-optional keys.
struct DashboardSnapshot: Equatable {
  var perCoreLoad: [CoreLoad] = []
  var loadAverage: LoadAverage?
  var thermals: [ThermalReading] = []
  var gpu = GPUStats()
  var topProcesses: [ProcessMemoryEntry] = []
  var swap: SwapUsage?
  var memoryPressure: MemoryPressureLevel?
  var volumes: [VolumeUsage] = []
  var diskIO: DiskIORates?
  var interfaces: [NetworkInterfaceInfo] = []
}
