import Foundation

struct AlertMetricRequest: Codable, Hashable, Sendable {
  let metricID: AlertMetricID
  let targetID: String?

  init(metricID: AlertMetricID, targetID: String? = nil) {
    self.metricID = metricID
    self.targetID = targetID
  }
}

protocol AlertMetricProviding: Sendable {
  var kind: AlertMetricProviderKind { get }
  func sample(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) async -> [AlertMetricObservation]
  func resetBaselines() async
}

struct AlertMetricProviderDependencies: @unchecked Sendable {
  var cumulativeCounters: () -> CumulativeCounters = SystemMetricsProbe.cumulativeCounters
  var memoryUsage: () -> MemoryUsage = SystemMetricsProbe.memoryUsage
  var perCoreTicks: () -> [CPUTicks] = DashboardProbe.perCoreTicks
  var loadAverage: () -> LoadAverage? = DashboardProbe.loadAverage
  var gpuStats: () -> GPUStats = SystemDetailProbe.gpuStats
  var swapUsage: () -> SwapUsage? = DashboardProbe.swapUsage
  var memoryPressure: () -> MemoryPressureLevel? = DashboardProbe.memoryPressure
  var volumes: () -> [VolumeUsage] = DashboardProbe.mountedVolumes
  var diskIO: () -> DiskIOCounters? = DashboardProbe.diskIOCounters
  var interfaces: () -> [NetworkInterfaceInfo] = DashboardProbe.networkInterfaces
  var thermalReadings: () -> [ThermalReading]
  var cpuTemperature: () -> Double?
  var fans: () -> [FanReading]
  var batteryStatus: () -> BatteryStatus?

  init(
    sensorReader: SystemSensorReading = SystemSensorReader(),
    powerProbe: PowerDiagnosticsProbing = SystemPowerDiagnosticsProbe()
  ) {
    self.thermalReadings = sensorReader.readThermalBreakdown
    self.cpuTemperature = sensorReader.readCPUTemperature
    self.fans = sensorReader.readFans
    self.batteryStatus = { try? powerProbe.batteryStatus() }
  }
}

