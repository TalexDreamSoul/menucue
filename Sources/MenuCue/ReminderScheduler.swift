import AppKit
import Foundation
import IOKit

/// Drives local-time reminders and feeds them into the same durable notification outbox as
/// metric alerts. The scheduler itself is deliberately small: the outbox owns retries and
/// channels, while this type owns only recurrence and once-per-occurrence state.
final class ReminderScheduler: @unchecked Sendable {
  private struct Runtime: Codable {
    var lastFired: [String: Date] = [:]
    var anchors: [String: Date] = [:]
    // Optional keeps runtime.v1 readable; a civil-day high-water mark prevents replay
    // when changing the anchor zone moves the clock back across the date line.
    var lastFiredDay: [String: String]?
  }

  private let store: NotificationRuntimeStore
  private let dispatcher: NotificationDeliveryDispatcher
  private let defaults: UserDefaults
  private let now: () -> Date
  private let isClamshellClosed: () -> Bool
  private var calendar: Calendar
  private var settings = NotificationSettings.default
  private var deviceName = "Mac"
  private var runtime: Runtime
  private var timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var pendingEnqueues: [UUID: (
    task: Task<Void, Never>, ruleID: UUID, occurrence: Date, day: String
  )] = [:]
  private var distributedObservers: [NSObjectProtocol] = []

  init(
    store: NotificationRuntimeStore,
    dispatcher: NotificationDeliveryDispatcher,
    defaults: UserDefaults = .standard,
    now: @escaping () -> Date = { Date() },
    isClamshellClosed: @escaping () -> Bool = ReminderScheduler.readClamshellState
  ) {
    self.store = store
    self.dispatcher = dispatcher
    self.defaults = defaults
    self.now = now
    self.isClamshellClosed = isClamshellClosed
    self.calendar = Calendar(identifier: .gregorian)
    self.runtime = Self.loadRuntime(from: defaults)
  }

  func start(settings: NotificationSettings, deviceName: String, timeZone: TimeZone) {
    self.settings = settings
    self.deviceName = deviceName
    self.calendar.timeZone = timeZone
    installObserversIfNeeded()
    if timer == nil {
      let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
        self?.tick()
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
    tick()
  }

  func update(settings: NotificationSettings, deviceName: String, timeZone: TimeZone) {
    self.settings = settings
    self.deviceName = deviceName
    self.calendar.timeZone = timeZone
    tick()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    observers.removeAll()
    distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
    distributedObservers.removeAll()
  }

  private func installObserversIfNeeded() {
    guard observers.isEmpty else { return }
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.tick()
      })

