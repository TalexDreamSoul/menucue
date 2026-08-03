import Combine
import Foundation
import OSLog

struct SystemMetricsDisplayFrame: Equatable {
  var snapshot = SystemMetricsSnapshot()
  var cpuHistory: [CPULoadSample] = []
}

private final class MetricsSamplingSession {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

/// Polls system metrics only while the Status tab is visible.
final class SystemMetricsService: ObservableObject {
  @Published private(set) var frame = SystemMetricsDisplayFrame()
  @Published private(set) var powerSource: PowerSourceState = .unknown
  @Published private(set) var currentInterval: TimeInterval

  var snapshot: SystemMetricsSnapshot { frame.snapshot }
  var cpuHistory: [CPULoadSample] { frame.cpuHistory }

  let hardware: SystemHardwareInfo
  let bootDate: Date?

  /// Default window length, sized for the 360pt popover chart. The Dashboard chart is
  /// several times wider and asks for a denser series through `init(historyCapacity:)`.
  static let historyCapacity = 48
  /// This instance's window length. Prefer it over the static in view code.
  let historyCapacity: Int
  static let cacheKey = "com.tagzxia.app.menucue.systemMetricsCache"
  static let cacheMaxAge: TimeInterval = 300

  private static let primingDelay: TimeInterval = 0.3
  private static let powerTickInterval = 4
  private static let signposter = OSSignposter(
    subsystem: "com.tagzxia.app.menucue",
    category: "SystemMetrics"
  )

  private var samplingSettings: MetricsSamplingSettings
  private let sensorRefreshInterval: TimeInterval
  private let diskCapacityRefreshInterval: TimeInterval
  private let monotonicNow: () -> TimeInterval
  private let queue = DispatchQueue(
    label: "com.tagzxia.app.menucue.system-metrics",
    qos: .utility
  )
  private let sensorReader: SystemSensorReading
  private let countersProvider: () -> CumulativeCounters
  private let memoryProvider: () -> MemoryUsage
  private let diskCapacityProvider: () -> (name: String, used: UInt64, total: UInt64)
  private let powerSourceProvider: () -> PowerSourceState
  private let lowPowerModeProvider: () -> Bool
  private let defaults: UserDefaults

  // Main-thread lifecycle state.
  private var timer: Timer?
  private var activationCount = 0
  private var tickCount = 0
  private var generation: UInt64 = 0
  private var sessionToken = MetricsSamplingSession()
  private var isSampleInFlight = false
  private var needsFollowUpSample = false
  private var lastSuccessfulSampleDate: Date?

  // Accessed only from queue. Keeping baselines and slow-changing caches here
  // serializes samples without adding locks to the hot path.
  private var workerGeneration: UInt64 = 0
  private var workerPreviousCounters: CumulativeCounters?
  private var workerLastFans: [FanReading] = []
  private var workerLastTemperature: Double?
  private var workerLastSensorRefresh: TimeInterval?
  private var workerDiskCapacity: (name: String, used: UInt64, total: UInt64)?
  private var workerLastDiskCapacityRefresh: TimeInterval?

  init(
    sampleInterval: TimeInterval? = nil,
    samplingSettings: MetricsSamplingSettings = .default,
    historyCapacity: Int = SystemMetricsService.historyCapacity,
    sensorRefreshInterval: TimeInterval = 10,
    diskCapacityRefreshInterval: TimeInterval = 60,
    monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    defaults: UserDefaults = .standard,
    now: Date = Date(),
    sensorReader: SystemSensorReading = SystemSensorReader(),
    countersProvider: @escaping () -> CumulativeCounters = SystemMetricsProbe.cumulativeCounters,
    memoryProvider: @escaping () -> MemoryUsage = SystemMetricsProbe.memoryUsage,
    diskCapacityProvider: @escaping () -> (name: String, used: UInt64, total: UInt64) =
      SystemMetricsProbe.diskCapacity,
    powerSourceProvider: @escaping () -> PowerSourceState = PowerSourceReader.current,
    lowPowerModeProvider: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
  ) {
    var resolvedSettings = samplingSettings.normalized
    if let sampleInterval {
      let interval = MetricsSamplingSettings.intervalRange.clamp(sampleInterval)
      resolvedSettings.isAdaptive = false
      resolvedSettings.fastestIntervalSeconds = interval
      resolvedSettings.slowestIntervalSeconds = interval
    }

    self.samplingSettings = resolvedSettings
    self.historyCapacity = max(1, historyCapacity)
    self.sensorRefreshInterval = max(0, sensorRefreshInterval)
    self.diskCapacityRefreshInterval = max(0, diskCapacityRefreshInterval)
    self.monotonicNow = monotonicNow
    self.defaults = defaults
    self.sensorReader = sensorReader
    self.countersProvider = countersProvider
    self.memoryProvider = memoryProvider
    self.diskCapacityProvider = diskCapacityProvider
    self.powerSourceProvider = powerSourceProvider
    self.lowPowerModeProvider = lowPowerModeProvider
    self.hardware = SystemMetricsProbe.hardwareInfo()
    self.bootDate = SystemMetricsProbe.bootDate()
    self.currentInterval = resolvedSettings.fastestIntervalSeconds

    if let cache = Self.loadCache(from: defaults, now: now) {
      self.frame = SystemMetricsDisplayFrame(
        snapshot: cache.snapshot,
        cpuHistory: Array(cache.cpuHistory.suffix(self.historyCapacity))
      )
      self.lastSuccessfulSampleDate = cache.savedAt
    }
  }

