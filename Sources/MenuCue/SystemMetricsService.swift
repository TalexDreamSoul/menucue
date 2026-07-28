import Combine
import Foundation

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
  @Published private(set) var snapshot = SystemMetricsSnapshot()
  @Published private(set) var cpuHistory: [CPULoadSample] = []
  @Published private(set) var powerSource: PowerSourceState = .unknown
  @Published private(set) var currentInterval: TimeInterval

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

  private var samplingSettings: MetricsSamplingSettings
  private let sensorTickInterval: Int
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
  private var followUpNeedsSensors = false
  private var lastSuccessfulSampleDate: Date?

  // Accessed only from queue. Keeping the baseline here serializes samples and
  // prevents multiple jobs from calculating against the same counters.
  private var workerGeneration: UInt64 = 0
  private var workerPreviousCounters: CumulativeCounters?
  private var workerLastFans: [FanReading] = []
  private var workerLastTemperature: Double?

  init(
    sampleInterval: TimeInterval? = nil,
    samplingSettings: MetricsSamplingSettings = .default,
    historyCapacity: Int = SystemMetricsService.historyCapacity,
    sensorTickInterval: Int = 2,
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
    self.sensorTickInterval = max(1, sensorTickInterval)
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
      self.snapshot = cache.snapshot
      self.cpuHistory = Array(cache.cpuHistory.suffix(self.historyCapacity))
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
    sample(includeSensors: true)
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
    followUpNeedsSensors = false
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
    powerSource = powerSourceProvider()
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
    sample(includeSensors: tickCount % sensorTickInterval == 0)
  }

  private func sample(includeSensors: Bool) {
    guard activationCount > 0 else { return }
    if isSampleInFlight {
      needsFollowUpSample = true
      followUpNeedsSensors = followUpNeedsSensors || includeSensors
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
      }
      let output = self.performSample(includeSensors: includeSensors)
      DispatchQueue.main.async { [weak self] in
        self?.finishSample(output, generation: session, token: token)
      }
    }
  }

  private func performSample(includeSensors: Bool) -> SampleOutput {
    let previous = workerPreviousCounters
    let counters = countersProvider()
    let elapsed = previous.map { counters.timestamp - $0.timestamp } ?? 0

    var result = SystemMetricsSnapshot()
    result.memory = memoryProvider()

    let capacity = diskCapacityProvider()
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

    if includeSensors {
      let fans = sensorReader.readFans()
      if !fans.isEmpty || workerLastFans.isEmpty {
        workerLastFans = fans
      }
      if let temperature = sensorReader.readCPUTemperature() {
        workerLastTemperature = temperature
      }
    }
    result.fans = workerLastFans
    result.cpuTemperature = workerLastTemperature
    workerPreviousCounters = counters
    return SampleOutput(snapshot: result, cpuSample: cpuSample)
  }

  private func finishSample(
    _ output: SampleOutput?,
    generation session: UInt64,
    token: MetricsSamplingSession
  ) {
    isSampleInFlight = false

    if let output,
      activationCount > 0,
      generation == session,
      !token.isCancelled
    {
      if output.snapshot.isPrimed {
        snapshot = output.snapshot
        if let cpuSample = output.cpuSample {
          appendHistory(cpuSample)
        }
      } else {
        var carried = output.snapshot
        carried.cpu = snapshot.cpu
        carried.disk.readBytesPerSecond = snapshot.disk.readBytesPerSecond
        carried.disk.writeBytesPerSecond = snapshot.disk.writeBytesPerSecond
        carried.network.downloadBytesPerSecond = snapshot.network.downloadBytesPerSecond
        carried.network.uploadBytesPerSecond = snapshot.network.uploadBytesPerSecond
        snapshot = carried
      }
      lastSuccessfulSampleDate = Date()
    }

    let shouldFollowUp = needsFollowUpSample && activationCount > 0
    let includeSensors = followUpNeedsSensors
    needsFollowUpSample = false
    followUpNeedsSensors = false
    if shouldFollowUp {
      sample(includeSensors: includeSensors)
    }
  }

  private func appendHistory(_ sample: CPULoadSample) {
    cpuHistory.append(sample)
    if cpuHistory.count > historyCapacity {
      cpuHistory.removeFirst(cpuHistory.count - historyCapacity)
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
