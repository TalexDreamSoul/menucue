import Foundation
import XCTest

@testable import TouchMacer

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
    let providerStarted = expectation(description: "counter provider started")
    let unblockProvider = DispatchSemaphore(value: 0)
    var counters = CumulativeCounters()
    counters.timestamp = 100
    counters.cpuTicks = CPUTicks(user: 10, system: 10, idle: 80, nice: 0)

    let service = SystemMetricsService(
      sampleInterval: 60,
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