  deinit {
    timer?.invalidate()
    sessionToken.cancel()
  }

  // MARK: - Cache

  struct Cache: Codable, Equatable {
    var savedAt: Date
    var snapshot: SystemMetricsSnapshot
    var cpuHistory: [CPULoadSample]
  }

  static func loadCache(
    from defaults: UserDefaults,
    now: Date = Date(),
    maxAge: TimeInterval = cacheMaxAge
  ) -> Cache? {
    guard let data = defaults.data(forKey: cacheKey),
      let cache = try? JSONDecoder().decode(Cache.self, from: data),
      now >= cache.savedAt,
      now.timeIntervalSince(cache.savedAt) < maxAge
    else { return nil }
    return cache
  }

  private func persistCache() {
    guard let savedAt = lastSuccessfulSampleDate else { return }
    let cache = Cache(savedAt: savedAt, snapshot: snapshot, cpuHistory: cpuHistory)
    guard let data = try? JSONEncoder().encode(cache) else { return }
    defaults.set(data, forKey: Self.cacheKey)
  }

  // MARK: - Lifecycle

  func retain() {
    activationCount += 1
    guard activationCount == 1 else { return }

    refreshPowerSource()
    currentInterval = resolvedInterval()
    sessionToken.cancel()
    sessionToken = MetricsSamplingSession()
    generation &+= 1
    tickCount = 0
    sample()
    timer = makeTimer(
      interval: currentInterval,
      firstFire: Date().addingTimeInterval(Self.primingDelay)
    )
  }

  func release() {
    guard activationCount > 0 else { return }
    activationCount -= 1
    guard activationCount == 0 else { return }

    timer?.invalidate()
    timer = nil
    sessionToken.cancel()
    generation &+= 1
    needsFollowUpSample = false
    persistCache()
  }

  func applySamplingSettings(_ settings: MetricsSamplingSettings) {
    let normalized = settings.normalized
    guard normalized != samplingSettings else { return }
    samplingSettings = normalized
    rescheduleIfIntervalChanged(force: true)
  }

  private func resolvedInterval() -> TimeInterval {
    AdaptiveSamplingPolicy.interval(
      for: powerSource,
      isLowPowerMode: lowPowerModeProvider(),
      settings: samplingSettings
    )
  }

  private func refreshPowerSource() {
    let next = powerSourceProvider()
    if next != powerSource {
      powerSource = next
    }
  }

  private func rescheduleIfIntervalChanged(force: Bool = false) {
    let target = resolvedInterval()
    guard force || abs(target - currentInterval) > 0.05 else { return }
    currentInterval = target
    guard activationCount > 0 else { return }
    timer?.invalidate()
    timer = makeTimer(interval: target, firstFire: Date().addingTimeInterval(target))
  }

  private func makeTimer(interval: TimeInterval, firstFire: Date) -> Timer {
    let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] _ in
      self?.tick()
    }
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  // MARK: - Sampling

  private func tick() {
    tickCount += 1
    if tickCount % Self.powerTickInterval == 0 {
      refreshPowerSource()
      rescheduleIfIntervalChanged()
    }
    sample()
  }

  private func sample() {
    guard activationCount > 0 else { return }
    if isSampleInFlight {
      needsFollowUpSample = true
      return
    }

    isSampleInFlight = true
    let session = generation
    let token = sessionToken
    queue.async { [weak self] in
      guard let self else { return }
      guard !token.isCancelled else {
        DispatchQueue.main.async { [weak self] in
          self?.finishSample(nil, generation: session, token: token)
        }
        return
      }

      if self.workerGeneration != session {
        self.workerGeneration = session
        self.workerPreviousCounters = nil
        self.workerLastSensorRefresh = nil
      }
      let interval = Self.signposter.beginInterval("Utility sample")
      let output = self.performSample()
      Self.signposter.endInterval("Utility sample", interval)
      DispatchQueue.main.async { [weak self] in
        self?.finishSample(output, generation: session, token: token)
      }
    }
  }

