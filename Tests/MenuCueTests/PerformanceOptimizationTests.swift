import Combine
import Foundation
import SwiftUI
import XCTest

@testable import MenuCue

@MainActor
final class StatusSamplingControllerTests: XCTestCase {
  func testVisibilityPublisherStopsSynchronouslyAndIdempotently() {
    let presentation = PopoverPresentationState()
    let controller = StatusSamplingController()
    var starts = 0
    var stops = 0

    controller.connect(
      to: presentation,
      onStart: { starts += 1 },
      onStop: { stops += 1 }
    )
    presentation.setVisible(true)
    XCTAssertTrue(controller.isActive)
    XCTAssertEqual(starts, 1)
    presentation.setVisible(true)
    XCTAssertEqual(starts, 1)

    presentation.setVisible(false)
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(stops, 1)
    presentation.setVisible(false)
    XCTAssertEqual(stops, 1)

    presentation.setVisible(true)
    XCTAssertTrue(controller.isActive)
    XCTAssertEqual(starts, 2)
    controller.disconnect()
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(stops, 2)
    presentation.setVisible(false)
    XCTAssertEqual(stops, 2)
  }

  func testClosingPresentationPreventsPrimingAndTimerSamples() {
    let suite = "StatusSamplingControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstProbe = expectation(description: "first probe started")
    let counters = CounterSequence(onFirstCall: { firstProbe.fulfill() })
    let service = SystemMetricsService(
      sampleInterval: 0.5,
      defaults: defaults,
      sensorReader: StaticSensorReader(),
      countersProvider: counters.next,
      diskCapacityProvider: { ("Test", 50, 100) },
      powerSourceProvider: { .unknown },
      lowPowerModeProvider: { false }
    )
    let presentation = PopoverPresentationState()
    let controller = StatusSamplingController()
    controller.connect(
      to: presentation,
      onStart: service.retain,
      onStop: service.release
    )

    presentation.setVisible(true)
    wait(for: [firstProbe], timeout: 1)
    presentation.setVisible(false)
    XCTAssertFalse(controller.isActive)

    let settled = expectation(description: "timer windows elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { settled.fulfill() }
    wait(for: [settled], timeout: 2)
    XCTAssertEqual(counters.callCount, 1)
    controller.disconnect()
  }
}

final class MetricChartPointTests: XCTestCase {
  private let size = CGSize(width: 100, height: 80)

  func testCPUChartKeepsEmptyAndSingleSampleGeometry() {
    XCTAssertTrue(
      CPUUsageChart.points(samples: [], capacity: 48, in: size, value: \.busy).isEmpty)

    let sample = CPULoadSample(user: 0.25, system: 0.25, nice: 0, idle: 0.5)
    XCTAssertEqual(
      CPUUsageChart.points(samples: [sample], capacity: 48, in: size, value: \.busy),
      [CGPoint(x: 0, y: 40), CGPoint(x: 100, y: 40)]
    )
  }

  func testCPUAndSeriesPointsSpanTheFullWindowOnce() {
    let samples = [
      CPULoadSample(user: 0, system: 0, nice: 0, idle: 1),
      CPULoadSample(user: 0.5, system: 0, nice: 0, idle: 0.5),
      CPULoadSample(user: 1, system: 0, nice: 0, idle: 0),
    ]

    XCTAssertEqual(
      CPUUsageChart.points(samples: samples, capacity: 3, in: size, value: \.user),
      [CGPoint(x: 0, y: 80), CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 0)]
    )
    XCTAssertEqual(
      SeriesChart.points([0, 5, 10], capacity: 3, in: size, scale: 10),
      [CGPoint(x: 0, y: 80), CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 0)]
    )
  }
}

