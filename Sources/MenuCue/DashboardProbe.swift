import Darwin
import Foundation
import IOKit

/// The readings the Dashboard needs on top of `SystemMetricsProbe`.
///
/// Same contract as the rest of the probe layer: safe off the main thread, never
/// traps, and an unavailable counter degrades to `nil`/empty rather than to a zero
/// that would read as a measurement.
enum DashboardProbe {

  // MARK: - Per-core load

  /// One entry per logical CPU. The array is freed with `vm_deallocate`; skipping
  /// that leaks on every sample, and this runs every couple of seconds while the
  /// CPU tab is open.
  static func perCoreTicks() -> [CPUTicks] {
    var coreCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0

    guard
      host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        == KERN_SUCCESS,
      let info
    else { return [] }

    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: info)),
        vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
      )
    }

    return (0..<Int(coreCount)).map { index in
      let base = index * Int(CPU_STATE_MAX)
      return CPUTicks(
        user: UInt64(info[base + Int(CPU_STATE_USER)]),
        system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
        idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
        nice: UInt64(info[base + Int(CPU_STATE_NICE)])
      )
    }
  }

  /// Element-wise delta. Returns `nil` when the two reads are not comparable —
  /// different core counts, or a counter that has not advanced.
  static func perCoreLoad(from previous: [CPUTicks], to current: [CPUTicks]) -> [CPULoadSample]? {
    guard !previous.isEmpty, previous.count == current.count else { return nil }

    var samples: [CPULoadSample] = []
    samples.reserveCapacity(current.count)
    for (previous, current) in zip(previous, current) {
      guard let sample = SystemMetricsProbe.cpuLoad(from: previous, to: current) else { return nil }
      samples.append(sample)
    }
    return samples
  }

  // MARK: - Core topology

  /// Cluster membership per logical CPU, read once because it cannot change.
  ///
  /// `IOPlatformDevice` publishes `cluster-type` ("E"/"P") alongside `logical-cpu-id`,
  /// which is authoritative. Where that is absent the `hw.perflevelN` counts are used:
  /// XNU numbers CPUs slowest-cluster-first, so perflevels are walked in reverse index
  /// order. If neither source covers exactly `coreCount` cores the result is all
  /// `.unspecified` — unlabelled is honest, mislabelled is not.
  static func coreTopology(coreCount: Int) -> [CoreCluster] {
    guard coreCount > 0 else { return [] }
    if let registry = registryCoreTopology(coreCount: coreCount) { return registry }
    if let perflevel = perflevelCoreTopology(coreCount: coreCount) { return perflevel }
    return Array(repeating: .unspecified, count: coreCount)
  }

  private static func registryCoreTopology(coreCount: Int) -> [CoreCluster]? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    var clusters = [CoreCluster](repeating: .unspecified, count: coreCount)
    var resolved = 0

    while case let device = IOIteratorNext(iterator), device != 0 {
      defer { IOObjectRelease(device) }

      var unmanaged: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(device, &unmanaged, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let properties = unmanaged?.takeRetainedValue() as? [String: Any],
        let rawType = properties["cluster-type"] as? Data,
        let identifier = (properties["logical-cpu-id"] as? NSNumber)?.intValue,
        identifier >= 0, identifier < coreCount
      else { continue }

      // The value is a CFData holding a single character plus a NUL terminator.
      switch rawType.first.map({ Character(UnicodeScalar($0)) }) {
      case "P": clusters[identifier] = .performance
      case "E": clusters[identifier] = .efficiency
      default: continue
      }
      resolved += 1
    }

    return resolved == coreCount ? clusters : nil
  }

  private static func perflevelCoreTopology(coreCount: Int) -> [CoreCluster]? {
    guard let levels = sysctlInteger("hw.nperflevels"), levels >= 2 else { return nil }

    var clusters: [CoreCluster] = []
    // Reverse order: hw.perflevel0 is the fastest cluster but owns the highest CPU ids.
    for level in stride(from: Int(levels) - 1, through: 0, by: -1) {
      guard let count = sysctlInteger("hw.perflevel\(level).logicalcpu") else { return nil }
      let cluster: CoreCluster = level == 0 ? .performance : .efficiency
      clusters.append(contentsOf: Array(repeating: cluster, count: Int(count)))
    }

    return clusters.count == coreCount ? clusters : nil
  }

  // MARK: - Load average

  static func loadAverage() -> LoadAverage? {
    var values = [Double](repeating: 0, count: 3)
    guard getloadavg(&values, 3) == 3 else { return nil }
    return LoadAverage(one: values[0], five: values[1], fifteen: values[2])
  }

  // MARK: - Swap & pressure

  static func swapUsage() -> SwapUsage? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
    return SwapUsage(
      used: usage.xsu_used,
      total: usage.xsu_total,
      isEncrypted: usage.xsu_encrypted != 0
    )
  }

  static func memoryPressure() -> MemoryPressureLevel? {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
      return nil
    }
    return MemoryPressureLevel.decode(level)
  }

  // MARK: - Volumes

  /// Every browsable mounted volume. Internal disks sort first; the rest keep their
  /// mount order so a list of external drives does not reshuffle between samples.
  static func mountedVolumes() -> [VolumeUsage] {
    let keys: [URLResourceKey] = [
      .volumeNameKey,
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
      .volumeLocalizedFormatDescriptionKey,
      .volumeIsInternalKey,
      .volumeIsBrowsableKey,
    ]

    guard
      let urls = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
    else { return [] }

    let volumes: [VolumeUsage] = urls.compactMap { url in
      guard
        let values = try? url.resourceValues(forKeys: Set(keys)),
        values.volumeIsBrowsable != false
      else { return nil }

      let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
      guard total > 0 else { return nil }

      // Important-usage capacity is what Finder reports as available.
      let available = UInt64(
        max(
          0,
          values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)))

      return VolumeUsage(
        path: url.path,
        name: values.volumeName ?? url.lastPathComponent,
        format: values.volumeLocalizedFormatDescription ?? L10n.string("Unknown"),
        used: total > available ? total - available : 0,
        total: total,
        isInternal: values.volumeIsInternal ?? false
      )
    }

    return volumes.enumerated()
      .sorted { lhs, rhs in
        if lhs.element.isInternal != rhs.element.isInternal { return lhs.element.isInternal }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  // MARK: - Disk operations

  /// Adds operation counts to the byte counters `SystemMetricsProbe` already reads,
  /// so the Storage tab can show IOPS as well as throughput.
  static func diskIOCounters() -> DiskIOCounters? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    var counters = DiskIOCounters()
    var foundDrive = false

    // Key names come from IOBlockStorageDriver.h, which IOKit does not expose to Swift.
    while case let drive = IOIteratorNext(iterator), drive != 0 {
      defer { IOObjectRelease(drive) }

      var unmanaged: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(drive, &unmanaged, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let properties = unmanaged?.takeRetainedValue() as? [String: Any],
        let statistics = properties["Statistics"] as? [String: Any]
      else { continue }

      foundDrive = true
      counters.readBytes &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
      counters.writeBytes &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
      counters.readOperations &+= (statistics["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
      counters.writeOperations &+= (statistics["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
    }

    return foundDrive ? counters : nil
  }

  /// Per-second rate from two cumulative reads, tolerating a counter reset.
  static func rate(from previous: UInt64, to current: UInt64, elapsed: TimeInterval) -> Double {
    guard elapsed > 0, current >= previous else { return 0 }
    return Double(current - previous) / elapsed
  }

  // MARK: - Interfaces

  /// Interfaces that are up, not loopback, and actually carrying something — either
  /// an IPv4 address or non-zero traffic. Without that last filter this Mac lists ten
  /// idle virtual `en*` devices from container runtimes.
  static func networkInterfaces() -> [NetworkInterfaceInfo] {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
    defer { freeifaddrs(addresses) }

    var order: [String] = []
    var macs: [String: String] = [:]
    var ipv4: [String: String] = [:]
    var traffic: [String: (input: UInt64, output: UInt64)] = [:]

    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = pointer.pointee
      guard let name = interface.ifa_name.map({ String(cString: $0) }) else { continue }
      guard isEligible(name, flags: interface.ifa_flags) else { continue }
      guard let family = interface.ifa_addr?.pointee.sa_family else { continue }

      if !order.contains(name) { order.append(name) }

      switch Int32(family) {
      case AF_LINK:
        // Wrapping 32-bit counters — kept only so the service can difference them.
        if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
          traffic[name] = (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
        }
        if let address = interface.ifa_addr {
          macs[name] = macAddress(from: address)
        }
      case AF_INET:
        if let address = interface.ifa_addr, ipv4[name] == nil {
          ipv4[name] = numericHost(from: address)
        }
      default:
        continue
      }
    }

    return order.compactMap { name in
      let bytes = traffic[name] ?? (0, 0)
      let info = NetworkInterfaceInfo(
        name: name,
        ipv4Address: ipv4[name],
        macAddress: macs[name],
        counterIn: bytes.input,
        counterOut: bytes.output
      )
      return info.isActive ? info : nil
    }
  }

  /// Mirrors `SystemMetricsProbe.isCountableInterface`, which is private to that type,
  /// and additionally drops `vmenet`. awdl/llw carry AirDrop chatter, bridge/utun would
  /// double-count tunneled traffic, and vmenet is VM plumbing — a container runtime puts
  /// six of them on this Mac, each with enough traffic to pass a naive "is it in use"
  /// test and bury the interface the user actually cares about.
  private static func isEligible(_ name: String, flags: UInt32) -> Bool {
    guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { return false }
    let excludedPrefixes = [
      "awdl", "llw", "bridge", "utun", "ipsec", "gif", "stf", "ap", "vmenet",
    ]
    return !excludedPrefixes.contains { name.hasPrefix($0) }
  }

  private static func macAddress(from address: UnsafeMutablePointer<sockaddr>) -> String? {
    let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
    guard link.sdl_alen == 6 else { return nil }

    var bytes: [UInt8] = []
    withUnsafePointer(to: link.sdl_data) { tuple in
      tuple.withMemoryRebound(to: CChar.self, capacity: Int(link.sdl_len)) { raw in
        let offset = Int(link.sdl_nlen)
        for index in 0..<Int(link.sdl_alen) {
          bytes.append(UInt8(bitPattern: raw[offset + index]))
        }
      }
    }
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
  }

  private static func numericHost(from address: UnsafeMutablePointer<sockaddr>) -> String? {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard
      getnameinfo(
        address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
        NI_NUMERICHOST) == 0
    else { return nil }
    return String(cString: host)
  }

  // MARK: - sysctl

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
