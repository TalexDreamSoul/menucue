import Foundation
import IOKit.ps

/// How often the Status tab resamples, and how that rate reacts to battery level.
///
/// Local to the machine — a MacBook on battery and a plugged-in Mac mini want very
/// different answers, so this is deliberately excluded from iCloud sync.
struct MetricsSamplingSettings: Equatable, Codable {
  /// When off, `fastestIntervalSeconds` is used regardless of power state.
  var isAdaptive: Bool
  /// Used on wall power, or at or above `highBatteryPercent`.
  var fastestIntervalSeconds: TimeInterval
  /// Used at or below `lowBatteryPercent`, and whenever Low Power Mode is on.
  var slowestIntervalSeconds: TimeInterval
  var highBatteryPercent: Int
  var lowBatteryPercent: Int

  static let `default` = MetricsSamplingSettings(
    isAdaptive: true,
    fastestIntervalSeconds: 1.5,
    slowestIntervalSeconds: 10,
    highBatteryPercent: 60,
    lowBatteryPercent: 20
  )

  static let intervalRange: ClosedRange<TimeInterval> = 0.5...30
  static let percentRange: ClosedRange<Int> = 5...95

  /// Keeps the pair orderable even if a stored value predates a range change, so the
  /// policy never has to divide by a zero-width or inverted band.
  var normalized: MetricsSamplingSettings {
    var result = self
    result.fastestIntervalSeconds = Self.intervalRange.clamp(fastestIntervalSeconds)
    result.slowestIntervalSeconds = Self.intervalRange.clamp(slowestIntervalSeconds)
    if result.slowestIntervalSeconds < result.fastestIntervalSeconds {
      result.slowestIntervalSeconds = result.fastestIntervalSeconds
    }
    result.lowBatteryPercent = Self.percentRange.clamp(lowBatteryPercent)
    result.highBatteryPercent = Self.percentRange.clamp(highBatteryPercent)
    if result.highBatteryPercent <= result.lowBatteryPercent {
      if result.lowBatteryPercent < Self.percentRange.upperBound {
        result.highBatteryPercent = result.lowBatteryPercent + 1
      } else {
        // The low threshold is already at the ceiling, so there is no room to raise
        // the high one; pull low down instead. Leaving them equal would break the
        // `high > low` invariant the ramp's divisor depends on.
        result.highBatteryPercent = Self.percentRange.upperBound
        result.lowBatteryPercent = Self.percentRange.upperBound - 1
      }
    }
    return result
  }
}

extension ClosedRange where Bound: Comparable {
  func clamp(_ value: Bound) -> Bound {
    Swift.min(upperBound, Swift.max(lowerBound, value))
  }
}

/// What the machine is running on right now.
enum PowerSourceState: Equatable {
  case wallPower
  case battery(percent: Int)
  /// Desktop Macs report no internal battery, and reads can transiently fail.
  case unknown

  var batteryPercent: Int? {
    if case let .battery(percent) = self { return percent }
    return nil
  }
}

/// Maps power state to a sampling interval. Pure, so the ramp is testable without
/// a battery.
enum AdaptiveSamplingPolicy {
  static func interval(
    for power: PowerSourceState,
    isLowPowerMode: Bool,
    settings: MetricsSamplingSettings
  ) -> TimeInterval {
    let settings = settings.normalized
    guard settings.isAdaptive else { return settings.fastestIntervalSeconds }
    // An explicit Low Power Mode request outranks the battery ramp.
    if isLowPowerMode { return settings.slowestIntervalSeconds }

    switch power {
    case .wallPower, .unknown:
      return settings.fastestIntervalSeconds
    case let .battery(percent):
      if percent >= settings.highBatteryPercent { return settings.fastestIntervalSeconds }
      if percent <= settings.lowBatteryPercent { return settings.slowestIntervalSeconds }
      // Ramp linearly between the two thresholds rather than stepping, so the rate
      // decays smoothly as the battery drains instead of lurching at a boundary.
      let span = Double(settings.highBatteryPercent - settings.lowBatteryPercent)
      let drained = Double(settings.highBatteryPercent - percent) / span
      return settings.fastestIntervalSeconds
        + drained * (settings.slowestIntervalSeconds - settings.fastestIntervalSeconds)
    }
  }

  /// Human-readable summary for the settings pane.
  static func describe(_ interval: TimeInterval) -> String {
    interval < 10
      ? L10n.format("%.1fs", interval)
      : L10n.format("%.0fs", interval)
  }
}

enum PowerSourceReader {
  static func current() -> PowerSourceState {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return .unknown }

    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
          as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else { continue }

      if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
        return .wallPower
      }
      guard let current = description[kIOPSCurrentCapacityKey] as? Int,
        let maximum = description[kIOPSMaxCapacityKey] as? Int,
        maximum > 0
      else { return .unknown }

      let percent = Int((Double(current) / Double(maximum) * 100).rounded())
      return .battery(percent: min(100, max(0, percent)))
    }
    return .unknown
  }
}
