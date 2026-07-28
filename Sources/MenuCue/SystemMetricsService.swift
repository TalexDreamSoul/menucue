import Combine
import Foundation

/// Polls system metrics while the Status tab is visible and publishes them as one snapshot.
///
/// Sampling is refcounted through `retain()`/`release()` so nothing runs when the popover
/// is closed. Cheap counters refresh every tick; SMC and HID sensors are an order of
/// magnitude slower, so they refresh every few ticks on a background queue.
final class SystemMetricsService: ObservableObject {
  @Published private(set) var snapshot = SystemMetricsSnapshot()
  /// Newest sample last; drives the CPU area chart.
  @Published private(set) var cpuHistory: [CPULoadSample] = []
  /// Surfaced so the settings pane can show what the adaptive policy settled on.
  @Published private(set) var powerSource: PowerSourceState = .unknown
  @Published private(set) var currentInterval: TimeInterval = 1.5

  let hardware: SystemHardwareInfo
  /// Read once at launch; the footer derives uptime from it without polling.
  let bootDate: Date?

  static let historyCapacity = 48

  /// Sampling only runs while the popover is open, so a cold start would otherwise
  /// show an empty chart and zeroed cards for the first couple of seconds.
  static let cacheKey = "com.tagzxia.app.menucue.systemMetricsCache"
  /// Past this, restored rates would be stale enough to mislead, so start clean.
  static let cacheMaxAge: TimeInterval = 300

  /// Reading the power source is an IOKit round trip, so it is refreshed every few
  /// ticks rather than on every sample.
  private static let powerTickInterval = 4

  private var samplingSettings: MetricsSamplingSettings
  private let lowPowerModeProvider: () -> Bool
  private let powerSourceProvider: () -> PowerSourceState
  private let sensorTickInterval: Int
  private let queue = DispatchQueue(label: "com.tagzxia.app.menucue.system-metrics", qos: .utility)
  private let sensorReader = SystemSensorReader()
  private let defaults: UserDefaults

  private var timer: Timer?
  private var activationCount = 0
  private var tickCount = 0
  private var previousCounters: CumulativeCounters?
  private var lastFans: [FanReading] = []
  private var lastTemperature: Double?

  init(
    samplingSettings: MetricsSamplingSettings = .default,
    sensorTickInterval: Int = 2,
    defaults: UserDefaults = .standard,
    now: Date = Date(),
    powerSourceProvider: @escaping () -> PowerSourceState = PowerSourceReader.current,
    lowPowerModeProvider: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
  ) {
    self.samplingSettings = samplingSettings.normalized
    self.sensorTickInterval = max(1, sensorTickInterval)
    self.defaults = defaults
    self.powerSourceProvider = powerSourceProvider
    self.lowPowerModeProvider = lowPowerModeProvider
    self.hardware = SystemMetricsProbe.hardwareInfo()
    self.bootDate = SystemMetricsProbe.bootDate()
    self.currentInterval = samplingSettings.normalized.fastestIntervalSeconds

    if let cache = Self.loadCache(from: defaults, now: now) {
      self.snapshot = cache.snapshot
      self.cpuHistory = cache.cpuHistory
    }
  }