  private func performSample() -> SampleOutput {
    let previous = workerPreviousCounters
    let counters = countersProvider()
    let elapsed = previous.map { counters.timestamp - $0.timestamp } ?? 0
    let monotonicTime = monotonicNow()

    var result = SystemMetricsSnapshot()
    result.memory = memoryProvider()

    let capacity = diskCapacity(at: monotonicTime)
    result.disk.volumeName = capacity.name
    result.disk.used = capacity.used
    result.disk.total = capacity.total
    result.network.interfaceName = counters.networkInterfaceName
    result.network.ipv4Address = counters.networkIPv4Address

    var cpuSample: CPULoadSample?
    if let previous, elapsed > 0 {
      if let previousTicks = previous.cpuTicks, let currentTicks = counters.cpuTicks {
        cpuSample = SystemMetricsProbe.cpuLoad(from: previousTicks, to: currentTicks)
        result.cpu = cpuSample ?? CPULoadSample()
      }
      result.disk.readBytesPerSecond = Self.rate(
        from: previous.diskReadBytes, to: counters.diskReadBytes, elapsed: elapsed)
      result.disk.writeBytesPerSecond = Self.rate(
        from: previous.diskWriteBytes, to: counters.diskWriteBytes, elapsed: elapsed)

      if previous.networkInterfaceName == counters.networkInterfaceName {
        result.network.downloadBytesPerSecond = Self.rate(
          from: previous.networkInBytes, to: counters.networkInBytes, elapsed: elapsed)
        result.network.uploadBytesPerSecond = Self.rate(
          from: previous.networkOutBytes, to: counters.networkOutBytes, elapsed: elapsed)
      }
      result.isPrimed = true
    }

    if shouldRefreshSensors(at: monotonicTime) {
      let fans = sensorReader.readFans()
      if !fans.isEmpty || workerLastFans.isEmpty {
        workerLastFans = fans
      }
      if let temperature = sensorReader.readCPUTemperature() {
        workerLastTemperature = temperature
      }
      workerLastSensorRefresh = monotonicTime
    }
    result.fans = workerLastFans
    result.cpuTemperature = workerLastTemperature
    workerPreviousCounters = counters
    return SampleOutput(snapshot: result, cpuSample: cpuSample)
  }

  private func diskCapacity(
    at monotonicTime: TimeInterval
  ) -> (name: String, used: UInt64, total: UInt64) {
    if let workerDiskCapacity,
      let lastRefresh = workerLastDiskCapacityRefresh,
      monotonicTime - lastRefresh < diskCapacityRefreshInterval
    {
      return workerDiskCapacity
    }
    let capacity = diskCapacityProvider()
    guard capacity.total > 0 else {
      // A transient volume-resource failure must not replace a valid reading or
      // postpone the next retry for the full cache interval.
      return workerDiskCapacity ?? capacity
    }
    workerDiskCapacity = capacity
    workerLastDiskCapacityRefresh = monotonicTime
    return capacity
  }

  private func shouldRefreshSensors(at monotonicTime: TimeInterval) -> Bool {
    guard let lastRefresh = workerLastSensorRefresh else { return true }
    return monotonicTime - lastRefresh >= sensorRefreshInterval
  }

  private func finishSample(
    _ output: SampleOutput?,
    generation session: UInt64,
    token: MetricsSamplingSession
  ) {
    let interval = Self.signposter.beginInterval("Main-thread commit")
    defer { Self.signposter.endInterval("Main-thread commit", interval) }
    isSampleInFlight = false

    if let output,
      activationCount > 0,
      generation == session,
      !token.isCancelled
    {
      var nextSnapshot = output.snapshot
      var nextHistory = frame.cpuHistory
      if output.snapshot.isPrimed {
        if let cpuSample = output.cpuSample {
          nextHistory.append(cpuSample)
          if nextHistory.count > historyCapacity {
            nextHistory.removeFirst(nextHistory.count - historyCapacity)
          }
        }
      } else {
        nextSnapshot.cpu = frame.snapshot.cpu
        nextSnapshot.disk.readBytesPerSecond = frame.snapshot.disk.readBytesPerSecond
        nextSnapshot.disk.writeBytesPerSecond = frame.snapshot.disk.writeBytesPerSecond
        nextSnapshot.network.downloadBytesPerSecond = frame.snapshot.network.downloadBytesPerSecond
        nextSnapshot.network.uploadBytesPerSecond = frame.snapshot.network.uploadBytesPerSecond
      }
      frame = SystemMetricsDisplayFrame(snapshot: nextSnapshot, cpuHistory: nextHistory)
      lastSuccessfulSampleDate = Date()
    }

    let shouldFollowUp = needsFollowUpSample && activationCount > 0
    needsFollowUpSample = false
    if shouldFollowUp {
      sample()
    }
  }

  private static func rate(
    from previous: UInt64?,
    to current: UInt64?,
    elapsed: TimeInterval
  ) -> Double {
    guard let previous, let current, elapsed > 0, current >= previous else { return 0 }
    return Double(current - previous) / elapsed
  }

  private struct SampleOutput {
    let snapshot: SystemMetricsSnapshot
    let cpuSample: CPULoadSample?
  }
}
