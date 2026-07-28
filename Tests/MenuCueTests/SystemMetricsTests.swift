import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import MenuCue

final class SystemMetricsFormatterTests: XCTestCase {
  func testCapacityKeepsThreeSignificantDigitsAcrossMagnitudes() {
    XCTAssertEqual(SystemMetricsFormatter.capacity(8_100_000_000), "8.10 GB")
    XCTAssertEqual(SystemMetricsFormatter.capacity(94_980_000_000), "95.0 GB")
    XCTAssertEqual(SystemMetricsFormatter.capacity(494_380_000_000), "494 GB")
    XCTAssertEqual(SystemMetricsFormatter.capacity(2_000_000_000_000), "2.00 TB")
  }

  func testRateAppendsPerSecondAndFloorsNoise() {
    XCTAssertEqual(SystemMetricsFormatter.rate(0), "0 KB/s")
    XCTAssertEqual(SystemMetricsFormatter.rate(0.4), "0 KB/s")
    XCTAssertEqual(SystemMetricsFormatter.rate(44_100_000), "44.1 MB/s")
    XCTAssertEqual(SystemMetricsFormatter.rate(453_000), "453 KB/s")
  }

  func testUptimeDropsLeadingZeroUnits() {
    XCTAssertEqual(SystemMetricsFormatter.uptime(0), "0m")
    XCTAssertEqual(SystemMetricsFormatter.uptime(90), "1m")
    XCTAssertEqual(SystemMetricsFormatter.uptime(3_600 * 5 + 120), "5h 2m")
    XCTAssertEqual(SystemMetricsFormatter.uptime(86_400 + 3_600 * 16 + 480), "1d 16h 8m")
  }

  func testPercentRoundsToWholeNumbers() {
    XCTAssertEqual(SystemMetricsFormatter.percent(0), "0%")
    XCTAssertEqual(SystemMetricsFormatter.percent(0.384), "38%")
    XCTAssertEqual(SystemMetricsFormatter.percent(1), "100%")
  }
}

final class CPULoadSampleTests: XCTestCase {
  func testLoadIsComputedFromTickDeltasNotAbsoluteCounters() throws {
    let previous = CPUTicks(user: 1_000, system: 500, idle: 8_000, nice: 0)
    let current = CPUTicks(user: 1_400, system: 700, idle: 8_400, nice: 0)

    let load = try XCTUnwrap(SystemMetricsProbe.cpuLoad(from: previous, to: current))

    XCTAssertEqual(load.user, 0.4, accuracy: 0.0001)
    XCTAssertEqual(load.system, 0.2, accuracy: 0.0001)
    XCTAssertEqual(load.idle, 0.4, accuracy: 0.0001)
    XCTAssertEqual(load.busy, 0.6, accuracy: 0.0001)
  }

  func testIdenticalTicksYieldNoSampleRatherThanZeroLoad() {
    let ticks = CPUTicks(user: 10, system: 10, idle: 10, nice: 10)
    XCTAssertNil(SystemMetricsProbe.cpuLoad(from: ticks, to: ticks))
  }

  func testCountersThatWentBackwardsAreRejected() {
    let previous = CPUTicks(user: 5_000, system: 1_000, idle: 9_000, nice: 0)
    let current = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
    XCTAssertNil(SystemMetricsProbe.cpuLoad(from: previous, to: current))
  }

  func testNiceTimeIsChargedToTheUserBand() {
    let sample = CPULoadSample(user: 0.3, system: 0.1, nice: 0.05, idle: 0.55)
    XCTAssertEqual(sample.userBand, 0.35, accuracy: 0.0001)
    XCTAssertEqual(sample.systemBand, 0.1, accuracy: 0.0001)
  }
}

final class FanReadingTests: XCTestCase {
  func testLoadFractionSpansTheIdleToMaximumRange() {
    let fan = FanReading(index: 0, currentRPM: 3_000, minRPM: 2_000, maxRPM: 4_000)
    XCTAssertEqual(fan.loadFraction, 0.5, accuracy: 0.0001)
  }

  func testDegenerateRangeReportsNoLoadInsteadOfDividingByZero() {
    let fan = FanReading(index: 0, currentRPM: 2_000, minRPM: 2_000, maxRPM: 2_000)
    XCTAssertEqual(fan.loadFraction, 0)
  }
}