final class SystemMetricsPublicationTests: XCTestCase {
  private var cancellables: Set<AnyCancellable> = []

  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }

  func testEachCompletedSamplePublishesOneCoherentFrameAfterHistorySaturates() {
    let defaults = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
    let counters = CounterSequence()
    let service = makeService(defaults: defaults, counters: counters, historyCapacity: 1)
    let received = expectation(description: "four coherent frames")
    received.expectedFulfillmentCount = 4
    var frames: [SystemMetricsDisplayFrame] = []

    service.$frame.dropFirst().sink { frame in
      frames.append(frame)
      if frames.count <= 4 { received.fulfill() }
    }.store(in: &cancellables)

    service.retain()
    wait(for: [received], timeout: 3)
    service.release()

    XCTAssertEqual(frames.count, 4)
    XCTAssertEqual(counters.callCount, 4)
    XCTAssertTrue(frames[0].cpuHistory.isEmpty)
    for frame in frames.dropFirst() {
      XCTAssertEqual(frame.cpuHistory.count, 1)
      XCTAssertEqual(frame.snapshot.cpu, frame.cpuHistory.last)
    }
  }

  func testDiskAndSensorsUseInjectedMonotonicCadence() {
    let defaults = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
    let counters = CounterSequence()
    let clock = LockedTime(0)
    let sensor = CountingSensorReader()
    let diskCalls = LockedCount()
    let service = makeService(
      defaults: defaults,
      counters: counters,
      sensor: sensor,
      diskCapacityProvider: {
        diskCalls.increment()
        return ("Test", 50, 100)
      },
      monotonicNow: { clock.value }
    )
    let firstWindow = expectation(description: "initial and priming frames")
    firstWindow.expectedFulfillmentCount = 2
    let beforeSensorBoundary = expectation(description: "frame before sensor boundary")
    let sensorBoundary = expectation(description: "frame at sensor boundary")
    let beforeDiskBoundary = expectation(description: "frame before disk boundary")
    let diskBoundary = expectation(description: "frame at disk boundary")
    var frameCount = 0

    service.$frame.dropFirst().sink { _ in
      frameCount += 1
      switch frameCount {
      case 1, 2: firstWindow.fulfill()
      case 3: beforeSensorBoundary.fulfill()
      case 4: sensorBoundary.fulfill()
      case 5: beforeDiskBoundary.fulfill()
      case 6: diskBoundary.fulfill()
      default: break
      }
    }.store(in: &cancellables)

    service.retain()
    wait(for: [firstWindow], timeout: 2)
    XCTAssertEqual(diskCalls.value, 1)
    XCTAssertEqual(sensor.fanReads, 1)
    XCTAssertEqual(sensor.temperatureReads, 1)

    clock.value = 9
    wait(for: [beforeSensorBoundary], timeout: 2)
    XCTAssertEqual(diskCalls.value, 1)
    XCTAssertEqual(sensor.fanReads, 1)

    clock.value = 10
    wait(for: [sensorBoundary], timeout: 2)
    XCTAssertEqual(diskCalls.value, 1)
    XCTAssertEqual(sensor.fanReads, 2)

    clock.value = 59
    wait(for: [beforeDiskBoundary], timeout: 2)
    XCTAssertEqual(diskCalls.value, 1)
    XCTAssertEqual(sensor.fanReads, 3)

    clock.value = 60
    wait(for: [diskBoundary], timeout: 2)
    service.release()

    XCTAssertEqual(diskCalls.value, 2)
    XCTAssertEqual(sensor.fanReads, 3)
    XCTAssertEqual(sensor.temperatureReads, 3)
  }

  func testTransientDiskFailureKeepsLastValueAndRetriesNextSample() {
    let defaults = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
    let counters = CounterSequence()
    let clock = LockedTime(0)
    let capacities = CapacitySequence([
      ("Test", 50, 100),
      ("Macintosh HD", 0, 0),
      ("Test", 60, 100),
    ])
    let service = makeService(
      defaults: defaults,
      counters: counters,
      diskCapacityProvider: capacities.next,
      monotonicNow: { clock.value }
    )
    let initial = expectation(description: "initial cached frames")
    initial.expectedFulfillmentCount = 2
    let failedRefresh = expectation(description: "failed refresh frame")
    let recoveredRefresh = expectation(description: "recovered refresh frame")
    var frames: [SystemMetricsDisplayFrame] = []

    service.$frame.dropFirst().sink { frame in
      frames.append(frame)
      switch frames.count {
      case 1, 2: initial.fulfill()
      case 3: failedRefresh.fulfill()
      case 4: recoveredRefresh.fulfill()
      default: break
      }
    }.store(in: &cancellables)

    service.retain()
    wait(for: [initial], timeout: 2)
    clock.value = 60
    wait(for: [failedRefresh], timeout: 2)
    XCTAssertEqual(capacities.callCount, 2)
    XCTAssertEqual(frames[2].snapshot.disk.used, 50)
    XCTAssertEqual(frames[2].snapshot.disk.total, 100)

    clock.value = 61
    wait(for: [recoveredRefresh], timeout: 2)
    service.release()

    XCTAssertEqual(capacities.callCount, 3)
    XCTAssertEqual(frames[3].snapshot.disk.used, 60)
    XCTAssertEqual(frames[3].snapshot.disk.total, 100)
  }

  private func makeService(
    defaults: UserDefaults,
    counters: CounterSequence,
    historyCapacity: Int = SystemMetricsService.historyCapacity,
    sensor: SystemSensorReading = StaticSensorReader(),
    diskCapacityProvider: @escaping () -> (name: String, used: UInt64, total: UInt64) = {
      ("Test", 50, 100)
    },
    monotonicNow: @escaping () -> TimeInterval = { 0 }
  ) -> SystemMetricsService {
    SystemMetricsService(
      sampleInterval: 0.5,
      historyCapacity: historyCapacity,
      sensorRefreshInterval: 10,
      diskCapacityRefreshInterval: 60,
      monotonicNow: monotonicNow,
      defaults: defaults,
      sensorReader: sensor,
      countersProvider: counters.next,
      memoryProvider: {
        MemoryUsage(appMemory: 50, wired: 0, compressed: 0, cached: 0, total: 100)
      },
      diskCapacityProvider: diskCapacityProvider,
      powerSourceProvider: { .unknown },
      lowPowerModeProvider: { false }
    )
  }

  private func isolatedDefaults() -> UserDefaults {
    let suite = "SystemMetricsPublicationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(suite, forKey: "test-suite-name")
    return defaults
  }

  private func defaultsSuite(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "test-suite-name")!
  }
}

