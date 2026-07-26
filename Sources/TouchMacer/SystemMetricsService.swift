import Combine
import Foundation

/// Polls system metrics only while the Status tab is visible.
final class SystemMetricsService: ObservableObject {
  @Published private(set) var snapshot = SystemMetricsSnapshot()
  @Published private(set) var cpuHistory: [CPULoadSample] = []

  let hardware: SystemHardwareInfo
  let bootDate: Date?

  static let historyCapacity = 48
  private static let primingDelay: TimeInterval = 0.3

  private let sampleInterval: TimeInterval
  private let sensorTickInterval: Int
  private let queue = DispatchQueue(label: "com.touchmacer.system-metrics", qos: .utility)
  private let sensorReader: SystemSensorReading
  private let countersProvider: () -> CumulativeCounters
  private let memoryProvider: () -> MemoryUsage
  private let diskCapacityProvider: () -> (name: String, used: UInt64, total: UInt64)

  // Main-thread lifecycle state.
  private var timer: Timer?
  private var activationCount = 0
  private var tickCount = 0
  private var generation: UInt64 = 0

  // Accessed only from queue. Keeping the baseline here serializes samples and
  // prevents multiple queued jobs from calculating against the same counters.
  private var workerGeneration: UInt64 = 0
  private var workerPreviousCounters: CumulativeCounters?
  private var workerLastFans: [FanReading] = []
  private var workerLastTemperature: Double?

  init(
    sampleInterval: TimeInterval = 1.5,
    sensorTickInterval: Int = 2,
    sensorReader: SystemSensorReading = SystemSensorReader(),
    countersProvider: @escaping () -> CumulativeCounters = SystemMetricsProbe.cumulativeCounters,
    memoryProvider: @escaping () -> MemoryUsage = SystemMetricsProbe.memoryUsage,
    diskCapacityProvider: @escaping () -> (name: String, used: UInt64, total: UInt64) =
      SystemMetricsProbe.diskCapacity
  ) {
    self.sampleInterval = sampleInterval
    self.sensorTickInterval = max(1, sensorTickInterval)
    self.sensorReader = sensorReader
    self.countersProvider = countersProvider
    self.memoryProvider = memoryProvider
    self.diskCapacityProvider = diskCapacityProvider
    self.hardware = SystemMetricsProbe.hardwareInfo()
    self.bootDate = SystemMetricsProbe.bootDate()
  }

  deinit {
    timer?.invalidate()
  }

  func retain() {
    activationCount += 1
    guard activationCount == 1 else { return }

    generation &+= 1
    tickCount = 0
    let session = generation
    queue.async { [weak self] in
      guard let self else { return }
      self.workerGeneration = session
      self.workerPreviousCounters = nil
      self.performSample(includeSensors: true, generation: session)
    }

    let timer = Timer(
      fire: Date().addingTimeInterval(Self.primingDelay),
      interval: sampleInterval,
      repeats: true
    ) { [weak self] _ in
      self?.tick()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func release() {
    activationCount = max(0, activationCount - 1)
    guard activationCount == 0 else { return }

    timer?.invalidate()
    timer = nil
    generation &+= 1
    let invalidatedGeneration = generation
    queue.async { [weak self] in
      guard let self else { return }
      self.workerGeneration = invalidatedGeneration
      self.workerPreviousCounters = nil
    }
  }

  private func tick() {
    tickCount += 1
    sample(includeSensors: tickCount % sensorTickInterval == 0)
  }

  private func sample(includeSensors: Bool) {
    let session = generation
    queue.async { [weak self] in
      self?.performSample(includeSensors: includeSensors, generation: session)
    }
  }

  private func performSample(includeSensors: Bool, generation session: UInt64) {
    guard workerGeneration == session else { return }

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

    DispatchQueue.main.async { [weak self] in
      guard let self,
        self.activationCount > 0,
        self.generation == session
      else { return }

      if result.isPrimed {
        self.snapshot = result
        if let cpuSample {
          self.appendHistory(cpuSample)
        }
      } else {
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

  private func appendHistory(_ sample: CPULoadSample) {
    cpuHistory.append(sample)
    if cpuHistory.count > Self.historyCapacity {
      cpuHistory.removeFirst(cpuHistory.count - Self.historyCapacity)
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
}