final class MemoryUsageTests: XCTestCase {
  func testUsedMemoryExcludesReclaimableCache() {
    let memory = MemoryUsage(
      appMemory: 6_000_000_000,
      wired: 2_000_000_000,
      compressed: 1_000_000_000,
      cached: 20_000_000_000,
      total: 48_000_000_000
    )
    XCTAssertEqual(memory.used, 9_000_000_000)
    XCTAssertEqual(memory.fraction, 0.1875, accuracy: 0.0001)
  }

  func testUnknownTotalDoesNotProduceInfiniteFraction() {
    let memory = MemoryUsage(appMemory: 1, wired: 0, compressed: 0, cached: 0, total: 0)
    XCTAssertEqual(memory.fraction, 0)
  }
}

/// Exercises the probes against the real machine. These assert only on invariants that
/// hold on any Mac, so they stay valid on other hardware and in CI.
final class SystemMetricsProbeLiveTests: XCTestCase {
  func testHardwareInfoIdentifiesTheChipAndCores() {
    let hardware = SystemMetricsProbe.hardwareInfo()
    XCTAssertFalse(hardware.chipName.isEmpty)
    XCTAssertNotEqual(hardware.chipName, "Mac", "Expected a real brand string from sysctl")
    XCTAssertGreaterThan(hardware.logicalCores, 0)
    XCTAssertFalse(hardware.coreSummary.isEmpty)
  }

  func testBootDateIsInThePast() throws {
    let bootDate = try XCTUnwrap(SystemMetricsProbe.bootDate())
    XCTAssertLessThan(bootDate, Date())
    XCTAssertGreaterThan(bootDate.timeIntervalSince1970, 1_000_000_000)
  }

  func testMemoryUsageReportsAPlausibleFootprint() {
    let memory = SystemMetricsProbe.memoryUsage()
    XCTAssertGreaterThan(memory.total, 1_000_000_000)
    XCTAssertGreaterThan(memory.used, 0)
    XCTAssertLessThanOrEqual(memory.used, memory.total)
  }

  func testDiskCapacityReportsAMountedRootVolume() {
    let disk = SystemMetricsProbe.diskCapacity()
    XCTAssertFalse(disk.name.isEmpty)
    XCTAssertGreaterThan(disk.total, 1_000_000_000)
    XCTAssertLessThanOrEqual(disk.used, disk.total)
  }

  func testCumulativeCountersAdvanceBetweenSamples() throws {
    let first = SystemMetricsProbe.cumulativeCounters()
    let firstTicks = try XCTUnwrap(first.cpuTicks)
    let deadline = Date().addingTimeInterval(1)
    var second = first

    repeat {
      Thread.sleep(forTimeInterval: 0.05)
      second = SystemMetricsProbe.cumulativeCounters()
    } while (second.cpuTicks?.total ?? 0) <= firstTicks.total && Date() < deadline

    let secondTicks = try XCTUnwrap(second.cpuTicks)
    XCTAssertGreaterThan(second.timestamp, first.timestamp)
    XCTAssertGreaterThan(secondTicks.total, firstTicks.total)
    if let firstDiskRead = first.diskReadBytes, let secondDiskRead = second.diskReadBytes {
      XCTAssertGreaterThanOrEqual(secondDiskRead, firstDiskRead)
    }
    if first.networkInterfaceName == second.networkInterfaceName,
      let firstNetworkIn = first.networkInBytes,
      let secondNetworkIn = second.networkInBytes
    {
      XCTAssertGreaterThanOrEqual(secondNetworkIn, firstNetworkIn)
    }
  }

  func testPrimaryIPv4PrefersAPhysicalInterface() throws {
    guard let address = SystemMetricsProbe.primaryIPv4() else {
      throw XCTSkip("No IPv4 address is configured on this machine")
    }
    XCTAssertFalse(address.interface.hasPrefix("lo"))
    XCTAssertFalse(address.interface.hasPrefix("utun"))
    XCTAssertEqual(address.address.split(separator: ".").count, 4)
  }
}

