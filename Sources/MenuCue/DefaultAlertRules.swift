import Foundation

/// Conservative first-run monitoring. These rules cover the system-wide conditions MenuCue
/// already samples reliably; process attribution and hardware-arrival events stay out until
/// their own collectors can make the same identity guarantees.
enum DefaultAlertRules {
  static func systemNotifications() -> [AlertRule] {
    let channel: Set<NotificationChannelKind> = [.system]
    return [
      AlertRule(
        id: UUID(uuidString: "1A7160A7-58B7-4F3A-B21C-8E5E730E71F1")!,
        name: L10n.string("CPU usage"),
        metricID: "cpu.total.busy",
        condition: .numeric(operator: .above, threshold: 0.9),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.75,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "9CE2D201-D7CF-4AC3-AE2C-1264A4C28491")!,
        name: L10n.string("memory.pressure"),
        metricID: "memory.pressure",
        condition: .severity(operator: .atLeast, threshold: 2),
        alertDuration: 30,
        recoveryDuration: 60,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "6F3393A9-DCC5-48D5-B2C3-594B1E3BE7BA")!,
        name: L10n.string("swap.used.percent"),
        metricID: "swap.used.percent",
        condition: .numeric(operator: .above, threshold: 0.2),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.1,
        cooldown: 900,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "6B12A659-3848-4422-8693-6E78552A7E5A")!,
        name: L10n.string("storage.volume.usedPercent"),
        metricID: "storage.volume.usedPercent",
        targetID: "/",
        condition: .numeric(operator: .above, threshold: 0.9),
        alertDuration: 60,
        recoveryDuration: 120,
        recoveryThreshold: 0.85,
        cooldown: 1_800,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "8D6DBBE3-BA60-4C0D-9FBB-EEF33C3B00B7")!,
        name: L10n.string("event.darkWake"),
        metricID: "event.darkWake",
        condition: .event,
        cooldown: 900,
        channels: channel
      ),
    ]
  }
}
