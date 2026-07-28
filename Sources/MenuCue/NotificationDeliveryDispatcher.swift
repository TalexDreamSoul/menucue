import Foundation

actor NotificationDeliveryDispatcher {
  private let store: NotificationRuntimeStore
  private let configuration: NotificationConfigurationService
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  private var settings = NotificationSettings.default
  private var isDraining = false
  private var needsDrain = false
  private var retryTask: Task<Void, Never>?

  init(
    store: NotificationRuntimeStore,
    configuration: NotificationConfigurationService,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
      try await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000))
    }
  ) {
    self.store = store
    self.configuration = configuration
    self.now = now
    self.sleep = sleep
  }

  func update(settings: NotificationSettings) {
    self.settings = settings
  }

  func kick() {
    needsDrain = true
    retryTask?.cancel()
    retryTask = nil
    guard !isDraining else { return }
    isDraining = true
    Task { await drainLoop() }
  }

  private func drainLoop() async {
    while needsDrain {
      needsDrain = false
      let channels = configuration.makeEnabledChannels(settings: settings)
      let coordinator = NotificationDeliveryCoordinator(outbox: store, channels: channels, now: now)
      try? await coordinator.drainOnce()
    }
    isDraining = false
    scheduleNextRetry()
  }

  private func scheduleNextRetry() {
    retryTask?.cancel()
    retryTask = Task { [weak self] in
      guard let self else { return }
      let current = self.now()
      guard let next = await self.store.nextPendingDeliveryDate(now: current) else { return }
      do { try await self.sleep(max(1, next.timeIntervalSince(current))) } catch { return }
      await self.kick()
    }
  }
}