    // A closed lid is followed by system sleep, so the sleep notification is the dependable
    // edge; the distributed notification covers clamshell mode, where the Mac keeps running.
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleLidStateChange()
      })

    distributedObservers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("AppleClamshellState"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleLidStateChange()
      })
  }

  private func tick() {
    guard settings.isGloballyEnabled else { return }
    let date = now()
    for rule in settings.reminders where rule.isEnabled {
      guard let occurrence = dueOccurrence(for: rule, at: date), canDeliver(rule) else { continue }
      enqueue(rule: rule, occurrence: occurrence, at: date)
    }
  }

  /// Fires lid-close reminders once per local day after each rule's `lidCloseAfterHour`.
  func handleLidStateChange() {
    guard settings.isGloballyEnabled, isClamshellClosed() else { return }
    let date = now()
    for rule in settings.reminders where rule.isEnabled {
      guard let afterHour = rule.lidCloseAfterHour,
        calendar.component(.hour, from: date) >= afterHour,
        canDeliver(rule),
        !wasFiredToday(rule, at: date)
      else { continue }
      enqueue(rule: rule, occurrence: date, at: date)
    }
  }

  private func dueOccurrence(for rule: ReminderRule, at date: Date) -> Date? {
    switch rule.schedule {
    case let .daily(hour, minute):
      let occurrence = calendar.date(
        bySettingHour: hour,
        minute: minute,
        second: 0,
        of: date,
        matchingPolicy: .nextTime,
        repeatedTimePolicy: .first
      )
      guard let occurrence, date >= occurrence,
        date.timeIntervalSince(occurrence) <= Self.catchUpWindow
      else { return nil }
      guard !wasFiredToday(rule, at: occurrence) else { return nil }
      return occurrence

    case let .everyDays(days):
      guard days > 0 else { return nil }
      let key = rule.id.uuidString
      if runtime.anchors[key] == nil {
        runtime.anchors[key] = date
        saveRuntime()
        return nil
      }
      let base = runtime.lastFired[key] ?? runtime.anchors[key]!
      guard let next = calendar.date(byAdding: .day, value: days, to: base), date >= next else {
        return nil
      }
      return next

    case let .everyHours(hours, startHour, endHour):
      guard hours > 0, startHour <= endHour,
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
      else { return nil }
      let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date)
      guard let start, date >= start else { return nil }
      var latest = start
      while let next = calendar.date(byAdding: .hour, value: hours, to: latest),
        next > latest,
        next < dayEnd,
        calendar.component(.hour, from: next) <= endHour,
        next <= date
      {
        latest = next
      }
      guard !wasFired(rule, at: latest) else { return nil }
      guard date.timeIntervalSince(latest) <= Self.catchUpWindow else { return nil }
      return latest
    }
  }

  private func enqueue(rule: ReminderRule, occurrence: Date, at date: Date) {
    let eventID = eventID(for: rule, occurrence: occurrence)
    let occurrenceDay = dayKey(for: occurrence)
    let message = NotificationMessage(
      eventID: eventID,
      deviceName: deviceName,
      ruleID: rule.id.uuidString,
      state: .alert,
      occurredAt: date,
      title: rule.title,
      body: rule.body,
      metric: nil
    )
    let channels = rule.channels.filter { settings.channel($0).isEnabled }
    guard !channels.isEmpty else { return }
    let taskID = UUID()
    let task = Task { [weak self, store, dispatcher] in
      do {
        try await store.enqueue(message: message, channels: channels)
        await dispatcher.kick()
        await self?.finishEnqueue(taskID: taskID, firing: (rule, occurrence, occurrenceDay))
      } catch {
        // A failed enqueue leaves the occurrence due so the next scheduler tick can retry it.
        await self?.finishEnqueue(taskID: taskID, firing: nil)
      }
    }
    pendingEnqueues[taskID] = (task, rule.id, occurrence, occurrenceDay)
  }

  @MainActor
  private func finishEnqueue(
    taskID: UUID,
    firing: (rule: ReminderRule, occurrence: Date, day: String)?
  ) {
    if let firing {
      markFired(rule: firing.rule, occurrence: firing.occurrence, day: firing.day)
      saveRuntime()
    }
    pendingEnqueues[taskID] = nil
  }

  /// Resolves once every enqueue started so far has reached the outbox and, on success,
  /// recorded its occurrence as fired. Call from the main actor.
  func settle() async {
    for pending in Array(pendingEnqueues.values) {
      await pending.task.value
    }
  }

  private func canDeliver(_ rule: ReminderRule) -> Bool {
    !rule.channels.filter { settings.channel($0).isEnabled }.isEmpty
  }

  private func markFired(rule: ReminderRule, occurrence: Date, day: String) {
    let key = rule.id.uuidString
    runtime.lastFired[key] = max(runtime.lastFired[key] ?? .distantPast, occurrence)
    if runtime.lastFiredDay == nil { runtime.lastFiredDay = [:] }
    let previousDay = runtime.lastFiredDay?[key] ?? ""
    runtime.lastFiredDay?[key] = max(previousDay, day)
  }

  private func wasFiredToday(_ rule: ReminderRule, at date: Date) -> Bool {
    let day = dayKey(for: date)
    if pendingEnqueues.values.contains(where: {
      $0.ruleID == rule.id
        && ($0.day >= day || calendar.isDate($0.occurrence, inSameDayAs: date))
    }) { return true }
    if let firedDay = runtime.lastFiredDay?[rule.id.uuidString], firedDay >= day {
      return true
    }
    guard let last = runtime.lastFired[rule.id.uuidString] else { return false }
    return calendar.isDate(last, inSameDayAs: date)
  }

  private func wasFired(_ rule: ReminderRule, at occurrence: Date) -> Bool {
    if pendingEnqueues.values.contains(where: {
      $0.ruleID == rule.id && $0.occurrence >= occurrence
    }) { return true }
    guard let last = runtime.lastFired[rule.id.uuidString] else { return false }
    return last >= occurrence
  }

  private func eventID(for rule: ReminderRule, occurrence: Date) -> String {
    switch rule.schedule {
    case .daily:
      return "reminder|\(rule.id.uuidString)|\(dayKey(for: occurrence))"
    case .everyDays, .everyHours:
      let stamp = Int(occurrence.timeIntervalSince1970)
      return "reminder|\(rule.id.uuidString)|\(stamp)"
    }
  }

  private func dayKey(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
  }

  private func saveRuntime() {
    guard let data = try? JSONEncoder().encode(runtime) else { return }
    defaults.set(data, forKey: Self.runtimeKey)
  }

  private static func loadRuntime(from defaults: UserDefaults) -> Runtime {
    guard let data = defaults.data(forKey: runtimeKey),
      let runtime = try? JSONDecoder().decode(Runtime.self, from: data)
    else { return Runtime() }
    return runtime
  }

  private static func readClamshellState() -> Bool {
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    let key = "AppleClamshellState" as CFString
    guard let value = IORegistryEntrySearchCFProperty(
      root,
      kIOServicePlane,
      key,
      kCFAllocatorDefault,
      IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    ) else { return false }
    return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
  }

  private static let runtimeKey = "reminderRuntime.v1"
  private static let catchUpWindow: TimeInterval = 2 * 60 * 60
}
