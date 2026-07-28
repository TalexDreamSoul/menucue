import Foundation

public struct PowerHelperCapabilities: OptionSet, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static let systemTimeZone = PowerHelperCapabilities(rawValue: 1 << 0)
}

public enum PowerHelperProtocolInfo {
  public static let currentVersion = 2
  public static let currentCapabilities: PowerHelperCapabilities = [.systemTimeZone]
}

public enum SystemTimeZoneCommand {
  public static let executablePath = "/usr/sbin/systemsetup"

  public static func arguments(for identifier: String) -> [String]? {
    guard TimeZone(identifier: identifier) != nil,
      TimeZone.knownTimeZoneIdentifiers.contains(identifier)
    else {
      return nil
    }
    return ["-settimezone", identifier]
  }

  public static func observedIdentifier(from output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: ":", maxSplits: 1)
      guard fields.count == 2,
        fields[0].trimmingCharacters(in: .whitespacesAndNewlines) == "Time Zone"
      else {
        continue
      }
      let identifier = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !identifier.isEmpty, TimeZone(identifier: identifier) != nil else { return nil }
      return identifier
    }
    return nil
  }

  public static func matches(requestedIdentifier: String, observedOutput: String) -> Bool {
    observedIdentifier(from: observedOutput) == requestedIdentifier
  }
}

public enum PowerHelperConstants {
  public static let daemonLabel = "com.tagzxia.app.menucue.helper"
  public static let daemonPlistName = "com.tagzxia.app.menucue.helper.plist"
  public static let machServiceName = "com.tagzxia.app.menucue.helper"
  public static let mainAppBundleIdentifier = "com.tagzxia.app.menucue"
  public static let mainExecutableName = "MenuCue"
}

@objc public protocol PowerHelperProtocol {
  func queryProtocolInfo(
    reply: @escaping (Int, UInt64) -> Void
  )

  func queryPowerState(
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  )

  func setLowPowerMode(
    _ enabled: Bool,
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  )

  func setSleepDisabled(
    _ enabled: Bool,
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  )

  func querySystemTimeZone(
    reply: @escaping (Bool, String?, String?) -> Void
  )

  func setSystemTimeZone(
    _ identifier: String,
    reply: @escaping (Bool, String?, String?) -> Void
  )

  func prepareForRemoval(
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  )
}