final class SystemMetricsServiceLifecycleTests: XCTestCase {
  func testReleasedSessionRejectsDelayedWorkerResult() {
    let suiteName = "SystemMetricsServiceLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let providerStarted = expectation(description: "counter provider started")
    let unblockProvider = DispatchSemaphore(value: 0)
    var counters = CumulativeCounters()
    counters.timestamp = 100
    counters.cpuTicks = CPUTicks(user: 10, system: 10, idle: 80, nice: 0)

    let service = SystemMetricsService(
      sampleInterval: 30,
      defaults: defaults,
      sensorReader: SensorReaderStub(),
      countersProvider: {
        providerStarted.fulfill()
        _ = unblockProvider.wait(timeout: .now() + 2)
        return counters
      },
      memoryProvider: {
        MemoryUsage(appMemory: 99, wired: 0, compressed: 0, cached: 0, total: 100)
      },
      diskCapacityProvider: { ("Test", 50, 100) }
    )

    service.retain()
    wait(for: [providerStarted], timeout: 1)
    service.release()
    unblockProvider.signal()

    let settled = expectation(description: "stale callback had time to arrive")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
    wait(for: [settled], timeout: 1)

    XCTAssertEqual(service.snapshot, SystemMetricsSnapshot())
    XCTAssertTrue(service.cpuHistory.isEmpty)
  }
}

private final class SensorReaderStub: SystemSensorReading {
  func readFans() -> [FanReading] { [] }
  func readCPUTemperature() -> Double? { nil }
}

/// Verifies the private-API sensor path really returns data on this hardware.
/// Fans are skipped on fanless Macs rather than failing.
final class SystemSensorReaderLiveTests: XCTestCase {
  func testCPUTemperatureIsReadableAndPlausible() throws {
    let reader = SystemSensorReader()
    guard let temperature = reader.readCPUTemperature() else {
      throw XCTSkip("No CPU temperature sensor is exposed on this machine")
    }
    XCTAssertGreaterThan(temperature, 10, "Implausibly cold reading: \(temperature)")
    XCTAssertLessThan(temperature, 120, "Implausibly hot reading: \(temperature)")
  }

  func testFanReadingsAreSelfConsistentWhenFansExist() throws {
    let reader = SystemSensorReader()
    let fans = reader.readFans()
    guard !fans.isEmpty else {
      throw XCTSkip("This Mac is fanless or does not expose fan keys")
    }

    for fan in fans {
      XCTAssertGreaterThanOrEqual(fan.currentRPM, 0)
      XCTAssertLessThan(fan.currentRPM, 20_000, "Implausible fan speed: \(fan.currentRPM)")
      if fan.maxRPM > 0 {
        XCTAssertLessThanOrEqual(fan.minRPM, fan.maxRPM)
      }
    }
  }
}

final class SystemMetricsCacheTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "SystemMetricsCacheTests"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  private func writeCache(savedAt: Date, busy: Double) {
    var snapshot = SystemMetricsSnapshot()
    snapshot.cpu = CPULoadSample(user: busy, system: 0, nice: 0, idle: 1 - busy)
    snapshot.isPrimed = true
    let cache = SystemMetricsService.Cache(
      savedAt: savedAt,
      snapshot: snapshot,
      cpuHistory: [snapshot.cpu, snapshot.cpu]
    )
    defaults.set(try! JSONEncoder().encode(cache), forKey: SystemMetricsService.cacheKey)
  }

  func testRecentCacheIsRestoredSoTheChartDoesNotRestartEmpty() {
    let savedAt = Date(timeIntervalSince1970: 1_000_000)
    writeCache(savedAt: savedAt, busy: 0.4)

    let service = SystemMetricsService(defaults: defaults, now: savedAt.addingTimeInterval(60))

    XCTAssertEqual(service.cpuHistory.count, 2)
    XCTAssertEqual(service.snapshot.cpu.busy, 0.4, accuracy: 0.0001)
  }

  func testStaleCacheIsDiscardedRatherThanShownAsCurrent() {
    let savedAt = Date(timeIntervalSince1970: 1_000_000)
    writeCache(savedAt: savedAt, busy: 0.9)

    let stale = savedAt.addingTimeInterval(SystemMetricsService.cacheMaxAge + 1)
    let service = SystemMetricsService(defaults: defaults, now: stale)

    XCTAssertTrue(service.cpuHistory.isEmpty)
    XCTAssertFalse(service.snapshot.isPrimed)
  }

  func testClockRollBackDoesNotMakeAnOldCacheLookFresh() {
    let savedAt = Date(timeIntervalSince1970: 1_000_000)
    writeCache(savedAt: savedAt, busy: 0.5)

    let service = SystemMetricsService(
      defaults: defaults, now: savedAt.addingTimeInterval(-3_600))

    XCTAssertTrue(service.cpuHistory.isEmpty)
  }

  func testReleaseWithoutASuccessfulSampleDoesNotCreateCache() {
    let service = SystemMetricsService(defaults: defaults)
    service.release()

    XCTAssertNil(defaults.data(forKey: SystemMetricsService.cacheKey))
  }

  func testClosingBeforeFirstSampleDoesNotRefreshRestoredCacheAge() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000_000)
    writeCache(savedAt: savedAt, busy: 0.4)
    let providerStarted = expectation(description: "provider started")
    let unblockProvider = DispatchSemaphore(value: 0)

    let service = SystemMetricsService(
      defaults: defaults,
      now: savedAt.addingTimeInterval(60),
      sensorReader: SensorReaderStub(),
      countersProvider: {
        providerStarted.fulfill()
        _ = unblockProvider.wait(timeout: .now() + 2)
        return CumulativeCounters(timestamp: 1)
      }
    )
    service.retain()
    wait(for: [providerStarted], timeout: 1)
    service.release()
    unblockProvider.signal()

    let settled = expectation(description: "cancelled provider returned")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 1)

    let data = try XCTUnwrap(defaults.data(forKey: SystemMetricsService.cacheKey))
    let persisted = try JSONDecoder().decode(SystemMetricsService.Cache.self, from: data)
    XCTAssertEqual(persisted.savedAt, savedAt)
    XCTAssertEqual(persisted.snapshot.cpu.busy, 0.4, accuracy: 0.0001)
  }
}