private final class CounterSequence {
  private let lock = NSLock()
  private let onFirstCall: (() -> Void)?
  private var calls = 0

  init(onFirstCall: (() -> Void)? = nil) {
    self.onFirstCall = onFirstCall
  }

  var callCount: Int {
    lock.withLock { calls }
  }

  func next() -> CumulativeCounters {
    let result: (CumulativeCounters, Bool) = lock.withLock {
      calls += 1
      let value = UInt64(calls * 10)
      return (
        CumulativeCounters(
          timestamp: TimeInterval(calls),
          cpuTicks: CPUTicks(user: value, system: value, idle: value * 2, nice: 0)
        ),
        calls == 1
      )
    }
    if result.1 { onFirstCall?() }
    return result.0
  }
}

private final class CapacitySequence {
  typealias Capacity = (name: String, used: UInt64, total: UInt64)

  private let lock = NSLock()
  private let values: [Capacity]
  private var index = 0

  init(_ values: [Capacity]) {
    self.values = values
  }

  var callCount: Int { lock.withLock { index } }

  func next() -> Capacity {
    lock.withLock {
      let value = values[min(index, values.count - 1)]
      index += 1
      return value
    }
  }
}

private final class LockedTime {
  private let lock = NSLock()
  private var storage: TimeInterval

  init(_ value: TimeInterval) {
    storage = value
  }

  var value: TimeInterval {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class LockedCount {
  private let lock = NSLock()
  private var storage = 0

  var value: Int { lock.withLock { storage } }

  func increment() {
    lock.withLock { storage += 1 }
  }
}

private final class CountingSensorReader: SystemSensorReading {
  private let lock = NSLock()
  private var fanReadCount = 0
  private var temperatureReadCount = 0

  var fanReads: Int { lock.withLock { fanReadCount } }
  var temperatureReads: Int { lock.withLock { temperatureReadCount } }

  func readFans() -> [FanReading] {
    lock.withLock { fanReadCount += 1 }
    return [FanReading(index: 0, currentRPM: 2_000, minRPM: 1_000, maxRPM: 4_000)]
  }

  func readCPUTemperature() -> Double? {
    lock.withLock { temperatureReadCount += 1 }
    return 55
  }
}

private final class StaticSensorReader: SystemSensorReading {
  func readFans() -> [FanReading] { [] }
  func readCPUTemperature() -> Double? { nil }
}
