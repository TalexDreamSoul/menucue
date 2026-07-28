import Darwin
import Foundation
import IOKit

protocol SystemSensorReading: AnyObject {
  func readFans() -> [FanReading]
  func readCPUTemperature() -> Double?
  func readThermalBreakdown() -> [ThermalReading]
}

extension SystemSensorReading {
  func readThermalBreakdown() -> [ThermalReading] { [] }
}

/// Fan speeds and die temperatures, which macOS exposes only through undocumented interfaces.
///
/// Two back ends are used because neither covers every Mac:
/// * `AppleSMC` reports fan tachometers on all Macs and CPU temperature on Intel.
/// * `IOHIDEventSystemClient` reports the per-cluster thermal sensors on Apple silicon,
///   where the classic SMC temperature keys are absent.
///
/// Both are best-effort. Any failure degrades to `nil`/empty so the Status tab simply
/// hides the affected card instead of reporting a wrong number.
final class SystemSensorReader: SystemSensorReading {
  private let smc = SMCConnection()
  private lazy var thermalSensors = HIDThermalSensorClient()

  /// Reading the SMC is a synchronous IOKit round trip; keep it off the main thread.
  func readFans() -> [FanReading] {
    guard let count = smc.readValue(key: "FNum").map({ Int($0) }), count > 0 else { return [] }

    return (0..<min(count, 8)).compactMap { index in
      guard let current = smc.readValue(key: "F\(index)Ac") else { return nil }
      let minimum = smc.readValue(key: "F\(index)Mn") ?? 0
      let maximum = smc.readValue(key: "F\(index)Mx") ?? 0
      return FanReading(
        index: index,
        currentRPM: current.rounded(),
        minRPM: minimum.rounded(),
        maxRPM: maximum.rounded()
      )
    }
  }

  func readCPUTemperature() -> Double? {
    if let temperature = thermalSensors.cpuTemperature() {
      return temperature
    }
    // Intel Macs expose the die and proximity sensors as ordinary SMC keys.
    for key in ["TC0D", "TC0P", "TC0E", "TC0F", "TCAD"] {
      if let value = smc.readValue(key: key), (1...125).contains(value) {
        return value
      }
    }
    return nil
  }

  /// Returns every available thermal cluster for the CPU detail panel.
  func readThermalBreakdown() -> [ThermalReading] {
    let hidReadings = thermalSensors.clusterTemperatures()
    guard hidReadings.isEmpty else { return hidReadings }

    let intelKeys: [(key: String, label: String, kind: ThermalSensorKind)] = [
      ("TC0D", L10n.string("CPU die"), .die),
      ("TC0P", L10n.string("CPU proximity"), .other),
      ("TG0D", L10n.string("GPU die"), .gpu),
      ("TA0P", L10n.string("Ambient"), .other),
      ("TM0P", L10n.string("Memory"), .other),
    ]
    return intelKeys.compactMap { entry in
      guard let value = smc.readValue(key: entry.key), (1...125).contains(value) else { return nil }
      return ThermalReading(label: entry.label, celsius: value, kind: entry.kind)
    }
  }
}

// MARK: - AppleSMC

/// Minimal read-only AppleSMC client.
///
/// The request/response struct must match the kernel's `SMCKeyData_t` byte for byte.
/// Swift lays a nested struct out using its *size* rather than its stride, so
/// `padding` below stands in for the tail padding C would insert after `keyInfo`.
private final class SMCConnection {
  private var connection: io_connect_t = 0
  private let lock = NSLock()
  private var lastOpenAttempt: Date?

  deinit {
    if connection != 0 {
      IOServiceClose(connection)
    }
  }

  func readValue(key: String) -> Double? {
    lock.lock()
    defer { lock.unlock() }

    guard openIfNeeded() else { return nil }
    guard let keyCode = SMCConnection.fourCharCode(key) else { return nil }

    // Step 1: ask the SMC how wide this key is and how it is encoded.
    var input = SMCKeyData()
    input.key = keyCode
    input.data8 = SMCConnection.commandReadKeyInfo

    guard let info = call(input) else { return nil }
    guard info.keyInfo.dataSize > 0, info.keyInfo.dataSize <= 32 else { return nil }

    // Step 2: read that many bytes and decode them per the reported type.
    input.keyInfo = info.keyInfo
    input.data8 = SMCConnection.commandReadBytes

    guard let output = call(input) else { return nil }
    return SMCConnection.decode(
      bytes: output.bytes,
      size: Int(info.keyInfo.dataSize),
      type: info.keyInfo.dataType
    )
  }

