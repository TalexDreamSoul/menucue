import Combine
import Foundation

/// Which metric card currently owns the detail panel.
enum MetricDetailTarget: String, Identifiable, CaseIterable {
  case cpu
  case memory
  case disk
  case network
  case fan

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: return L10n.string("CPU & GPU")
    case .memory: return L10n.string("Memory by app")
    case .disk: return L10n.string("Storage")
    case .network: return L10n.string("Network")
    case .fan: return L10n.string("Cooling")
    }
  }
}

/// Runs expensive detail probes only while a metric card requests them.
final class SystemDetailService: ObservableObject {
  @Published private(set) var target: MetricDetailTarget?
  @Published private(set) var gpu = GPUStats()
  @Published private(set) var thermals: [ThermalReading] = []
  @Published private(set) var topProcesses: [ProcessMemoryEntry] = []
  @Published private(set) var isLoading = false

  private let refreshInterval: TimeInterval
  private let queue = DispatchQueue(
    label: "com.tagzxia.app.menucue.system-detail",
    qos: .userInitiated
  )
  private let sensorReader: SystemSensorReading
  private let gpuProvider: () -> GPUStats
  private let processProvider: () -> [ProcessMemoryEntry]
  private var timer: Timer?
  private var generation: UInt64 = 0
  private var isProbeInFlight = false
  private var needsReload = false

  init(
    refreshInterval: TimeInterval = 2,
    sensorReader: SystemSensorReading = SystemSensorReader(),
    gpuProvider: @escaping () -> GPUStats = SystemDetailProbe.gpuStats,
    processProvider: @escaping () -> [ProcessMemoryEntry] = {
      SystemDetailProbe.topMemoryProcesses()
    }
  ) {
    self.refreshInterval = refreshInterval
    self.sensorReader = sensorReader
    self.gpuProvider = gpuProvider
    self.processProvider = processProvider
  }

  deinit {
    timer?.invalidate()
  }

  func hover(_ next: MetricDetailTarget?) {
    guard next != target else { return }
    target = next
    generation &+= 1
    needsReload = false
    timer?.invalidate()
    timer = nil

    guard let next else {
      isLoading = false
      return
    }

    isLoading = !hasContent(for: next)
    load(next, generation: generation)

    guard Self.refreshes(next) else { return }
    let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
      guard let self, let target = self.target else { return }
      self.load(target, generation: self.generation)
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Keyboard and VoiceOver users can pin a panel without relying on hover.
  func toggle(_ target: MetricDetailTarget) {
    hover(self.target == target ? nil : target)
  }

  private static func refreshes(_ target: MetricDetailTarget) -> Bool {
    switch target {
    case .cpu, .memory: return true
    case .disk, .network, .fan: return false
    }
  }

  private func hasContent(for target: MetricDetailTarget) -> Bool {
    switch target {
    case .cpu: return !gpu.isEmpty || !thermals.isEmpty
    case .memory: return !topProcesses.isEmpty
    case .disk, .network, .fan: return true
    }
  }

  private func load(_ target: MetricDetailTarget, generation session: UInt64) {
    switch target {
    case .disk, .network, .fan:
      isLoading = false
      return
    case .cpu, .memory:
      break
    }

    guard !isProbeInFlight else {
      needsReload = true
      return
    }
    isProbeInFlight = true

    queue.async { [weak self] in
      guard let self else { return }
      let result: ProbeResult
      switch target {
      case .cpu:
        result = .cpu(self.gpuProvider(), self.sensorReader.readThermalBreakdown())
      case .memory:
        result = .memory(self.processProvider())
      case .disk, .network, .fan:
        return
      }

      DispatchQueue.main.async { [weak self] in
        self?.complete(result, generation: session)
      }
    }
  }

  private func complete(_ result: ProbeResult, generation session: UInt64) {
    isProbeInFlight = false
    if session == generation {
      switch result {
      case let .cpu(gpu, thermals):
        self.gpu = gpu
        self.thermals = thermals
      case let .memory(processes):
        self.topProcesses = processes
      }
      isLoading = false
    }

    let shouldReload = needsReload
    needsReload = false
    if shouldReload, let target {
      load(target, generation: generation)
    }
  }

  private enum ProbeResult {
    case cpu(GPUStats, [ThermalReading])
    case memory([ProcessMemoryEntry])
  }
}
