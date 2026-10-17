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
        isEnabled: true,
        metricID: "cpu.total.busy",
        condition: .numeric(operator: .above, threshold: 0.9),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.75,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "B2E15C7A-932A-4B6A-9154-8B7C5A142D01")!,
        name: L10n.string("CPU User Busy"),
        isEnabled: true,
        metricID: "cpu.total.user",
        condition: .numeric(operator: .above, threshold: 0.85),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.70,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "C3F26D8B-A43B-5C7B-A265-9C8D6B253E12")!,
        name: L10n.string("CPU System Load"),
        isEnabled: false,
        metricID: "cpu.total.system",
        condition: .numeric(operator: .above, threshold: 0.50),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.35,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "D4A37E9C-B54C-6D8C-B376-AD9E7C364F23")!,
        name: L10n.string("CPU Load (1m)"),
        isEnabled: false,
        metricID: "cpu.load.1m",
        condition: .numeric(operator: .above, threshold: 12.0),
        alertDuration: 60,
        recoveryDuration: 60,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "E5B48F0D-C65D-7E9D-C487-BEAF8D475034")!,
        name: L10n.string("GPU Utilization"),
        isEnabled: true,
        metricID: "gpu.device.utilization",
        condition: .numeric(operator: .above, threshold: 0.90),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.75,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "F6C5901E-D76E-8FA0-D598-CFB09E586145")!,
        name: L10n.string("GPU Memory Usage"),
        isEnabled: false,
        metricID: "gpu.memory.inUse",
        condition: .numeric(operator: .above, threshold: 17_179_869_184),
        alertDuration: 60,
        recoveryDuration: 60,
        cooldown: 900,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "07D6A12F-E87F-90B1-E6A9-D0C1AF697256")!,
        name: L10n.string("Memory Usage"),
        isEnabled: true,
        metricID: "memory.used.percent",
        condition: .numeric(operator: .above, threshold: 0.90),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.80,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "9CE2D201-D7CF-4AC3-AE2C-1264A4C28491")!,
        name: L10n.string("memory.pressure"),
        isEnabled: true,
        metricID: "memory.pressure",
        condition: .severity(operator: .atLeast, threshold: 2),
        alertDuration: 30,
        recoveryDuration: 60,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "18E7B230-F980-A1C2-F7BA-E1D2B07A8367")!,
        name: L10n.string("App Memory Usage"),
        isEnabled: false,
        metricID: "memory.app",
        condition: .numeric(operator: .above, threshold: 21_474_836_480),
        alertDuration: 60,
        recoveryDuration: 60,
        cooldown: 900,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "6F3393A9-DCC5-48D5-B2C3-594B1E3BE7BA")!,
        name: L10n.string("swap.used.percent"),
        isEnabled: true,
        metricID: "swap.used.percent",
        condition: .numeric(operator: .above, threshold: 0.3),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 0.15,
        cooldown: 900,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "6B12A659-3848-4422-8693-6E78552A7E5A")!,
        name: L10n.string("storage.volume.usedPercent"),
        isEnabled: true,
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
        id: UUID(uuidString: "29F8C341-0A91-B2D3-08CB-F2E3C18B9478")!,
        name: L10n.string("Disk Critical Space"),
        isEnabled: true,
        metricID: "storage.volume.usedPercent",
        targetID: "/",
        condition: .numeric(operator: .above, threshold: 0.95),
        alertDuration: 30,
        recoveryDuration: 120,
        recoveryThreshold: 0.90,
        cooldown: 1_800,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "3A09D452-1BA2-C3E4-19DC-03F4D29CA589")!,
        name: L10n.string("Disk Write Rate"),
        isEnabled: false,
        metricID: "disk.write.rate",
        condition: .numeric(operator: .above, threshold: 157_286_400),
        alertDuration: 30,
        recoveryDuration: 60,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "4B1AE563-2CB3-D4F5-2AED-1405E3ADB69A")!,
        name: L10n.string("Disk Read Rate"),
        isEnabled: false,
        metricID: "disk.read.rate",
        condition: .numeric(operator: .above, threshold: 209_715_200),
        alertDuration: 30,
        recoveryDuration: 60,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "5C2BF674-3DC4-E506-3BFE-2516F4BEC7AB")!,
        name: L10n.string("High Download Traffic"),
        isEnabled: false,
        metricID: "network.download.rate",
        condition: .numeric(operator: .above, threshold: 31_457_280),
        alertDuration: 60,
        recoveryDuration: 60,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "6D3C0785-4ED5-F617-4C0F-362705CFD8BC")!,
        name: L10n.string("High Upload Traffic"),
        isEnabled: false,
        metricID: "network.upload.rate",
        condition: .numeric(operator: .above, threshold: 15_728_640),
        alertDuration: 60,
        recoveryDuration: 60,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "7E4D1896-5FE6-0728-5D10-473816D0E9CD")!,
        name: L10n.string("CPU High Temperature"),
        isEnabled: true,
        metricID: "sensor.cpu.temperature",
        condition: .numeric(operator: .above, threshold: 90),
        alertDuration: 45,
        recoveryDuration: 60,
        recoveryThreshold: 75,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "8F5E29A7-60F7-1839-6E21-584927E1FA0E")!,
        name: L10n.string("Thermal Alert"),
        isEnabled: true,
        metricID: "sensor.thermal.temperature",
        condition: .numeric(operator: .above, threshold: 85),
        alertDuration: 45,
        recoveryDuration: 60,
        recoveryThreshold: 70,
        cooldown: 600,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "906F3AB8-7108-294A-7F32-695A38F20B1F")!,
        name: L10n.string("Fan High Speed"),
        isEnabled: true,
        metricID: "fan.speed",
        condition: .numeric(operator: .above, threshold: 4500),
        alertDuration: 60,
        recoveryDuration: 60,
        recoveryThreshold: 3000,
        cooldown: 900,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "A1704BC9-8219-3A5B-8043-7A6B49031C20")!,
        name: L10n.string("Low Battery"),
        isEnabled: true,
        metricID: "battery.level",
        condition: .numeric(operator: .below, threshold: 0.20),
        alertDuration: 15,
        recoveryDuration: 30,
        recoveryThreshold: 0.25,
        cooldown: 1_800,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "B2815CD0-932A-4B6C-9154-8B7C5A142D31")!,
        name: L10n.string("Critical Battery"),
        isEnabled: true,
        metricID: "battery.level",
        condition: .numeric(operator: .below, threshold: 0.10),
        alertDuration: 10,
        recoveryDuration: 30,
        recoveryThreshold: 0.15,
        cooldown: 1_800,
        channels: channel
      ),
      AlertRule(
        id: UUID(uuidString: "8D6DBBE3-BA60-4C0D-9FBB-EEF33C3B00B7")!,
        name: L10n.string("event.darkWake"),
        isEnabled: true,
        metricID: "event.darkWake",
        condition: .event,
        cooldown: 900,
        channels: channel
      ),
    ]
  }
}
