import Combine
import Foundation

/// Backs the Dashboard pane with everything `SystemMetricsService` does not already
/// sample.
///
/// Deliberately separate, for the same reason `SystemDetailService` is: enumerating
/// processes, walking the IO registry, and listing volumes cost far more than the
/// regular counter loop, so each runs only while the tab that shows it is visible.
///
/// Rate histories are *derived* from the shared `SystemMetricsService` stream rather
/// than measured again. A second set of counter baselines would drift from the
/// popover's and print numbers that disagree with it.
final class DashboardMetricsService: ObservableObject {
  @Published private(set) var snapshot = DashboardSnapshot()
  @Published private(set) var section: DashboardSection?

  @Published private(set) var diskReadHistory: MetricHistory
  @Published private(set) var diskWriteHistory: MetricHistory
  @Published private(set) var downloadHistory: MetricHistory
  @Published private(set) var uploadHistory: MetricHistory
  @Published private(set) var gpuHistory: MetricHistory
  /// Keyed by fan index, so a Mac with two fans charts them separately.
  @Published private(set) var fanHistory: [Int: MetricHistory] = [:]

  private let refreshInterval: TimeInterval
  private let processLimit: Int
  private let historyCapacity: Int
  private let sensorReader: SystemSensorReading
  /// Long enough for every core to accumulate a tick, short enough not to be felt.
  private static let primingInterval: TimeInterval = 0.25
  private let queue = DispatchQueue(
    label: "com.tagzxia.app.menucue.dashboard-metrics",
    qos: .userInitiated
  )

  private var timer: Timer?
  private var cancellable: AnyCancellable?
  /// Discards a slow probe that lands after the tab has already changed.
  private var generation: UInt64 = 0
  private var isProbeInFlight = false
  private var needsReload = false

  // Baselines for the readings this service owns. Touched only on `queue`.
  private var previousCoreTicks: [CPUTicks] = []
  private var previousDiskIO: DiskIOCounters?
  private var previousDiskIOTimestamp: TimeInterval?
  private var previousInterfaceCounters: [String: (input: UInt64, output: UInt64)] = [:]
  private var previousInterfaceTimestamp: TimeInterval?
  private var coreTopology: [CoreCluster] = []

  init(
    refreshInterval: TimeInterval = 2,
    processLimit: Int = 10,
    historyCapacity: Int = 120,
    sensorReader: SystemSensorReading = SystemSensorReader()
  ) {
    self.refreshInterval = refreshInterval
    self.processLimit = max(1, processLimit)
    self.historyCapacity = max(1, historyCapacity)
    self.sensorReader = sensorReader
    self.diskReadHistory = MetricHistory(capacity: historyCapacity)
    self.diskWriteHistory = MetricHistory(capacity: historyCapacity)
    self.downloadHistory = MetricHistory(capacity: historyCapacity)
    self.uploadHistory = MetricHistory(capacity: historyCapacity)
    self.gpuHistory = MetricHistory(capacity: historyCapacity)
  }

  deinit {
    timer?.invalidate()
  }

  // MARK: - Lifecycle

  /// Mirrors the shared sampler into this service's rate histories.
  ///
  /// Histories fill for every section, not just the visible one, so switching to
  /// Storage or Network shows a populated chart instead of an empty box. Appending to
  /// a ring buffer is free — the gating exists for probes, not for arithmetic.
  func attach(to metrics: SystemMetricsService) {
    cancellable = metrics.$snapshot
      .receive(on: DispatchQueue.main)
      .sink { [weak self] snapshot in
        self?.record(snapshot)
      }
  }

