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

  deinit {
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
        let events = try self.probe.wakeEvents()
        try self.historyStore.merge(events)
        let history = try self.historyStore.load()
        next.events = history.events
        next.dailySummaries = history.dailySummaries
      } catch { errors.append(error.localizedDescription) }
      // Assertions are cheap and current; a failure here must not blank the history.
      do { next.assertions = try self.probe.sleepAssertions() }
      catch { errors.append(error.localizedDescription) }
      do { next.scheduledWakes = try self.probe.scheduledWakes() }
      catch { errors.append(error.localizedDescription) }
      next.refreshedAt = Date()
      next.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")

      DispatchQueue.main.async {
        guard requestGeneration == self.generation else { return }
        self.snapshot = next
        self.isRefreshing = false
        self.refreshInFlight = false
        if self.refreshPending { self.refresh() }
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
