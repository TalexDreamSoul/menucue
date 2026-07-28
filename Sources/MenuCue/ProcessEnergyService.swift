import Combine
import Foundation

final class ProcessEnergyService: ObservableObject {
  enum ViewMode: String, CaseIterable { case apps, processes }

  @Published private(set) var entries: [ProcessEnergyEntry] = []
  @Published private(set) var groups: [ProcessEnergyGroup] = []
  @Published private(set) var sampledAt: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var errorMessage: String?
  /// What has been running over the retained window, as opposed to in this instant.
  @Published private(set) var history = ProcessEnergyHistory()
  @Published var viewMode: ViewMode = .apps

  private let probe: ProcessEnergyProbing
  private let refreshInterval: TimeInterval
  private let now: () -> Date
  private let queue = DispatchQueue(label: "com.tagzxia.app.menucue.process-energy", qos: .utility)
  private var timer: Timer?
  private var refreshInFlight = false
  private var refreshPending = false
  private var activationCount = 0
  private var generation = 0
  private var lastRefreshStartedAt: Date?

  private let historyStore: ProcessEnergyHistoryStore?
  private var backgroundTimer: Timer?

  init(
    probe: ProcessEnergyProbing = SystemProcessEnergyProbe(),
    refreshInterval: TimeInterval = 15,
    historyStore: ProcessEnergyHistoryStore? = .applicationStore(),
    now: @escaping () -> Date = Date.init
  ) {
    self.probe = probe
    self.refreshInterval = max(0.001, refreshInterval)
    self.historyStore = historyStore
    self.now = now
    if let historyStore, let restored = try? historyStore.load(now: now()) {
      history = restored
    }
  }

  /// Samples on a slow cadence with nothing on screen, so "what has been running" can
  /// be answered for a window rather than for the instant a tab was opened.
  ///
  /// Deliberately much slower than the foreground rate: this is about persistence, and
  /// a `top -l 2` costs about a second of wall clock each time.
  func startBackgroundSampling(interval: TimeInterval = 300) {
    guard backgroundTimer == nil else { return }
    sampleIntoHistory()
    // Deliberately not driven by `metricsSampling`: that setting is tuned for a
    // 1.5-second metrics poll and its intervals are the wrong order of magnitude
    // here. Low Power Mode is the one signal that clearly applies.
    let resolved = ProcessInfo.processInfo.isLowPowerModeEnabled
      ? max(900, interval * 3)
      : max(60, interval)
    let timer = Timer(timeInterval: resolved, repeats: true) { [weak self] _ in
      self?.sampleIntoHistory()
    }
    RunLoop.main.add(timer, forMode: .common)
    backgroundTimer = timer
  }

  func stopBackgroundSampling() {
    backgroundTimer?.invalidate()
    backgroundTimer = nil
  }

  /// One sample folded into the history, without disturbing the live readout.
  private func sampleIntoHistory() {
    let sampledAt = now()
    queue.async { [weak self] in
      guard let self else { return }
      guard let entries = try? self.probe.sample(limit: 20) else { return }
      DispatchQueue.main.async {
        self.history.record(entries, at: sampledAt)
        try? self.historyStore?.save(self.history)
      }
    }
  }

  func clearHistory() {
    history = ProcessEnergyHistory()
    try? historyStore?.clear()
  }

  deinit {
    timer?.invalidate()
    backgroundTimer?.invalidate()
  }

  func retain() {
    activationCount += 1
    guard activationCount == 1 else { return }
    generation += 1
    lastRefreshStartedAt = nil
    refresh()
  }

  func release() {
    activationCount = max(0, activationCount - 1)
    guard activationCount == 0 else { return }
    generation += 1
    timer?.invalidate()
    timer = nil
    refreshPending = false
    refreshInFlight = false
    lastRefreshStartedAt = nil
    isRefreshing = false
  }

  func refresh() {
    guard activationCount > 0 else { return }
    if refreshInFlight { refreshPending = true; return }
    let currentDate = now()
    if let lastRefreshStartedAt {
      let remaining = refreshInterval - currentDate.timeIntervalSince(lastRefreshStartedAt)
      if remaining > 0 {
        refreshPending = true
        // The work is deferred, but the request was accepted. Without this the Refresh
        // button did nothing visible for up to a full interval — it looked broken
        // rather than throttled.
        isRefreshing = true
        scheduleRefresh(after: remaining)
        return
      }
    }
    let refreshGeneration = generation
    lastRefreshStartedAt = currentDate
    scheduleRefresh(after: refreshInterval)
    refreshInFlight = true
    refreshPending = false
    isRefreshing = true
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let entries = try self.probe.sample(limit: 12)
        let groups = ProcessEnergyAggregator.groups(from: entries)
        DispatchQueue.main.async {
          guard self.activationCount > 0, self.generation == refreshGeneration else { return }
          // A foreground sample is as good a data point as a background one.
          self.history.record(entries, at: self.now())
          try? self.historyStore?.save(self.history)
          self.entries = entries
          self.groups = groups
          self.sampledAt = self.now()
          self.errorMessage = nil
          self.finishRefresh()
        }
      } catch {
        DispatchQueue.main.async {
          guard self.activationCount > 0, self.generation == refreshGeneration else { return }
          self.errorMessage = error.localizedDescription
          self.finishRefresh()
        }
      }
    }
  }

  func detail(for identity: ProcessIdentity, completion: @escaping (Result<ProcessDetail, Error>) -> Void) {
    queue.async { [probe] in
      let result = Result { try probe.detail(for: identity) }
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func scheduleRefresh(after delay: TimeInterval) {
    guard timer == nil, activationCount > 0 else { return }
    let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
      guard let self else { return }
      self.timer = nil
      self.refresh()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func finishRefresh() {
    isRefreshing = false
    refreshInFlight = false
    if refreshPending { refresh() }
  }
}
