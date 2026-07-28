import Darwin
import Foundation
import IOKit

/// Raw counters that only become a rate once compared against the previous read.
struct CumulativeCounters: Equatable {
  var timestamp: TimeInterval = 0
  var cpuTicks = CPUTicks()
  var diskReadBytes: UInt64 = 0
  var diskWriteBytes: UInt64 = 0
  var networkInBytes: UInt64 = 0
  var networkOutBytes: UInt64 = 0
}

struct CPUTicks: Equatable {
  var user: UInt64 = 0
  var system: UInt64 = 0
  var idle: UInt64 = 0
  var nice: UInt64 = 0

  var total: UInt64 {
    user &+ system &+ idle &+ nice
  }
}

/// Reads system counters through public Darwin, sysctl, and IOKit interfaces.
///
/// Every method is safe to call off the main thread and never traps: an
/// unavailable counter degrades to a zero value rather than failing the sample.
enum SystemMetricsProbe {

  // MARK: - Static hardware facts

  static func hardwareInfo() -> SystemHardwareInfo {
    var info = SystemHardwareInfo()
    info.chipName =
      sysctlString("machdep.cpu.brand_string")
      ?? sysctlString("hw.model")
      ?? "Mac"
    info.physicalCores = Int(sysctlInteger("hw.physicalcpu") ?? 0)
    info.logicalCores = Int(sysctlInteger("hw.logicalcpu") ?? 0)
    // perflevel0 is the performance cluster on Apple silicon; both are absent on Intel.
    info.performanceCores = Int(sysctlInteger("hw.perflevel0.physicalcpu") ?? 0)
    info.efficiencyCores = Int(sysctlInteger("hw.perflevel1.physicalcpu") ?? 0)
    return info
  }