  private func openIfNeeded() -> Bool {
    if connection != 0 { return true }
    if let lastOpenAttempt, Date().timeIntervalSince(lastOpenAttempt) < 30 {
      return false
    }
    lastOpenAttempt = Date()

    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }

    var handle: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, 0, &handle) == kIOReturnSuccess else {
      return false
    }
    connection = handle
    return true
  }

  private func call(_ input: SMCKeyData) -> SMCKeyData? {
    var request = input
    var response = SMCKeyData()
    var responseSize = MemoryLayout<SMCKeyData>.stride

    let result = IOConnectCallStructMethod(
      connection,
      SMCConnection.selectorHandleYPCEvent,
      &request,
      MemoryLayout<SMCKeyData>.stride,
      &response,
      &responseSize
    )

    guard result == kIOReturnSuccess, response.result == 0 else { return nil }
    return response
  }

  // MARK: Decoding

  private static func decode(bytes: SMCBytes, size: Int, type: UInt32) -> Double? {
    let buffer = withUnsafeBytes(of: bytes) { Array($0.prefix(size)) }
    guard buffer.count == size else { return nil }

    switch type {
    case DataType.float where size == 4:
      // SMC floats are stored little-endian regardless of the reported key order.
      let raw =
        UInt32(buffer[3]) << 24 | UInt32(buffer[2]) << 16 | UInt32(buffer[1]) << 8
        | UInt32(buffer[0])
      return Double(Float(bitPattern: raw))

    case DataType.fpe2 where size == 2:
      // 14 integer bits followed by 2 fractional bits.
      return Double(UInt16(buffer[0]) << 8 | UInt16(buffer[1])) / 4

    case DataType.sp78 where size == 2:
      return Double(Int8(bitPattern: buffer[0])) + Double(buffer[1]) / 256

    case DataType.uint8 where size >= 1:
      return Double(buffer[0])

    case DataType.uint16 where size == 2:
      return Double(UInt16(buffer[0]) << 8 | UInt16(buffer[1]))

    case DataType.uint32 where size == 4:
      return Double(
        UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8
          | UInt32(buffer[3]))

    default:
      return nil
    }
  }

  private static func fourCharCode(_ string: String) -> UInt32? {
    let scalars = Array(string.unicodeScalars)
    guard scalars.count == 4, scalars.allSatisfy({ $0.value <= 0xFF }) else { return nil }
    return scalars.reduce(UInt32(0)) { partial, scalar in
      partial << 8 | UInt32(scalar.value)
    }
  }

  private enum DataType {
    static let float = SMCConnection.fourCharCode("flt ")!
    static let fpe2 = SMCConnection.fourCharCode("fpe2")!
    static let sp78 = SMCConnection.fourCharCode("sp78")!
    static let uint8 = SMCConnection.fourCharCode("ui8 ")!
    static let uint16 = SMCConnection.fourCharCode("ui16")!
    static let uint32 = SMCConnection.fourCharCode("ui32")!
  }

  private static let commandReadBytes: UInt8 = 5
  private static let commandReadKeyInfo: UInt8 = 9
  private static let selectorHandleYPCEvent: UInt32 = 2
}

private typealias SMCBytes = (
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
  var major: UInt8 = 0
  var minor: UInt8 = 0
  var build: UInt8 = 0
  var reserved: UInt8 = 0
  var release: UInt16 = 0
}

private struct SMCPowerLimitData {
  var version: UInt16 = 0
  var length: UInt16 = 0
  var cpuPowerLimit: UInt32 = 0
  var gpuPowerLimit: UInt32 = 0
  var memPowerLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
  var dataSize: UInt32 = 0
  var dataType: UInt32 = 0
  var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
  var key: UInt32 = 0
  var vers = SMCVersion()
  var pLimitData = SMCPowerLimitData()
  var keyInfo = SMCKeyInfoData()
  /// Reproduces the tail padding C adds after `keyInfo`; do not remove.
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
  )
}

// MARK: - IOHIDEventSystemClient

/// Reads Apple silicon thermal sensors through IOKit's private HID event system.
///
/// The symbols exist in IOKit but are not declared in any public header, so they are
/// resolved with `dlsym` — a missing symbol then disables the reader instead of
/// breaking the link.
private final class HIDThermalSensorClient {
  private struct Sensor {
    let name: String
    let service: AnyObject
  }

  private let lock = NSLock()
  private var sensors: [Sensor] = []
  private var client: AnyObject?
  private var retryAfter: Date?

  private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
  private typealias SetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Int32
  private typealias CopyServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
  private typealias CopyProperty = @convention(c) (AnyObject?, CFString) -> Unmanaged<AnyObject>?
  private typealias CopyEvent = @convention(c) (AnyObject?, Int64, Int32, Int64) ->
    Unmanaged<AnyObject>?
  private typealias EventFloatValue = @convention(c) (AnyObject?, Int32) -> Double