  func activate(_ section: DashboardSection) {
    guard section != self.section else { return }
    self.section = section
    generation &+= 1

    timer?.invalidate()
    load(section, generation: generation)

    let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
      guard let self, let section = self.section else { return }
      self.load(section, generation: self.generation)
    }
    // .common keeps the tab live while a menu or scroll gesture is tracking.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func deactivate() {
    // A stale baseline would make the next visit's first sample span the whole time
    // the tab was hidden, which reads as a flat 100% or 0%.
    previousCoreTicks = []
    section = nil
    generation &+= 1
    timer?.invalidate()
    timer = nil
    cancellable = nil
  }

  // MARK: - History

  private func record(_ metrics: SystemMetricsSnapshot) {
    // Before the first pair of counter reads the rates are not meaningful, and
    // charting the placeholder zeros would draw a dip that never happened.
    guard metrics.isPrimed else { return }

    diskReadHistory.append(metrics.disk.readBytesPerSecond)
    diskWriteHistory.append(metrics.disk.writeBytesPerSecond)
    downloadHistory.append(metrics.network.downloadBytesPerSecond)
    uploadHistory.append(metrics.network.uploadBytesPerSecond)

    for fan in metrics.fans {
      var history = fanHistory[fan.index] ?? MetricHistory(capacity: historyCapacity)
      history.append(fan.currentRPM)
      fanHistory[fan.index] = history
    }
  }

  // MARK: - Probes

  private func load(_ section: DashboardSection, generation: UInt64) {
    guard !isProbeInFlight else {
      needsReload = true
      return
    }
    isProbeInFlight = true

    let probes = section.probes
    let processLimit = self.processLimit

    queue.async { [weak self] in
      guard let self else { return }
      var result = DashboardResult()

      if probes.contains(.perCore) {
        // Per-core load is a difference, so the very first pass has no baseline and
        // would leave the card empty until the next tick — long enough that opening
        // the CPU tab looks broken. Priming here costs one short sleep, once.
        if self.previousCoreTicks.isEmpty {
          self.previousCoreTicks = DashboardProbe.perCoreTicks()
          Thread.sleep(forTimeInterval: Self.primingInterval)
        }

        let ticks = DashboardProbe.perCoreTicks()
        if self.coreTopology.count != ticks.count {
          self.coreTopology = DashboardProbe.coreTopology(coreCount: ticks.count)
        }
        if let loads = DashboardProbe.perCoreLoad(from: self.previousCoreTicks, to: ticks) {
          result.perCoreLoad = loads.enumerated().map { index, sample in
            CoreLoad(
              index: index,
              busy: sample.busy,
              cluster: index < self.coreTopology.count ? self.coreTopology[index] : .unspecified
            )
          }
        }
        self.previousCoreTicks = ticks
      }

      if probes.contains(.loadAverage) { result.loadAverage = DashboardProbe.loadAverage() }
      if probes.contains(.thermals) { result.thermals = self.sensorReader.readThermalBreakdown() }
      if probes.contains(.gpu) { result.gpu = SystemDetailProbe.gpuStats() }
      if probes.contains(.processes) {
        result.topProcesses = SystemDetailProbe.topMemoryProcesses(limit: processLimit)
      }
      if probes.contains(.swap) { result.swap = DashboardProbe.swapUsage() }
      if probes.contains(.memoryPressure) { result.pressure = DashboardProbe.memoryPressure() }
      if probes.contains(.volumes) { result.volumes = DashboardProbe.mountedVolumes() }
      if probes.contains(.diskOperations) { result.diskIO = self.readDiskIORates() }
      if probes.contains(.interfaces) {
        result.interfaces = self.withInterfaceRates(DashboardProbe.networkInterfaces())
      }

      DispatchQueue.main.async {
        self.complete(result, probes: probes, generation: generation)
      }
    }
  }

  /// Called on `queue`; owns the interface baseline.
  ///
  /// The per-interface octet counters are 32-bit and wrap every 4.29 GB, so only the
  /// difference between two reads is meaningful. A wrap makes `current < previous`,
  /// which `DashboardProbe.rate` reports as zero for that one sample rather than as a
  /// four-gigabyte spike.
  private func withInterfaceRates(_ interfaces: [NetworkInterfaceInfo])
    -> [NetworkInterfaceInfo]
  {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = previousInterfaceTimestamp.map { now - $0 } ?? 0

    let updated = interfaces.map { interface -> NetworkInterfaceInfo in
      var interface = interface
      if let previous = previousInterfaceCounters[interface.name], elapsed > 0 {
        interface.downloadBytesPerSecond = DashboardProbe.rate(
          from: previous.input, to: interface.counterIn, elapsed: elapsed)
        interface.uploadBytesPerSecond = DashboardProbe.rate(
          from: previous.output, to: interface.counterOut, elapsed: elapsed)
      }
      return interface
    }

    previousInterfaceCounters = Dictionary(
      uniqueKeysWithValues: interfaces.map { ($0.name, (input: $0.counterIn, output: $0.counterOut)) }
    )
    previousInterfaceTimestamp = now
    return updated
  }

  /// Called on `queue`; owns the disk baseline so two samples cannot race on it.
  private func readDiskIORates() -> DiskIORates? {
    guard let counters = DashboardProbe.diskIOCounters() else { return nil }
    let now = ProcessInfo.processInfo.systemUptime
    defer {
      previousDiskIO = counters
      previousDiskIOTimestamp = now
    }

    var rates = DiskIORates(
      totalBytesRead: counters.readBytes,
      totalBytesWritten: counters.writeBytes
    )
    guard let previous = previousDiskIO, let last = previousDiskIOTimestamp else { return rates }

    let elapsed = now - last
    rates.readOperationsPerSecond = DashboardProbe.rate(
      from: previous.readOperations, to: counters.readOperations, elapsed: elapsed)
    rates.writeOperationsPerSecond = DashboardProbe.rate(
      from: previous.writeOperations, to: counters.writeOperations, elapsed: elapsed)
    return rates
  }

  private func complete(
    _ result: DashboardResult,
    probes: Set<DashboardProbeKind>,
    generation: UInt64
  ) {
    isProbeInFlight = false
    defer {
      if needsReload, let section {
        needsReload = false
        load(section, generation: self.generation)
      }
    }
    guard generation == self.generation else { return }

    // Only the readings this pass asked for are replaced; the rest keep their last
    // known value so switching tabs does not blank a card that is still valid.
    var next = snapshot
    if probes.contains(.perCore), !result.perCoreLoad.isEmpty { next.perCoreLoad = result.perCoreLoad }
    if probes.contains(.loadAverage) { next.loadAverage = result.loadAverage }
    if probes.contains(.thermals) { next.thermals = result.thermals }
    if probes.contains(.gpu) { next.gpu = result.gpu }
    if probes.contains(.processes) { next.topProcesses = result.topProcesses }
    if probes.contains(.swap) { next.swap = result.swap }
    if probes.contains(.memoryPressure) { next.memoryPressure = result.pressure }
    if probes.contains(.volumes) { next.volumes = result.volumes }
    if probes.contains(.diskOperations) { next.diskIO = result.diskIO }
    if probes.contains(.interfaces) { next.interfaces = result.interfaces }
    snapshot = next

    if let utilization = result.gpu.deviceUtilization {
      gpuHistory.append(utilization)
    }
  }
}

/// Probe output before it is folded into the published snapshot.
private struct DashboardResult {
  var perCoreLoad: [CoreLoad] = []
  var loadAverage: LoadAverage?
  var thermals: [ThermalReading] = []
  var gpu = GPUStats()
  var topProcesses: [ProcessMemoryEntry] = []
  var swap: SwapUsage?
  var pressure: MemoryPressureLevel?
  var volumes: [VolumeUsage] = []
  var diskIO: DiskIORates?
  var interfaces: [NetworkInterfaceInfo] = []
}