  /// Called when the user edits the sampling preferences. Reschedules immediately so
  /// a change is visible without closing and reopening the popover.
  func applySamplingSettings(_ settings: MetricsSamplingSettings) {
    let normalized = settings.normalized
    guard normalized != samplingSettings else { return }
    samplingSettings = normalized
    guard activationCount > 0 else {
      currentInterval = resolvedInterval()
      return
    }
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

  /// Rebuilding the timer on every tick would reset its phase, so only do it when the
  /// target interval has actually moved.
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
    // .common keeps sampling alive while a menu or scroll gesture is tracking.
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  deinit {
    timer?.invalidate()
  }

  // MARK: - Cache

  struct Cache: Codable {
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
      now.timeIntervalSince(cache.savedAt) < maxAge,
      // A clock roll-back would otherwise make any cache look fresh forever.
      now >= cache.savedAt
    else { return nil }
    return cache
  }

  private func persistCache(at date: Date = Date()) {
    let cache = Cache(savedAt: date, snapshot: snapshot, cpuHistory: cpuHistory)
    guard let data = try? JSONEncoder().encode(cache) else { return }
    defaults.set(data, forKey: Self.cacheKey)
  }

  // MARK: - Lifecycle

  func retain() {
    activationCount += 1
    guard activationCount == 1 else { return }

    refreshPowerSource()
    currentInterval = resolvedInterval()
    // The first read only establishes a baseline — rates need a second one, so
    // schedule it well inside a second rather than a full interval later.
    sample(includeSensors: true)
    timer = makeTimer(
      interval: currentInterval,
      firstFire: Date().addingTimeInterval(Self.primingDelay)
    )
  }

  private static let primingDelay: TimeInterval = 0.3

  func release() {
    activationCount = max(0, activationCount - 1)
    guard activationCount == 0 else { return }
    timer?.invalidate()
    timer = nil
    // Counters are only meaningful against a recent baseline; start fresh next time.
    previousCounters = nil
    persistCache()
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
    let previous = previousCounters

    queue.async { [weak self] in
      guard let self else { return }

      let counters = SystemMetricsProbe.cumulativeCounters()
      let elapsed = previous.map { counters.timestamp - $0.timestamp } ?? 0

      var result = SystemMetricsSnapshot()
      result.memory = SystemMetricsProbe.memoryUsage()

      let capacity = SystemMetricsProbe.diskCapacity()
      result.disk.volumeName = capacity.name
      result.disk.used = capacity.used
      result.disk.total = capacity.total

      if let address = SystemMetricsProbe.primaryIPv4() {
        result.network.interfaceName = address.interface
        result.network.ipv4Address = address.address
      }

      if let previous, elapsed > 0 {
        result.cpu =
          SystemMetricsProbe.cpuLoad(from: previous.cpuTicks, to: counters.cpuTicks) ?? CPULoadSample()
        result.disk.readBytesPerSecond = Self.rate(
          from: previous.diskReadBytes, to: counters.diskReadBytes, elapsed: elapsed)
        result.disk.writeBytesPerSecond = Self.rate(
          from: previous.diskWriteBytes, to: counters.diskWriteBytes, elapsed: elapsed)
        result.network.downloadBytesPerSecond = Self.rate(
          from: previous.networkInBytes, to: counters.networkInBytes, elapsed: elapsed)
        result.network.uploadBytesPerSecond = Self.rate(
          from: previous.networkOutBytes, to: counters.networkOutBytes, elapsed: elapsed)
        result.isPrimed = true
      }

      let fans: [FanReading]
      let temperature: Double?
      if includeSensors {
        fans = self.sensorReader.readFans()
        temperature = self.sensorReader.readCPUTemperature()
      } else {
        fans = self.lastFans
        temperature = self.lastTemperature
      }
      result.fans = fans
      result.cpuTemperature = temperature

      DispatchQueue.main.async {
        self.lastFans = fans
        self.lastTemperature = temperature
        self.previousCounters = counters

        if result.isPrimed {
          self.snapshot = result
          self.appendHistory(result.cpu)
        } else {
          // A baseline read has no rates. Keep the last known ones rather than
          // flashing zeros over them when the popover is reopened.
          var carried = result
          carried.cpu = self.snapshot.cpu
          carried.disk.readBytesPerSecond = self.snapshot.disk.readBytesPerSecond
          carried.disk.writeBytesPerSecond = self.snapshot.disk.writeBytesPerSecond
          carried.network.downloadBytesPerSecond = self.snapshot.network.downloadBytesPerSecond
          carried.network.uploadBytesPerSecond = self.snapshot.network.uploadBytesPerSecond
          self.snapshot = carried
        }
      }
    }
  }

  private func appendHistory(_ sample: CPULoadSample) {
    cpuHistory.append(sample)
    if cpuHistory.count > Self.historyCapacity {
      cpuHistory.removeFirst(cpuHistory.count - Self.historyCapacity)
    }
  }

  /// Converts two cumulative counters into a per-second rate, tolerating 32-bit wraparound.
  private static func rate(from previous: UInt64, to current: UInt64, elapsed: TimeInterval)
    -> Double
  {
    guard elapsed > 0, current >= previous else { return 0 }
    return Double(current - previous) / elapsed
  }
}