final class AdaptiveSamplingPolicyTests: XCTestCase {
  private let settings = MetricsSamplingSettings(
    isAdaptive: true,
    fastestIntervalSeconds: 1.5,
    slowestIntervalSeconds: 10,
    highBatteryPercent: 60,
    lowBatteryPercent: 20
  )

  private func interval(_ power: PowerSourceState, lowPower: Bool = false) -> TimeInterval {
    AdaptiveSamplingPolicy.interval(
      for: power, isLowPowerMode: lowPower, settings: settings)
  }

  func testWallPowerAlwaysSamplesAtTheFastestRate() {
    XCTAssertEqual(interval(.wallPower), 1.5, accuracy: 0.001)
  }

  func testDesktopsWithoutABatteryAreNotThrottled() {
    XCTAssertEqual(interval(.unknown), 1.5, accuracy: 0.001)
  }

  func testFullBatteryUsesTheFastestRateAndLowBatteryTheSlowest() {
    XCTAssertEqual(interval(.battery(percent: 100)), 1.5, accuracy: 0.001)
    XCTAssertEqual(interval(.battery(percent: 60)), 1.5, accuracy: 0.001)
    XCTAssertEqual(interval(.battery(percent: 20)), 10, accuracy: 0.001)
    XCTAssertEqual(interval(.battery(percent: 3)), 10, accuracy: 0.001)
  }

  func testIntervalRampsGraduallyBetweenTheThresholdsInsteadOfStepping() {
    // Midway between 60% and 20% should be midway between 1.5s and 10s.
    XCTAssertEqual(interval(.battery(percent: 40)), 5.75, accuracy: 0.001)

    let samples = stride(from: 60, through: 20, by: -5).map {
      interval(.battery(percent: $0))
    }
    XCTAssertEqual(samples, samples.sorted(), "interval must grow monotonically as charge drops")
  }

  func testLowPowerModeOverridesAHealthyBattery() {
    XCTAssertEqual(interval(.battery(percent: 95), lowPower: true), 10, accuracy: 0.001)
    XCTAssertEqual(interval(.wallPower, lowPower: true), 10, accuracy: 0.001)
  }

  func testDisablingAdaptationPinsTheFastestRate() {
    var fixed = settings
    fixed.isAdaptive = false
    XCTAssertEqual(
      AdaptiveSamplingPolicy.interval(
        for: .battery(percent: 5), isLowPowerMode: true, settings: fixed),
      1.5,
      accuracy: 0.001)
  }

  func testInvertedThresholdsAreNormalizedRatherThanDividingByZero() {
    var inverted = settings
    inverted.highBatteryPercent = 20
    inverted.lowBatteryPercent = 60
    let normalized = inverted.normalized
    XCTAssertGreaterThan(normalized.highBatteryPercent, normalized.lowBatteryPercent)

    let result = AdaptiveSamplingPolicy.interval(
      for: .battery(percent: 40), isLowPowerMode: false, settings: inverted)
    XCTAssertTrue(result.isFinite)
  }

  func testASlowerFastestRateThanTheSlowestIsClampedIntoOrder() {
    var swapped = settings
    swapped.fastestIntervalSeconds = 12
    swapped.slowestIntervalSeconds = 2
    let normalized = swapped.normalized
    XCTAssertGreaterThanOrEqual(
      normalized.slowestIntervalSeconds, normalized.fastestIntervalSeconds)
  }
}