  private static let temperatureEventType: Int64 = 15
  private static let temperatureFieldBase = Int32(15 << 16)

  private static let handle: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  private static let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
  private static let eventFloatValue = symbol("IOHIDEventGetFloatValue", as: EventFloatValue.self)

  /// Sensor names differ per chip generation; the first group that yields readings wins.
  private static let sensorGroups: [[String]] = [
    ["pACC MTR Temp Sensor", "eACC MTR Temp Sensor"],
    ["PMU tdie", "PMU tdev"],
    ["SOC MTR Temp Sensor"],
  ]

  func cpuTemperature() -> Double? {
    lock.lock()
    defer { lock.unlock() }

    if let retryAfter, Date() < retryAfter { return nil }
    if sensors.isEmpty {
      discoverSensors()
      if sensors.isEmpty {
        scheduleRetry()
        return nil
      }
    }

    guard let copyEvent = Self.copyEvent, let eventFloatValue = Self.eventFloatValue else {
      scheduleRetry()
      return nil
    }

    for group in Self.sensorGroups {
      let matching = sensors.filter { sensor in
        group.contains { sensor.name.hasPrefix($0) }
      }
      guard !matching.isEmpty else { continue }

      let readings = matching.compactMap { sensor -> Double? in
        guard
          let event = copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?
            .takeRetainedValue()
        else { return nil }
        let value = eventFloatValue(event, Self.temperatureFieldBase)
        // Disconnected sensors report 0 or absurd values; ignore them.
        return (1...125).contains(value) ? value : nil
      }
      guard !readings.isEmpty else { continue }

      // The hottest cluster is what a user means by "CPU temperature".
      retryAfter = nil
      return readings.max()
    }

    return nil
  }

  /// Averages each known cluster prefix into one labelled reading.
  func clusterTemperatures() -> [ThermalReading] {
    lock.lock()
    defer { lock.unlock() }

    if let retryAfter, Date() < retryAfter { return [] }
    if sensors.isEmpty {
      discoverSensors()
      if sensors.isEmpty {
        scheduleRetry()
        return []
      }
    }
    guard let copyEvent = Self.copyEvent, let eventFloatValue = Self.eventFloatValue else {
      scheduleRetry()
      return []
    }

    func read(_ sensor: Sensor) -> Double? {
      guard
        let event = copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue()
      else { return nil }
      let value = eventFloatValue(event, Self.temperatureFieldBase)
      return (1...125).contains(value) ? value : nil
    }

    let readings = Self.clusterLabels.compactMap { cluster -> ThermalReading? in
      let values = sensors
        .filter { $0.name.hasPrefix(cluster.prefix) }
        .compactMap { read($0) }
      guard !values.isEmpty else { return nil }
      return ThermalReading(
        label: L10n.string(cluster.label),
        celsius: values.reduce(0, +) / Double(values.count),
        kind: cluster.kind
      )
    }
    if !readings.isEmpty { retryAfter = nil }
    return readings
  }

  private static let clusterLabels: [(prefix: String, label: String, kind: ThermalSensorKind)] = [
    ("pACC MTR Temp Sensor", "P-cluster", .performanceCluster),
    ("eACC MTR Temp Sensor", "E-cluster", .efficiencyCluster),
    ("GPU MTR Temp Sensor", "GPU", .gpu),
    ("SOC MTR Temp Sensor", "SoC", .soc),
    ("PMU tdie", "Die", .die),
    ("PMU tdev", "Device", .device),
    ("ANE MTR Temp Sensor", "Neural Engine", .neuralEngine),
  ]

  private func scheduleRetry() {
    sensors.removeAll()
    client = nil
    retryAfter = Date().addingTimeInterval(60)
  }

  private func discoverSensors() {
    guard
      let create = Self.symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
      let setMatching = Self.symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
      let copyServices = Self.symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
      let copyProperty = Self.symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self)
    else { return }

    guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
    self.client = client

    // kHIDPage_AppleVendor / kHIDUsage_AppleVendor_TemperatureSensor
    let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005]
    _ = setMatching(client, matching as CFDictionary)

    guard let services = copyServices(client)?.takeRetainedValue() else { return }

    for index in 0..<CFArrayGetCount(services) {
      guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
      let service = unsafeBitCast(raw, to: AnyObject.self)
      guard
        let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
      else { continue }
      sensors.append(Sensor(name: name, service: service))
    }
  }
}