  static func bootDate() -> Date? {
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    var boottime = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctl(&mib, u_int(mib.count), &boottime, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec))
  }

  // MARK: - Counters

  static func cumulativeCounters() -> CumulativeCounters {
    var counters = CumulativeCounters()
    counters.timestamp = ProcessInfo.processInfo.systemUptime
    counters.cpuTicks = cpuTicks()

    let disk = diskThroughputCounters()
    counters.diskReadBytes = disk.read
    counters.diskWriteBytes = disk.write

    let network = networkThroughputCounters()
    counters.networkInBytes = network.input
    counters.networkOutBytes = network.output

    return counters
  }

  static func cpuTicks() -> CPUTicks {
    var size = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    var loadInfo = host_cpu_load_info_data_t()

    let result = withUnsafeMutablePointer(to: &loadInfo) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPointer in
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &size)
      }
    }
    guard result == KERN_SUCCESS else { return CPUTicks() }

    return CPUTicks(
      user: UInt64(loadInfo.cpu_ticks.0),
      system: UInt64(loadInfo.cpu_ticks.1),
      idle: UInt64(loadInfo.cpu_ticks.2),
      nice: UInt64(loadInfo.cpu_ticks.3)
    )
  }

  static func cpuLoad(from previous: CPUTicks, to current: CPUTicks) -> CPULoadSample? {
    let userDelta = current.user &- previous.user
    let systemDelta = current.system &- previous.system
    let idleDelta = current.idle &- previous.idle
    let niceDelta = current.nice &- previous.nice
    let totalDelta = userDelta &+ systemDelta &+ idleDelta &+ niceDelta

    // A zero or wrapped delta means the counters are not comparable yet.
    guard totalDelta > 0, current.total >= previous.total else { return nil }

    let total = Double(totalDelta)
    return CPULoadSample(
      user: Double(userDelta) / total,
      system: Double(systemDelta) / total,
      nice: Double(niceDelta) / total,
      idle: Double(idleDelta) / total
    )
  }

  // MARK: - Memory

  static func memoryUsage() -> MemoryUsage {
    var usage = MemoryUsage()
    usage.total = sysctlInteger("hw.memsize") ?? 0

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return usage }

    let pageSize = UInt64(vm_kernel_page_size)
    // Mirrors Activity Monitor: app memory excludes pages that can be reclaimed on demand.
    let internalPages = UInt64(stats.internal_page_count)
    let purgeablePages = UInt64(stats.purgeable_count)
    usage.appMemory = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
    usage.wired = UInt64(stats.wire_count) * pageSize
    usage.compressed = UInt64(stats.compressor_page_count) * pageSize
    usage.cached = UInt64(stats.external_page_count) * pageSize
    return usage
  }

  // MARK: - Disk

  static func diskCapacity() -> (name: String, used: UInt64, total: UInt64) {
    let url = URL(fileURLWithPath: "/")
    let keys: Set<URLResourceKey> = [
      .volumeNameKey,
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ]

    guard let values = try? url.resourceValues(forKeys: keys) else {
      return ("Macintosh HD", 0, 0)
    }

    let name = values.volumeName ?? "Macintosh HD"
    let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
    // Important-usage capacity matches what Finder reports as available.
    let available = UInt64(
      max(
        0,
        values.volumeAvailableCapacityForImportantUsage
          ?? Int64(values.volumeAvailableCapacity ?? 0)))
    let used = total > available ? total - available : 0
    return (name, used, total)
  }

  private static func diskThroughputCounters() -> (read: UInt64, write: UInt64) {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
    else {
      return (0, 0)
    }
    defer { IOObjectRelease(iterator) }

    var read: UInt64 = 0
    var write: UInt64 = 0

    // Key names come from IOBlockStorageDriver.h, which IOKit does not expose to Swift.
    while case let drive = IOIteratorNext(iterator), drive != 0 {
      defer { IOObjectRelease(drive) }

      var properties: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(drive, &properties, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let dictionary = properties?.takeRetainedValue() as? [String: Any],
        let statistics = dictionary["Statistics"] as? [String: Any]
      else {
        continue
      }

      read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
      write &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
    }

    return (read, write)
  }

  // MARK: - Network

  private static func networkThroughputCounters() -> (input: UInt64, output: UInt64) {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
    defer { freeifaddrs(addresses) }

    var input: UInt64 = 0
    var output: UInt64 = 0

    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = pointer.pointee
      guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
      guard let name = interface.ifa_name.map({ String(cString: $0) }) else { continue }
      guard isCountableInterface(name, flags: interface.ifa_flags) else { continue }
      guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }

      input &+= UInt64(data.pointee.ifi_ibytes)
      output &+= UInt64(data.pointee.ifi_obytes)
    }

    return (input, output)
  }

  static func primaryIPv4() -> (interface: String, address: String)? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }

    var candidates: [(interface: String, address: String)] = []

    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = pointer.pointee
      guard let socketAddress = interface.ifa_addr,
        socketAddress.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      guard let name = interface.ifa_name.map({ String(cString: $0) }) else { continue }
      guard isCountableInterface(name, flags: interface.ifa_flags) else { continue }

      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          socketAddress,
          socklen_t(socketAddress.pointee.sa_len),
          &host,
          socklen_t(host.count),
          nil,
          0,
          NI_NUMERICHOST
        ) == 0
      else { continue }

      candidates.append((name, String(cString: host)))
    }

    // Physical interfaces first: en0 is Wi-Fi or Ethernet on every shipping Mac.
    return candidates.min { lhs, rhs in
      interfaceRank(lhs.interface) < interfaceRank(rhs.interface)
    }
  }

  private static func isCountableInterface(_ name: String, flags: UInt32) -> Bool {
    guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { return false }
    // awdl/llw carry AirDrop chatter and bridge/utun would double-count tunneled traffic.
    let excludedPrefixes = ["awdl", "llw", "bridge", "utun", "ipsec", "gif", "stf", "ap"]
    return !excludedPrefixes.contains { name.hasPrefix($0) }
  }

  private static func interfaceRank(_ name: String) -> Int {
    if name.hasPrefix("en") { return 0 }
    if name.hasPrefix("bond") { return 1 }
    return 2
  }

  // MARK: - sysctl helpers

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private static func sysctlInteger(_ name: String) -> UInt64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }

    switch size {
    case MemoryLayout<UInt32>.size:
      var value: UInt32 = 0
      guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
      return UInt64(value)
    case MemoryLayout<UInt64>.size:
      var value: UInt64 = 0
      guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
      return value
    default:
      return nil
    }
  }
}
