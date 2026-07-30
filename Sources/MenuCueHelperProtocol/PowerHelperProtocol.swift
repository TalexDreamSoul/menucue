import Darwin
import Foundation

public struct PowerHelperCapabilities: OptionSet, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static let systemTimeZone = PowerHelperCapabilities(rawValue: 1 << 0)
  public static let managedPowerSettings = PowerHelperCapabilities(rawValue: 1 << 1)
  public static let processControl = PowerHelperCapabilities(rawValue: 1 << 2)
}

public enum PowerHelperProtocolInfo {
  public static let currentVersion = 3
  public static let currentCapabilities: PowerHelperCapabilities = [
    .systemTimeZone,
    .managedPowerSettings,
    .processControl,
  ]
}

public enum ManagedPowerSetting: Int, CaseIterable, Sendable {
  case powerNap
  case wakeOnNetwork
  case standby
  case tcpKeepalive

  public var pmsetKey: String {
    switch self {
    case .powerNap: return "powernap"
    case .wakeOnNetwork: return "womp"
    case .standby: return "standby"
    case .tcpKeepalive: return "tcpkeepalive"
    }
  }
}

public enum ManagedPowerSource: Int, CaseIterable, Sendable {
  case battery
  case ac
  case all

  public var pmsetFlag: String {
    switch self {
    case .battery: return "-b"
    case .ac: return "-c"
    case .all: return "-a"
    }
  }

  public var profileHeader: String? {
    switch self {
    case .battery: return "Battery Power:"
    case .ac: return "AC Power:"
    case .all: return nil
    }
  }
}

public enum ProcessControlCommand {
  public static func startTimeMicroseconds(_ startTime: TimeInterval) -> Int64 {
    Int64((startTime * 1_000_000).rounded())
  }

  public static func relativeNiceTarget(current: Int, delta: Int) -> Int? {
    guard delta == -1 || delta == 1 else { return nil }
    let target = current + delta
    guard (-20...19).contains(target) else { return nil }
    return target
  }
}

public enum ManagedPowerSettingCommand {
  private static let profileHeaders = ["Battery Power:", "AC Power:", "UPS Power:"]

  public static func arguments(
    settingRawValue: Int,
    sourceRawValue: Int,
    enabled: Bool
  ) -> [String]? {
    guard let setting = ManagedPowerSetting(rawValue: settingRawValue),
      let source = ManagedPowerSource(rawValue: sourceRawValue)
    else { return nil }
    return [source.pmsetFlag, setting.pmsetKey, enabled ? "1" : "0"]
  }

  public static func observedValueMatches(
    settingRawValue: Int,
    sourceRawValue: Int,
    enabled: Bool,
    customOutput: String
  ) -> Bool {
    guard let setting = ManagedPowerSetting(rawValue: settingRawValue),
      let source = ManagedPowerSource(rawValue: sourceRawValue)
    else { return false }
    let expected = enabled ? 1 : 0
    switch source {
    case .battery, .ac:
      guard let header = source.profileHeader, customOutput.contains(header) else { return false }
      return value(for: setting.pmsetKey, in: customOutput, section: header) == expected
    case .all:
      let presentHeaders = profileHeaders.filter { customOutput.contains($0) }
      guard !presentHeaders.isEmpty else { return false }
      return presentHeaders.allSatisfy {
        value(for: setting.pmsetKey, in: customOutput, section: $0) == expected
      }
    }
  }

  private static func value(for key: String, in output: String, section: String) -> Int? {
    var active = false
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if profileHeaders.contains(line) {
        active = line == section
        continue
      }
      guard active else { continue }
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.count >= 2, fields[0] == Substring(key), let value = Int(fields[1]) {
        return value
      }
    }
    return nil
  }
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

public enum PowerHelperExecutableLocation {
  public static func currentExecutableURL() -> URL? {
    var bufferSize: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &bufferSize)
    var buffer = [CChar](repeating: 0, count: Int(bufferSize))
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
      _NSGetExecutablePath(pointer.baseAddress, &bufferSize)
    }
    guard result == 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
  }
}

public enum PowerHelperConstants {
  public static let daemonLabel = "com.tagzxia.app.menucue.helper"
  public static let daemonPlistName = "com.tagzxia.app.menucue.helper.plist"
  public static let machServiceName = "com.tagzxia.app.menucue.helper"
  public static let mainAppBundleIdentifier = "com.tagzxia.app.menucue"
  public static let mainExecutableName = "MenuCue"

  public static func mainExecutableURL(forHelperExecutable helperURL: URL) -> URL {
    helperURL
      .deletingLastPathComponent()
      .appendingPathComponent(mainExecutableName)
  }
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

  func setManagedPowerSetting(
    _ settingRawValue: Int,
    sourceRawValue: Int,
    enabled: Bool,
    reply: @escaping (Bool, String?) -> Void
  )

  func terminateProcess(
    _ pid: Int32,
    startTimeMicroseconds: Int64,
    ownerUID: UInt32,
    executablePath: String,
    reply: @escaping (Bool, String?) -> Void
  )

  func reniceProcess(
    _ pid: Int32,
    startTimeMicroseconds: Int64,
    ownerUID: UInt32,
    executablePath: String,
    delta: Int,
    reply: @escaping (Bool, Int, String?) -> Void
  )

  func prepareForRemoval(
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  )
}
