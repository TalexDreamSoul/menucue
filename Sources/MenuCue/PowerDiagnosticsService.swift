import AppKit
import Combine
import Foundation

final class PowerDiagnosticsService: ObservableObject {
  @Published private(set) var snapshot = PowerDiagnosticsSnapshot()
  @Published private(set) var battery: BatteryStatus?
  @Published private(set) var isRefreshing = false
  /// What the on-disk history costs and covers, so the pane can say so.
  @Published private(set) var historyFileSizeBytes: UInt64 = 0
  /// Records the one-time v1 migration removed. Surfaced once rather than deleting
  /// the user's data silently.
  @Published private(set) var migrationDroppedRecords = 0
  /// When history was last cleared, and how much that is hiding. Both `nil`/zero when
  /// nothing has been cleared.
  @Published private(set) var clearedAt: Date?
  @Published private(set) var hiddenEventCount = 0

  private let probe: PowerDiagnosticsProbing
  private let historyStore: WakeHistoryStore
  private let notificationCenter: NotificationCenter
  private let batteryRefreshInterval: TimeInterval
  private let wakeRefreshDelay: TimeInterval
  private let queue = DispatchQueue(
    label: "com.tagzxia.app.menucue.power-diagnostics", qos: .utility)
  private var wakeObserver: NSObjectProtocol?
  private var sleepObserver: NSObjectProtocol?
  private var darkWakeHistoryHandler: (([WakeEvent]) -> Void)?
  private var systemSleepHandler: (() -> Void)?
  private var systemWakeHandler: (() -> Void)?
  /// Set when the app has read the log at least once this launch, so the periodic
  /// re-read can be dropped entirely.
  private var hasBackfilled = false
  private var batteryTimer: Timer?
  private var activationCount = 0
  private var refreshInFlight = false
  private var refreshPending = false
  private var historyRefreshPending = false
  private var generation = 0
  /// Keeps history current while nothing is on screen.
  ///
  /// The wake observer alone was not enough: it refreshed a snapshot nobody could see
  /// unless the popover happened to be open. Backfill from `pmset` covers gaps, but
  /// only if something asks for it — so this asks, on a slow cadence.
  private var isBackgroundMonitoringEnabled = false
  private var batteryRefreshInFlight = false
  private var batteryRefreshPending = false
  private var batteryGeneration = 0

  init(
    probe: PowerDiagnosticsProbing = SystemPowerDiagnosticsProbe(),
    historyStore: WakeHistoryStore = .applicationStore(),
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    batteryRefreshInterval: TimeInterval = 5,
    wakeRefreshDelay: TimeInterval = 1
  ) {
    self.probe = probe
    self.historyStore = historyStore
    self.notificationCenter = notificationCenter
    self.batteryRefreshInterval = max(0.001, batteryRefreshInterval)
    self.wakeRefreshDelay = max(0, wakeRefreshDelay)
  }

  var wakeMonitoringReferenceCount: Int {
    (isBackgroundMonitoringEnabled ? 1 : 0)
      + (activationCount > 0 ? 1 : 0)
      + (darkWakeHistoryHandler == nil ? 0 : 1)
  }

  var isWakeObserverRegistered: Bool { wakeObserver != nil }

  func setDarkWakeMonitoring(
    historyHandler: (([WakeEvent]) -> Void)?,
    onSleep: (() -> Void)? = nil,
    onWake: (() -> Void)? = nil
  ) {
    darkWakeHistoryHandler = historyHandler
    systemSleepHandler = historyHandler == nil ? nil : onSleep
    systemWakeHandler = historyHandler == nil ? nil : onWake
    updateWakeObservers()
    guard historyHandler != nil else { return }
    if hasBackfilled {
      historyHandler?(snapshot.events)
    } else {
      backfillOnce()
    }
  }

  /// Brings history up to date once, and then leaves it to the wake notification.
  ///
  /// There used to be a 15-minute timer here. Measurement killed it: `pmset -g log`
  /// alone costs 3.6–5.7 s and 24 MB on this Mac, and the parsing on top of it is
  /// negligible — so the periodic read was paying the entire cost to discover, almost
  /// always, that nothing had happened.
  ///
  /// Nothing needs discovering. `NSWorkspace.didWakeNotification` fires exactly when a
  /// wake occurs, so the log is now read once at launch — to cover whatever happened
  /// while the app was not running — and thereafter only when the machine actually
  /// wakes.
  func startBackgroundMonitoring() {
    guard !isBackgroundMonitoringEnabled else { return }
    isBackgroundMonitoringEnabled = true
    updateWakeObservers()
    backfillOnce()
  }

  func stopBackgroundMonitoring() {
    isBackgroundMonitoringEnabled = false
    updateWakeObservers()
  }

  /// The launch backfill. Idempotent, so calling it from several places is harmless.
  private func backfillOnce() {
    guard !hasBackfilled else { return }
    hasBackfilled = true
    refreshHistoryOnly()
  }

