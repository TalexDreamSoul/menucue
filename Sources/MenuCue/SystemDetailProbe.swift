import Darwin
import Foundation
import IOKit

/// GPU load, read from the accelerator's own performance counters. Unlike
/// `powermetrics` this needs no elevated privileges.
struct GPUStats: Equatable, Codable {
  var deviceUtilization: Double?
  var rendererUtilization: Double?
  var inUseMemory: UInt64?

  var isEmpty: Bool {
    deviceUtilization == nil && rendererUtilization == nil && inUseMemory == nil
  }
}

/// What a thermal sensor is measuring. `label` is localized for display, so it can
/// never be matched against — this is the stable identity a caller filters on.
enum ThermalSensorKind: String, Equatable, Codable {
  case performanceCluster
  case efficiencyCluster
  case gpu
  case soc
  case die
  case device
  case neuralEngine
  case other
}

/// One named thermal sensor, so the CPU detail can show P-cluster, E-cluster and
/// GPU separately instead of collapsing to a single hottest number.
struct ThermalReading: Identifiable, Equatable, Codable {
  let label: String
  let celsius: Double
  var kind: ThermalSensorKind = .other

  var id: String { label }
}

/// A process and what it is holding in physical memory.
struct ProcessMemoryEntry: Identifiable, Equatable, Codable {
  let pid: Int32
  let name: String
  let residentBytes: UInt64

  var id: Int32 { pid }
}

enum SystemDetailProbe {
  // MARK: - GPU

  static func gpuStats() -> GPUStats {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return GPUStats() }
    defer { IOObjectRelease(iterator) }

    var result = GPUStats()
    var service = IOIteratorNext(iterator)
    while service != 0 {
      defer {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
      }
      var unmanaged: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let properties = unmanaged?.takeRetainedValue() as? [String: Any],
        let statistics = properties["PerformanceStatistics"] as? [String: Any]
      else { continue }

      // Machines with more than one accelerator report each separately; the busiest
      // is the one the user is actually watching.
      if let value = statistics["Device Utilization %"] as? Int {
        result.deviceUtilization = max(result.deviceUtilization ?? 0, Double(value) / 100)
      }
      if let value = statistics["Renderer Utilization %"] as? Int {
        result.rendererUtilization = max(result.rendererUtilization ?? 0, Double(value) / 100)
      }
      if let value = statistics["In use system memory"] as? Int, value > 0 {
        result.inUseMemory = max(result.inUseMemory ?? 0, UInt64(value))
      }
    }
    return result
  }

  // MARK: - Processes

  /// Top memory consumers. Processes owned by other users (mostly root daemons)
  /// cannot be inspected without privileges and are skipped — they are small, and
  /// every user-visible app is readable.
  ///
  /// The default suits the popover's hover panel, which is a glance rather than a list.
  /// The Dashboard's Memory tab asks for a longer one explicitly.
  static func topMemoryProcesses(limit: Int = 3) -> [ProcessMemoryEntry] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }

    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let byteCount = capacity * Int32(MemoryLayout<pid_t>.size)
    let written = proc_listallpids(&pids, byteCount)
    guard written > 0 else { return [] }

    let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
    var entries: [ProcessMemoryEntry] = []
    entries.reserveCapacity(Int(written))

    for pid in pids.prefix(Int(written)) where pid > 0 {
      var info = proc_taskinfo()
      guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize else { continue }
      guard info.pti_resident_size > 0 else { continue }

      var nameBuffer = [CChar](repeating: 0, count: 256)
      guard proc_name(pid, &nameBuffer, 256) > 0 else { continue }
      let name = String(cString: nameBuffer)
      guard !name.isEmpty else { continue }

      entries.append(
        ProcessMemoryEntry(pid: pid, name: name, residentBytes: info.pti_resident_size))
    }

    return Self.rank(entries, limit: limit)
  }

  /// Multi-process apps (browsers, Electron) report a dozen helpers that individually
  /// look small; summing them by name is what a user means by "what is using memory".
  static func rank(_ entries: [ProcessMemoryEntry], limit: Int) -> [ProcessMemoryEntry] {
    var totals: [String: (pid: Int32, bytes: UInt64)] = [:]
    for entry in entries {
      let key = displayName(for: entry.name)
      let existing = totals[key]
      totals[key] = (
        pid: existing.map { entry.residentBytes > $0.bytes ? entry.pid : $0.pid } ?? entry.pid,
        bytes: (existing?.bytes ?? 0) &+ entry.residentBytes
      )
    }

    let merged: [ProcessMemoryEntry] = totals.map { key, value in
      ProcessMemoryEntry(pid: value.pid, name: key, residentBytes: value.bytes)
    }
    let ordered = merged.sorted { lhs, rhs in
      if lhs.residentBytes != rhs.residentBytes { return lhs.residentBytes > rhs.residentBytes }
      return lhs.name < rhs.name
    }
    return Array(ordered.prefix(limit))
  }

  /// "Google Chrome Helper (Renderer)" and "Orca Helper (GPU)" fold into their app.
  static func displayName(for processName: String) -> String {
    guard let range = processName.range(of: " Helper") else { return processName }
    let base = String(processName[processName.startIndex..<range.lowerBound])
    return base.isEmpty ? processName : base
  }
}