final class SystemMetricsServiceSamplingTests: XCTestCase {
  func testServiceAdoptsTheBatteryAppropriateIntervalOnRetain() {
    let defaults = UserDefaults(suiteName: "SamplingServiceTests")!
    defaults.removePersistentDomain(forName: "SamplingServiceTests")

    let service = SystemMetricsService(
      samplingSettings: .default,
      defaults: defaults,
      powerSourceProvider: { .battery(percent: 20) },
      lowPowerModeProvider: { false }
    )
    service.retain()
    defer { service.release() }

    XCTAssertEqual(service.currentInterval, 10, accuracy: 0.001)
    XCTAssertEqual(service.powerSource, .battery(percent: 20))
  }

  func testEditingSettingsReschedulesWithoutReopeningThePopover() {
    let defaults = UserDefaults(suiteName: "SamplingServiceTests2")!
    defaults.removePersistentDomain(forName: "SamplingServiceTests2")

    let service = SystemMetricsService(
      samplingSettings: .default,
      defaults: defaults,
      powerSourceProvider: { .wallPower },
      lowPowerModeProvider: { false }
    )
    service.retain()
    defer { service.release() }
    XCTAssertEqual(service.currentInterval, 1.5, accuracy: 0.001)

    var faster = MetricsSamplingSettings.default
    faster.fastestIntervalSeconds = 3
    service.applySamplingSettings(faster)

    XCTAssertEqual(service.currentInterval, 3, accuracy: 0.001)
  }

  func testSlowSamplingCoalescesTicksAndDoesNotRunFollowUpAfterRelease() {
    let providerStarted = expectation(description: "metrics provider started")
    let unblockProvider = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var callCount = 0

    let service = SystemMetricsService(
      sampleInterval: 0.5,
      sensorReader: SensorReaderStub(),
      countersProvider: {
        lock.lock()
        callCount += 1
        let isFirstCall = callCount == 1
        lock.unlock()
        if isFirstCall { providerStarted.fulfill() }
        _ = unblockProvider.wait(timeout: .now() + 3)
        return CumulativeCounters(timestamp: 1)
      }
    )
    service.retain()
    wait(for: [providerStarted], timeout: 1)

    let ticksElapsed = expectation(description: "multiple timer ticks elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { ticksElapsed.fulfill() }
    wait(for: [ticksElapsed], timeout: 2)
    lock.lock()
    let callsWhileBlocked = callCount
    lock.unlock()
    XCTAssertEqual(callsWhileBlocked, 1, "timer ticks must coalesce behind one slow sample")

    service.release()
    unblockProvider.signal()
    let settled = expectation(description: "cancelled sample returned")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 1)
    lock.lock()
    let finalCallCount = callCount
    lock.unlock()
    XCTAssertEqual(finalCallCount, 1, "release must discard the coalesced follow-up")
  }
}

final class FlagPaletteTests: XCTestCase {
  private func pixel(hue: Double, saturation: Double = 0.9, brightness: Double = 0.8) -> FlagPixel {
    FlagPixel(hue: hue, saturation: saturation, brightness: brightness)
  }