  /// Backfills wake history without touching the readings only the UI needs.
  ///
  /// Assertions and battery flow describe *now*, so they are pointless when nothing is
  /// watching. Wake history is the opposite: it is the record of what happened while
  /// nobody was looking.
  private func refreshHistoryOnly() {
    if refreshInFlight {
      historyRefreshPending = true
      return
    }
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
        defer { self.runPendingRefreshIfNeeded() }
        guard requestGeneration == self.generation else { return }
        self.historyFileSizeBytes = self.historyStore.fileSizeBytes
        self.migrationDroppedRecords = self.historyStore.migrationDroppedRecords
        if let history, !failed {
          self.snapshot.events = history.events
          self.snapshot.dailySummaries = history.dailySummaries
          self.snapshot.scheduledWakes = scheduled
          self.clearedAt = history.clearedAt
          self.hiddenEventCount = history.hiddenEventCount
          self.darkWakeHistoryHandler?(history.events)
        }
      }
    }
  }

  private func runPendingRefreshIfNeeded() {
    if historyRefreshPending {
      historyRefreshPending = false
      refreshHistoryOnly()
    } else if refreshPending {
      refresh()
    }
  }

  private func updateWakeObservers() {
    let shouldObserve = wakeMonitoringReferenceCount > 0
    if shouldObserve, wakeObserver == nil {
      wakeObserver = notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.systemWakeHandler?()
        // pmset writes its line shortly after the workspace notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + self.wakeRefreshDelay) {
          self.refreshHistoryOnly()
        }
      }
      sleepObserver = notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.hasBackfilled = false
        self?.systemSleepHandler?()
      }
    } else if !shouldObserve {
      if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
      if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
      wakeObserver = nil
      sleepObserver = nil
    }
  }

  deinit {
    batteryTimer?.invalidate()
    if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
    if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
  }

  func retain() {
    activationCount += 1
    guard activationCount == 1 else { return }
    updateWakeObservers()
    refresh()
    refreshBattery()
    let timer = Timer(timeInterval: batteryRefreshInterval, repeats: true) { [weak self] _ in
      self?.refreshBattery()
    }
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
    updateWakeObservers()
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
      var clearedAt: Date?
      var hiddenCount = 0

      do { next.wakeStatistics = try self.probe.wakeStatistics() } catch {
        errors.append(error.localizedDescription)
      }
      do { next.profiles = try self.probe.powerProfiles() } catch {
        errors.append(error.localizedDescription)
      }
      do {
        // One pass over the log yields both; two calls meant two 25 MB reads.
        let reading = try self.probe.wakeLog()
        try self.historyStore.merge(reading.events)
        let history = try self.historyStore.load()
        next.events = history.events
        next.dailySummaries = history.dailySummaries
        next.scheduledWakes = reading.scheduled
        clearedAt = history.clearedAt
        hiddenCount = history.hiddenEventCount
      } catch { errors.append(error.localizedDescription) }
      // Assertions are cheap and current; a failure here must not blank the history.
      do { next.assertions = try self.probe.sleepAssertions() } catch {
        errors.append(error.localizedDescription)
      }
      next.refreshedAt = Date()
      next.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")

      DispatchQueue.main.async {
        // Clear the in-flight state before the staleness check. Returning early with
        // it still set would wedge the service: nothing else ever clears it, so every
        // later refresh would queue behind a run that had already finished.
        self.isRefreshing = false
        self.refreshInFlight = false
        defer { self.runPendingRefreshIfNeeded() }
        guard requestGeneration == self.generation else { return }
        self.historyFileSizeBytes = self.historyStore.fileSizeBytes
        self.migrationDroppedRecords = self.historyStore.migrationDroppedRecords
        self.clearedAt = clearedAt
        self.hiddenEventCount = hiddenCount
        self.snapshot = next
        self.darkWakeHistoryHandler?(next.events)
      }
    }
  }

  /// Brings back everything a previous clear hid.
  func restoreHistory() {
    queue.async { [weak self] in
      guard let self else { return }
      try? self.historyStore.restore()
      DispatchQueue.main.async { self.refresh() }
    }
  }

  func clearHistory() {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        try self.historyStore.clear()
        // Read back rather than assume. These counts drive the "show them again"
        // affordance, and publishing them here is what makes the clear look undoable
        // at the moment it happens rather than only after the next refresh.
        let history = try? self.historyStore.load()
        DispatchQueue.main.async {
          self.snapshot.events = []
          self.snapshot.dailySummaries = []
          self.clearedAt = history?.clearedAt
          self.hiddenEventCount = history?.hiddenEventCount ?? 0
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
          guard self.activationCount > 0, self.batteryGeneration == requestGeneration else {
            return
          }
          self.battery = battery
          self.finishBatteryRefresh()
        }
      } catch {
        DispatchQueue.main.async {
          guard self.activationCount > 0, self.batteryGeneration == requestGeneration else {
            return
          }
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