actor SystemAlertMetricProvider: AlertMetricProviding {
  nonisolated let kind: AlertMetricProviderKind

  private let dependencies: AlertMetricProviderDependencies
  private var previousCounters: CumulativeCounters?
  private var previousCoreTicks: [CPUTicks]?
  private var previousDiskIO: DiskIOCounters?
  private var previousDiskDate: Date?
  private var previousInterfaces: [String: (input: UInt64, output: UInt64)] = [:]
  private var previousInterfaceDate: Date?

  init(
    kind: AlertMetricProviderKind,
    dependencies: AlertMetricProviderDependencies = AlertMetricProviderDependencies()
  ) {
    self.kind = kind
    self.dependencies = dependencies
  }

  func sample(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) async -> [AlertMetricObservation] {
    guard !requests.isEmpty else { return [] }
    let values: [AlertMetricRequest: AlertMetricObservation]
    switch kind {
    case .system:
      values = sampleSystem(requests: requests, at: date)
    case .cpuDetail:
      values = sampleCPUDetail(requests: requests, at: date)
    case .gpu:
      values = sampleGPU(requests: requests, at: date)
    case .memoryDetail:
      values = sampleMemoryDetail(requests: requests, at: date)
    case .storageDetail:
      values = sampleStorage(requests: requests, at: date)
    case .networkDetail:
      values = sampleNetwork(requests: requests, at: date)
    case .thermal:
      values = sampleThermals(requests: requests, at: date)
    case .battery:
      values = sampleBattery(requests: requests, at: date)
    case .darkWake:
      values = [:]
    }

    return requests.map { request in
      values[request]
        ?? .unavailable(
          metricID: request.metricID,
          targetID: request.targetID,
          sampledAt: date
        )
    }
  }

  func resetBaselines() async {
    previousCounters = nil
    previousCoreTicks = nil
    previousDiskIO = nil
    previousDiskDate = nil
    previousInterfaces = [:]
    previousInterfaceDate = nil
  }

  private func sampleSystem(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    let counters = dependencies.cumulativeCounters()
    let memory = dependencies.memoryUsage()
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]

    if let previousCounters,
      let previousTicks = previousCounters.cpuTicks,
      let currentTicks = counters.cpuTicks,
      let cpu = SystemMetricsProbe.cpuLoad(from: previousTicks, to: currentTicks)
    {
      add(.number(cpu.busy), id: "cpu.total.busy", requests: requests, date: date, to: &result)
      add(.number(cpu.userBand), id: "cpu.total.user", requests: requests, date: date, to: &result)
      add(
        .number(cpu.systemBand), id: "cpu.total.system", requests: requests, date: date,
        to: &result)
      add(.number(cpu.idle), id: "cpu.total.idle", requests: requests, date: date, to: &result)
    }

    add(
      .number(Double(memory.used)), id: "memory.used", requests: requests, date: date, to: &result)
    add(
      .number(memory.fraction), id: "memory.used.percent", requests: requests, date: date,
      to: &result)
    add(
      .number(Double(memory.appMemory)), id: "memory.app", requests: requests, date: date,
      to: &result)
    add(
      .number(Double(memory.wired)), id: "memory.wired", requests: requests, date: date,
      to: &result)
    add(
      .number(Double(memory.compressed)), id: "memory.compressed", requests: requests,
      date: date, to: &result)
    add(
      .number(Double(memory.cached)), id: "memory.cached", requests: requests, date: date,
      to: &result)

    if let previousCounters {
      let elapsed = counters.timestamp - previousCounters.timestamp
      if elapsed > 0 {
        addRate(
          from: previousCounters.diskReadBytes, to: counters.diskReadBytes, elapsed: elapsed,
          id: "disk.read.rate", requests: requests, date: date, result: &result)
        addRate(
          from: previousCounters.diskWriteBytes, to: counters.diskWriteBytes, elapsed: elapsed,
          id: "disk.write.rate", requests: requests, date: date, result: &result)
        if previousCounters.networkInterfaceName == counters.networkInterfaceName {
          let context = counters.networkInterfaceName.map { ["source.identity": $0] } ?? [:]
          addRate(
            from: previousCounters.networkInBytes, to: counters.networkInBytes, elapsed: elapsed,
            id: "network.download.rate", requests: requests, date: date, context: context,
            result: &result)
          addRate(
            from: previousCounters.networkOutBytes, to: counters.networkOutBytes,
            elapsed: elapsed, id: "network.upload.rate", requests: requests, date: date,
            context: context, result: &result)
        }
      }
    }
    previousCounters = counters
    return result
  }

  private func sampleCPUDetail(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    let ticks = dependencies.perCoreTicks()
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]
    if let previousCoreTicks,
      let loads = DashboardProbe.perCoreLoad(from: previousCoreTicks, to: ticks)
    {
      for (index, load) in loads.enumerated() {
        add(
          .number(load.busy), id: "cpu.core.busy", targetID: String(index),
          requests: requests, date: date, to: &result)
      }
    }
    previousCoreTicks = ticks

    if let load = dependencies.loadAverage() {
      add(.number(load.one), id: "cpu.load.1m", requests: requests, date: date, to: &result)
      add(.number(load.five), id: "cpu.load.5m", requests: requests, date: date, to: &result)
      add(
        .number(load.fifteen), id: "cpu.load.15m", requests: requests, date: date,
        to: &result)
    }
    return result
  }

  private func sampleGPU(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    let gpu = dependencies.gpuStats()
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]
    if let value = gpu.deviceUtilization {
      add(
        .number(value), id: "gpu.device.utilization", requests: requests, date: date,
        to: &result)
    }
    if let value = gpu.rendererUtilization {
      add(
        .number(value), id: "gpu.renderer.utilization", requests: requests, date: date,
        to: &result)
    }
    if let value = gpu.inUseMemory {
      add(
        .number(Double(value)), id: "gpu.memory.inUse", requests: requests, date: date,
        to: &result)
    }
    return result
  }

  private func sampleMemoryDetail(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]
    if let swap = dependencies.swapUsage() {
      add(
        .number(Double(swap.used)), id: "swap.used", requests: requests, date: date,
        to: &result)
      add(
        .number(swap.fraction), id: "swap.used.percent", requests: requests, date: date,
        to: &result)
    }
    if let pressure = dependencies.memoryPressure() {
      let severity: Int
      switch pressure {
      case .normal: severity = 1
      case .warning: severity = 2
      case .critical: severity = 3
      }
      add(
        .severity(severity), id: "memory.pressure", requests: requests, date: date,
        to: &result)
    }
    return result
  }

  private func sampleStorage(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]
    for volume in dependencies.volumes() {
      add(
        .number(Double(volume.used)), id: "storage.volume.used", targetID: volume.path,
        requests: requests, date: date, to: &result)
      add(
        .number(Double(volume.free)), id: "storage.volume.free", targetID: volume.path,
        requests: requests, date: date, to: &result)
      add(
        .number(volume.fraction), id: "storage.volume.usedPercent", targetID: volume.path,
        requests: requests, date: date, to: &result)
    }

    if let counters = dependencies.diskIO() {
      defer {
        previousDiskIO = counters
        previousDiskDate = date
      }
      if let previousDiskIO, let previousDiskDate {
        let elapsed = date.timeIntervalSince(previousDiskDate)
        if elapsed > 0,
          counters.readOperations >= previousDiskIO.readOperations,
          counters.writeOperations >= previousDiskIO.writeOperations
        {
          add(
            .number(
              Double(counters.readOperations - previousDiskIO.readOperations) / elapsed),
            id: "disk.read.operations", requests: requests, date: date, to: &result)
          add(
            .number(
              Double(counters.writeOperations - previousDiskIO.writeOperations) / elapsed),
            id: "disk.write.operations", requests: requests, date: date, to: &result)
        }
      }
    }
    return result
  }

  private func sampleNetwork(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    let interfaces = dependencies.interfaces()
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]
    let elapsed = previousInterfaceDate.map { date.timeIntervalSince($0) } ?? 0
    if elapsed > 0 {
      for interface in interfaces {
        guard let previous = previousInterfaces[interface.name],
          interface.counterIn >= previous.input,
          interface.counterOut >= previous.output
        else { continue }
        add(
          .number(Double(interface.counterIn - previous.input) / elapsed),
          id: "network.interface.downloadRate", targetID: interface.name,
          requests: requests, date: date, to: &result)
        add(
          .number(Double(interface.counterOut - previous.output) / elapsed),
          id: "network.interface.uploadRate", targetID: interface.name,
          requests: requests, date: date, to: &result)
      }
    }
    previousInterfaces = Dictionary(
      uniqueKeysWithValues: interfaces.map {
        ($0.name, (input: $0.counterIn, output: $0.counterOut))
      })
    previousInterfaceDate = date
    return result
  }

  private func sampleThermals(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]
    if let value = dependencies.cpuTemperature() {
      add(
        .number(value), id: "sensor.cpu.temperature", requests: requests, date: date,
        to: &result)
    }
    for reading in dependencies.thermalReadings() {
      add(
        .number(reading.celsius), id: "sensor.thermal.temperature", targetID: reading.sensorID,
        requests: requests, date: date, context: ["target.name": reading.label], to: &result)
    }
    for fan in dependencies.fans() {
      add(
        .number(fan.currentRPM), id: "fan.speed", targetID: String(fan.index),
        requests: requests, date: date, to: &result)
      add(
        .number(fan.loadFraction), id: "fan.load", targetID: String(fan.index),
        requests: requests, date: date, to: &result)
    }
    return result
  }

  private func sampleBattery(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) -> [AlertMetricRequest: AlertMetricObservation] {
    guard let battery = dependencies.batteryStatus() else { return [:] }
    var result: [AlertMetricRequest: AlertMetricObservation] = [:]
    add(
      .number(Double(battery.percentage) / 100), id: "battery.level", requests: requests,
      date: date, to: &result)
    if let value = battery.flow?.watts {
      add(
        .number(value), id: "battery.flow.watts", requests: requests, date: date,
        to: &result)
    }
    if let value = battery.flow?.percentPerHour {
      add(
        .number(value), id: "battery.flow.percentPerHour", requests: requests, date: date,
        to: &result)
    }
    if let value = battery.isCharging {
      add(
        .boolean(value), id: "battery.charging", requests: requests, date: date,
        to: &result)
    }
    if let value = battery.isOnAC {
      add(.boolean(value), id: "power.onAC", requests: requests, date: date, to: &result)
    }
    return result
  }

  private func addRate(
    from previous: UInt64?,
    to current: UInt64?,
    elapsed: TimeInterval,
    id: AlertMetricID,
    requests: Set<AlertMetricRequest>,
    date: Date,
    context: [String: String] = [:],
    result: inout [AlertMetricRequest: AlertMetricObservation]
  ) {
    guard let previous, let current, current >= previous else { return }
    add(
      .number(Double(current - previous) / elapsed), id: id, requests: requests, date: date,
      context: context, to: &result)
  }

  private func add(
    _ value: AlertMetricValue,
    id: AlertMetricID,
    targetID: String? = nil,
    requests: Set<AlertMetricRequest>,
    date: Date,
    context: [String: String] = [:],
    to result: inout [AlertMetricRequest: AlertMetricObservation]
  ) {
    let request = AlertMetricRequest(metricID: id, targetID: targetID)
    guard requests.contains(request) else { return }
    result[request] = .value(
      metricID: id,
      targetID: targetID,
      value: value,
      sampledAt: date,
      context: context
    )
  }
}

enum AlertMetricFormatter {
  static func string(
    for value: AlertMetricValue,
    definition: AlertMetricDefinition?
  ) -> String {
    switch value {
    case .number(let number):
      switch definition?.unit {
      case .fraction:
        return "\(Int((number * 100).rounded()))%"
      case .bytes:
        return SystemMetricsFormatter.capacity(UInt64(max(0, number)))
      case .bytesPerSecond:
        return SystemMetricsFormatter.rate(number)
      case .celsius:
        return SystemMetricsFormatter.temperature(number)
      case .rpm:
        return "\(Int(number.rounded())) RPM"
      case .watts:
        return String(format: "%.1f W", number)
      case .percentPerHour:
        return String(format: "%.1f%%/h", number)
      case .operationsPerSecond:
        return String(format: "%.1f ops/s", number)
      case .load:
        return String(format: "%.2f", number)
      case .some(.none), nil:
        return String(format: "%.2f", number)
      }
    case .severity(let severity):
      return String(severity)
    case .boolean(let value):
      return value ? "true" : "false"
    case .event:
      return ""
    }
  }
}
