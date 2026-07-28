import Combine
import Foundation

final class ProcessEnergyService: ObservableObject {
  enum ViewMode: String, CaseIterable { case apps, processes }

  @Published private(set) var entries: [ProcessEnergyEntry] = []
  @Published private(set) var groups: [ProcessEnergyGroup] = []
  @Published private(set) var sampledAt: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var errorMessage: String?
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

  init(
    probe: ProcessEnergyProbing = SystemProcessEnergyProbe(),
    refreshInterval: TimeInterval = 15,
    now: @escaping () -> Date = Date.init
  ) {
    self.probe = probe
    self.refreshInterval = max(0.001, refreshInterval)
    self.now = now
  }

  deinit { timer?.invalidate() }

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