  private func hue(of color: Color) -> Double {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    NSColor(color).usingColorSpace(.deviceRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return Double(h)
  }

  func testDominantHueWinsOverAMinorityBand() {
    // A red-heavy flag with a small blue canton should read as red, not purple.
    let pixels = Array(repeating: pixel(hue: 0.99), count: 40)
      + Array(repeating: pixel(hue: 0.6), count: 8)
    let color = try! XCTUnwrap(FlagPalette.tint(from: pixels)?.primary)
    XCTAssertGreaterThan(hue(of: color), 0.9)
  }

  func testWhiteAndBlackFieldsAreIgnored() {
    // Every flag has them, so they carry no identity and must not win the histogram.
    let pixels = Array(repeating: pixel(hue: 0, saturation: 0.02, brightness: 1.0), count: 200)
      + Array(repeating: pixel(hue: 0, saturation: 0.0, brightness: 0.05), count: 200)
      + Array(repeating: pixel(hue: 0.33), count: 10)
    let color = try! XCTUnwrap(FlagPalette.tint(from: pixels)?.primary)
    XCTAssertEqual(hue(of: color), 0.33, accuracy: 0.05)
  }

  func testAFlagWithNoSaturatedPixelsYieldsNoColor() {
    let pixels = Array(repeating: pixel(hue: 0.5, saturation: 0.05, brightness: 0.9), count: 50)
    XCTAssertNil(FlagPalette.tint(from: pixels))
  }

  func testTintSaturationIsClampedIntoTheLegibleBand() {
    let washed = Array(repeating: pixel(hue: 0.55, saturation: 0.4, brightness: 0.9), count: 30)
    let color = try! XCTUnwrap(FlagPalette.tint(from: washed)?.primary)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    NSColor(color).usingColorSpace(.deviceRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    XCTAssertGreaterThanOrEqual(Double(s), FlagPalette.tintSaturation.lowerBound - 0.001)
  }

  func testRealFlagsProduceDistinctColors() {
    let japan = FlagPalette.tint(for: "🇯🇵").primary
    let brazil = FlagPalette.tint(for: "🇧🇷").primary
    XCTAssertNotEqual(hue(of: japan), hue(of: brazil), accuracy: 0.0)
    // Japan's disc is red, Brazil's field is green.
    XCTAssertTrue(hue(of: japan) < 0.08 || hue(of: japan) > 0.92, "japan hue \(hue(of: japan))")
    XCTAssertEqual(hue(of: brazil), 0.33, accuracy: 0.12, "brazil hue \(hue(of: brazil))")
  }
}

final class FlagTintSeparationTests: XCTestCase {
  private func pixels(hue: Double, count: Int) -> [FlagPixel] {
    Array(repeating: FlagPixel(hue: hue, saturation: 0.9, brightness: 0.8), count: count)
  }

  func testATwoToneFlagYieldsBothHues() {
    let tint = try! XCTUnwrap(
      FlagPalette.tint(from: pixels(hue: 0.99, count: 40) + pixels(hue: 0.6, count: 20)))
    XCTAssertNotNil(tint.secondary, "red + blue must produce a gradient, not a flat wash")
  }

  func testASingleToneFlagDoesNotInventASecondHue() {
    let tint = try! XCTUnwrap(FlagPalette.tint(from: pixels(hue: 0.0, count: 50)))
    XCTAssertNil(tint.secondary)
  }

  func testAdjacentHuesDoNotCountAsASecondColor() {
    // Red and orange-red are one color band, not a two-tone design.
    let tint = try! XCTUnwrap(
      FlagPalette.tint(from: pixels(hue: 0.01, count: 40) + pixels(hue: 0.06, count: 30)))
    XCTAssertNil(tint.secondary)
  }

  func testAFaintThirdColorIsIgnored() {
    let tint = try! XCTUnwrap(
      FlagPalette.tint(from: pixels(hue: 0.33, count: 100) + pixels(hue: 0.6, count: 5)))
    XCTAssertNil(tint.secondary, "a stray emblem must not drive half the gradient")
  }

  func testHueSeparationWrapsAroundTheColorWheel() {
    XCTAssertEqual(FlagPalette.separation(from: 0, to: 11), 1)
    XCTAssertEqual(FlagPalette.separation(from: 0, to: 6), 6)
  }

  func testRedHeavyFlagsAreDistinguishedByTheirSecondHue() {
    // The whole point of the two-hue design: these all won on red before.
    for flag in ["🇺🇸", "🇬🇧"] {
      XCTAssertNotNil(FlagPalette.tint(for: flag).secondary, "\(flag) should be two-tone")
    }
  }
}

final class SystemDetailProbeTests: XCTestCase {
  func testHelperProcessesFoldIntoTheirParentApp() {
    XCTAssertEqual(
      SystemDetailProbe.displayName(for: "Google Chrome Helper (Renderer)"), "Google Chrome")
    XCTAssertEqual(SystemDetailProbe.displayName(for: "Orca Helper (GPU)"), "Orca")
    XCTAssertEqual(SystemDetailProbe.displayName(for: "node"), "node")
  }

  func testAHelperNamedProcessWithNoParentKeepsItsOwnName() {
    XCTAssertEqual(SystemDetailProbe.displayName(for: " Helper"), " Helper")
  }

  func testRankingSumsHelpersSoBrowsersOutrankASingleLargeProcess() {
    let entries = [
      ProcessMemoryEntry(pid: 1, name: "bun", residentBytes: 900),
      ProcessMemoryEntry(pid: 2, name: "Google Chrome", residentBytes: 400),
      ProcessMemoryEntry(pid: 3, name: "Google Chrome Helper (Renderer)", residentBytes: 400),
      ProcessMemoryEntry(pid: 4, name: "Google Chrome Helper (GPU)", residentBytes: 400),
    ]
    let ranked = SystemDetailProbe.rank(entries, limit: 5)

    XCTAssertEqual(ranked.first?.name, "Google Chrome")
    XCTAssertEqual(ranked.first?.residentBytes, 1200)
    XCTAssertEqual(ranked.count, 2)
  }

  func testRankingHonoursTheLimitAndOrdersDescending() {
    let entries = (1...10).map {
      ProcessMemoryEntry(pid: Int32($0), name: "p\($0)", residentBytes: UInt64($0) * 100)
    }
    let ranked = SystemDetailProbe.rank(entries, limit: 3)

    XCTAssertEqual(ranked.map(\.name), ["p10", "p9", "p8"])
  }

  func testMergedEntryKeepsThePidOfItsLargestMember() {
    let entries = [
      ProcessMemoryEntry(pid: 7, name: "Orca Helper (GPU)", residentBytes: 100),
      ProcessMemoryEntry(pid: 9, name: "Orca Helper (Renderer)", residentBytes: 800),
    ]
    XCTAssertEqual(SystemDetailProbe.rank(entries, limit: 1).first?.pid, 9)
  }

  func testLiveProbesDegradeToEmptyRatherThanCrashing() {
    // Both walk private-ish interfaces; the contract is "never throw, never trap".
    _ = SystemDetailProbe.gpuStats()
    let processes = SystemDetailProbe.topMemoryProcesses(limit: 4)
    XCTAssertLessThanOrEqual(processes.count, 4)
    XCTAssertEqual(processes, processes.sorted { $0.residentBytes > $1.residentBytes })
  }
}

final class SystemDetailServiceLifecycleTests: XCTestCase {
  func testSlowProbeCoalescesRefreshTicksAndRejectsDismissedResult() {
    let probeStarted = expectation(description: "detail probe started")
    let unblockProbe = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var callCount = 0

    let service = SystemDetailService(
      refreshInterval: 0.01,
      sensorReader: SensorReaderStub(),
      gpuProvider: {
        lock.lock()
        callCount += 1
        let isFirstCall = callCount == 1
        lock.unlock()
        if isFirstCall { probeStarted.fulfill() }
        _ = unblockProbe.wait(timeout: .now() + 2)
        return GPUStats(
          deviceUtilization: 0.75,
          rendererUtilization: nil,
          inUseMemory: nil
        )
      },
      processProvider: { [] }
    )

    service.hover(.cpu)
    wait(for: [probeStarted], timeout: 1)

    let ticksElapsed = expectation(description: "refresh ticks elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { ticksElapsed.fulfill() }
    wait(for: [ticksElapsed], timeout: 1)
    lock.lock()
    let callsWhileBlocked = callCount
    lock.unlock()
    XCTAssertEqual(callsWhileBlocked, 1, "slow probes must not queue without bound")

    service.hover(nil)
    unblockProbe.signal()
    let settled = expectation(description: "dismissed result returned")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 1)

    XCTAssertNil(service.target)
    XCTAssertTrue(service.gpu.isEmpty, "a dismissed probe must not publish stale content")
  }
}

final class MetricsSamplingPersistenceTests: XCTestCase {
  private let suiteName = "MetricsSamplingPersistenceTests"

  func testSamplingRoundTripsOnlyThroughLocalSettingsStore() {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = SettingsStore(defaults: defaults)
    var settings = store.load()
    settings.metricsSampling = MetricsSamplingSettings(
      isAdaptive: true,
      fastestIntervalSeconds: 2,
      slowestIntervalSeconds: 15,
      highBatteryPercent: 70,
      lowBatteryPercent: 25
    )
    store.save(settings)

    XCTAssertEqual(store.load().metricsSampling, settings.metricsSampling)
    XCTAssertFalse(
      PortableSettingField.allCases.map(\.rawValue).contains("metricsSampling"),
      "machine-specific battery policy must never enter iCloud envelopes"
    )
  }

  func testMissingOrCorruptSamplingDataFallsBackToDefaults() {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = SettingsStore(defaults: defaults)
    XCTAssertEqual(store.load().metricsSampling, .default)

    defaults.set(Data("not-json".utf8), forKey: "metricsSampling.v1")
    XCTAssertEqual(store.load().metricsSampling, .default)
  }
}

final class MetricsSamplingNormalizationTests: XCTestCase {
  /// The ramp divides by `high - low`, so this invariant must hold for every input.
  func testThresholdsAreAlwaysOrderedWhateverTheInput() {
    let candidates = [-50, 0, 1, 4, 5, 20, 60, 94, 95, 96, 200]
    for low in candidates {
      for high in candidates {
        var settings = MetricsSamplingSettings.default
        settings.lowBatteryPercent = low
        settings.highBatteryPercent = high
        let normalized = settings.normalized

        XCTAssertGreaterThan(
          normalized.highBatteryPercent, normalized.lowBatteryPercent,
          "low=\(low) high=\(high)")
        XCTAssertTrue(
          MetricsSamplingSettings.percentRange.contains(normalized.lowBatteryPercent))
        XCTAssertTrue(
          MetricsSamplingSettings.percentRange.contains(normalized.highBatteryPercent))
      }
    }
  }

  func testEveryBatteryLevelYieldsAFiniteIntervalInsideTheConfiguredBand() {
    var settings = MetricsSamplingSettings.default
    settings.lowBatteryPercent = 95
    settings.highBatteryPercent = 95
    let normalized = settings.normalized

    for percent in 0...100 {
      let interval = AdaptiveSamplingPolicy.interval(
        for: .battery(percent: percent), isLowPowerMode: false, settings: settings)
      XCTAssertTrue(interval.isFinite, "percent \(percent) produced \(interval)")
      XCTAssertGreaterThanOrEqual(interval, normalized.fastestIntervalSeconds - 0.001)
      XCTAssertLessThanOrEqual(interval, normalized.slowestIntervalSeconds + 0.001)
    }
  }
}

final class MetricDetailPlacementTests: XCTestCase {
  private let container = CGSize(width: 360, height: 500)
  private let inset = PopoverMetrics.contentPadding
  private let width = StatusTabView.detailPanelWidth

  private func origin(card: CGRect, height: CGFloat) -> CGPoint {
    StatusTabView.panelOrigin(cardFrame: card, container: container, height: height)
  }

  func testPanelOpensBelowACardNearTheTop() {
    let card = CGRect(x: 20, y: 20, width: 150, height: 90)
    let point = origin(card: card, height: 120)
    XCTAssertEqual(point.y, card.maxY + StatusTabView.detailPanelGap, accuracy: 0.01)
  }

  func testPanelFlipsAboveWhenThereIsNoRoomBelow() {
    let card = CGRect(x: 20, y: 360, width: 150, height: 90)
    let height: CGFloat = 200
    let point = origin(card: card, height: height)
    XCTAssertEqual(
      point.y, card.minY - StatusTabView.detailPanelGap - height, accuracy: 0.01)
  }

  /// The bug from the screenshot: a tall panel above a low card ran off the top.
  func testATallPanelIsClampedInsideTheContainerInsteadOfOverflowing() {
    let card = CGRect(x: 20, y: 300, width: 150, height: 120)
    let height: CGFloat = 420
    let point = origin(card: card, height: height)

    XCTAssertGreaterThanOrEqual(point.y, inset - 0.01, "panel ran off the top")
    XCTAssertLessThanOrEqual(
      point.y + height, container.height + 0.01, "panel ran off the bottom")
  }

  func testPanelStaysInsideTheContainerForEveryCardPositionAndHeight() {
    for cardY in stride(from: CGFloat(0), through: 420, by: 30) {
      for height in stride(from: CGFloat(60), through: 460, by: 40) {
        let card = CGRect(x: 20, y: cardY, width: 150, height: 80)
        let point = origin(card: card, height: height)
        XCTAssertGreaterThanOrEqual(
          point.y, inset - 0.01, "cardY=\(cardY) height=\(height)")
        if height + 2 * inset <= container.height {
          XCTAssertLessThanOrEqual(
            point.y + height, container.height - inset + 0.01,
            "cardY=\(cardY) height=\(height)")
        }
      }
    }
  }

  func testPanelIsCentredOnItsCardButClampedToTheHorizontalEdges() {
    let centred = origin(card: CGRect(x: 130, y: 10, width: 100, height: 60), height: 100)
    XCTAssertEqual(centred.x, 180 - width / 2, accuracy: 0.01)

    let farLeft = origin(card: CGRect(x: 0, y: 10, width: 60, height: 60), height: 100)
    XCTAssertEqual(farLeft.x, inset, accuracy: 0.01)

    let farRight = origin(card: CGRect(x: 300, y: 10, width: 60, height: 60), height: 100)
    XCTAssertEqual(farRight.x, container.width - width - inset, accuracy: 0.01)
  }
}
