import AppKit
import Combine
import Foundation

final class PowerDiagnosticsService: ObservableObject {
  @Published private(set) var snapshot = PowerDiagnosticsSnapshot()
  @Published private(set) var battery: BatteryStatus?
  @Published private(set) var isRefreshing = false

  private let probe: PowerDiagnosticsProbing
  private let historyStore: WakeHistoryStore
  private let notificationCenter: NotificationCenter
  private let batteryRefreshInterval: TimeInterval
  private let queue = DispatchQueue(label: "com.tagzxia.app.menucue.power-diagnostics", qos: .utility)
  private var wakeObserver: NSObjectProtocol?
  private var batteryTimer: Timer?
  private var activationCount = 0
  private var refreshInFlight = false
  private var refreshPending = false
  private var generation = 0
  /// Keeps history current while nothing is on screen.
  ///
  /// The wake observer alone was not enough: it refreshed a snapshot nobody could see
  /// unless the popover happened to be open. Backfill from `pmset` covers gaps, but
  /// only if something asks for it — so this asks, on a slow cadence.
  private var backgroundTimer: Timer?
  private var isBackgroundMonitoringEnabled = false
  private var batteryRefreshInFlight = false
  private var batteryRefreshPending = false
  private var batteryGeneration = 0

  init(
    probe: PowerDiagnosticsProbing = SystemPowerDiagnosticsProbe(),
    historyStore: WakeHistoryStore = .applicationStore(),
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    batteryRefreshInterval: TimeInterval = 5
  ) {
    self.probe = probe
    self.historyStore = historyStore
    self.notificationCenter = notificationCenter
    self.batteryRefreshInterval = max(0.001, batteryRefreshInterval)
    wakeObserver = notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
    }
  }

  /// Starts the low-cadence background refresh.
  ///
  /// Deliberately opt-in and persisted by the caller: nothing samples until the user
  /// has opened this feature at least once, and after that it keeps working with the
  /// popover closed — which is the whole point of asking "what woke my Mac".
  func startBackgroundMonitoring(interval: TimeInterval = 900) {
    guard !isBackgroundMonitoringEnabled else { return }
    isBackgroundMonitoringEnabled = true
    let timer = Timer(timeInterval: max(60, interval), repeats: true) { [weak self] _ in
      self?.refreshHistoryOnly()
    }
    RunLoop.main.add(timer, forMode: .common)
    backgroundTimer = timer
  }

  func stopBackgroundMonitoring() {
    isBackgroundMonitoringEnabled = false
    backgroundTimer?.invalidate()
    backgroundTimer = nil
  }

  /// Backfills wake history without touching the readings only the UI needs.
  ///
  /// Assertions and battery flow describe *now*, so they are pointless when nothing is
  /// watching. Wake history is the opposite: it is the record of what happened while
  /// nobody was looking.
  private func refreshHistoryOnly() {
    guard !refreshInFlight else { return }
    refreshInFlight = true
    generation &+= 1
    let requestGeneration = generation

    queue.async { [weak self] in
      guard let self else { return }
      var scheduled: [ScheduledWake] = []
      var failed = false
      do {
        let reading = try self.probe.wakeLog()
        scheduled = reading.scheduled
        try self.historyStore.merge(reading.events)
      } catch {
        failed = true
      }
      let history = (try? self.historyStore.load())
      DispatchQueue.main.async {
        self.refreshInFlight = false
        defer {
          // A press that arrived while this backfill was running was recorded and must
          // still be served. Without this it was dropped: `pmset -g log` takes several
          // seconds, so the window is wide, and the user saw a Refresh button that did
          // nothing at all.
          if self.refreshPending { self.refresh() }
        }
        guard requestGeneration == self.generation else { return }
        if let history, !failed {
          self.snapshot.events = history.events
          self.snapshot.dailySummaries = history.dailySummaries
          self.snapshot.scheduledWakes = scheduled
        }
      }
    }
  }

  deinit {
    backgroundTimer?.invalidate()
    batteryTimer?.invalidate()
    if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
  }

  func retain() {
    activationCount += 1
    guard activationCount == 1 else { return }
    refresh()
    refreshBattery()
    let timer = Timer(timeInterval: batteryRefreshInterval, repeats: true) { [weak self] _ in self?.refreshBattery() }
    RunLoop.main.add(timer, forMode: .common)
    batteryTimer = timer
  }

  func release() {
    activationCount = max(0, activationCount - 1)
    guard activationCount == 0 else { return }
    batteryGeneration += 1
    batteryTimer?.invalidate()
    batteryTimer = nil
    batteryRefreshPending = false
    batteryRefreshInFlight = false
  }

  func refresh() {
    if refreshInFlight {
      refreshPending = true
      // The request was accepted, not ignored. The background backfill sets
      // `refreshInFlight` without ever setting this, so a press landing during one
      // left the button enabled and idle-looking for the whole `pmset -g log` run.
      isRefreshing = true
      return
    }
    refreshInFlight = true
    refreshPending = false
    isRefreshing = true
    generation &+= 1
    let requestGeneration = generation
    let previous = snapshot

    queue.async { [weak self] in
      guard let self else { return }
      var next = previous
      var errors: [String] = []

      do { next.wakeStatistics = try self.probe.wakeStatistics() }
      catch { errors.append(error.localizedDescription) }
      do { next.profiles = try self.probe.powerProfiles() }
      catch { errors.append(error.localizedDescription) }
      do {
        // One pass over the log yields both; two calls meant two 25 MB reads.
        let reading = try self.probe.wakeLog()
        try self.historyStore.merge(reading.events)
        let history = try self.historyStore.load()
        next.events = history.events
        next.dailySummaries = history.dailySummaries
        next.scheduledWakes = reading.scheduled
      } catch { errors.append(error.localizedDescription) }
      // Assertions are cheap and current; a failure here must not blank the history.
      do { next.assertions = try self.probe.sleepAssertions() }
      catch { errors.append(error.localizedDescription) }
      next.refreshedAt = Date()
      next.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")

      DispatchQueue.main.async {
        // Clear the in-flight state before the staleness check. Returning early with
        // it still set would wedge the service: nothing else ever clears it, so every
        // later refresh would queue behind a run that had already finished.
        self.isRefreshing = false
        self.refreshInFlight = false
        defer { if self.refreshPending { self.refresh() } }
        guard requestGeneration == self.generation else { return }
        self.snapshot = next
      }
    }
  }

  func clearHistory() {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        try self.historyStore.clear()
        DispatchQueue.main.async {
          self.snapshot.events = []
          self.snapshot.dailySummaries = []
        }
      } catch {
        DispatchQueue.main.async { self.snapshot.errorMessage = error.localizedDescription }
      }
    }
  }

  private func refreshBattery() {
    guard activationCount > 0 else { return }
    if batteryRefreshInFlight {
      batteryRefreshPending = true
      return
    }
    batteryRefreshInFlight = true
    batteryRefreshPending = false
    let requestGeneration = batteryGeneration
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let battery = try self.probe.batteryStatus()
        DispatchQueue.main.async {
          guard self.activationCount > 0, self.batteryGeneration == requestGeneration else { return }
          self.battery = battery
          self.finishBatteryRefresh()
        }
      } catch {
        DispatchQueue.main.async {
          guard self.activationCount > 0, self.batteryGeneration == requestGeneration else { return }
          var next = self.snapshot
          next.errorMessage = error.localizedDescription
          self.snapshot = next
          self.finishBatteryRefresh()
        }
      }
    }
  }

  private func finishBatteryRefresh() {
    batteryRefreshInFlight = false
    if batteryRefreshPending { refreshBattery() }
  }
}
