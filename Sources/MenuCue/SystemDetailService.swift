import Combine
import Foundation

/// Which metric card the pointer is currently over. `nil` means no detail is shown
/// and nothing extra is being probed.
enum MetricDetailTarget: String, Identifiable, CaseIterable {
  case cpu
  case memory
  case disk
  case network
  case fan

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: return "CPU & GPU"
    case .memory: return "Memory by app"
    case .disk: return "Storage"
    case .network: return "Network"
    case .fan: return "Cooling"
    }
  }
}

/// Backs the hover detail panels. Deliberately separate from `SystemMetricsService`:
/// enumerating every process and walking the IO registry costs far more than the
/// regular sample loop, so it only runs while a card is actually hovered.
final class SystemDetailService: ObservableObject {
  @Published private(set) var target: MetricDetailTarget?
  @Published private(set) var gpu = GPUStats()
  @Published private(set) var thermals: [ThermalReading] = []
  @Published private(set) var topProcesses: [ProcessMemoryEntry] = []
  @Published private(set) var isLoading = false

  private let refreshInterval: TimeInterval
  private let queue = DispatchQueue(label: "com.tagzxia.app.menucue.system-detail", qos: .userInitiated)
  private let sensorReader: SystemSensorReader
  private var timer: Timer?
  /// Guards against a slow scan landing after the pointer has moved on.
  private var generation = 0

  init(refreshInterval: TimeInterval = 2, sensorReader: SystemSensorReader = SystemSensorReader()) {
    self.refreshInterval = refreshInterval
    self.sensorReader = sensorReader
  }

  deinit {
    timer?.invalidate()
  }

  func hover(_ next: MetricDetailTarget?) {
    guard next != target else { return }
    target = next
    generation &+= 1
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

  /// Disk capacity does not move while you hover it, so re-scanning would be waste.
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

  private func load(_ target: MetricDetailTarget, generation: Int) {
    switch target {
    case .cpu:
      queue.async { [weak self] in
        guard let self else { return }
        let gpu = SystemDetailProbe.gpuStats()
        let thermals = self.sensorReader.readThermalBreakdown()
        DispatchQueue.main.async {
          guard generation == self.generation else { return }
          self.gpu = gpu
          self.thermals = thermals
          self.isLoading = false
        }
      }
    case .memory:
      queue.async { [weak self] in
        guard let self else { return }
        let processes = SystemDetailProbe.topMemoryProcesses()
        DispatchQueue.main.async {
          guard generation == self.generation else { return }
          self.topProcesses = processes
          self.isLoading = false
        }
      }
    case .disk, .network, .fan:
      isLoading = false
    }
  }
}
