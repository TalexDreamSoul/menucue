import Darwin
import Foundation
import Security
import MenuCueHelperProtocol

private struct PowerState {
  let lowPowerEnabled: Bool
  let sleepDisabled: Bool
}

private struct ProcessResult {
  let status: Int32
  let output: String
  let error: String
}

private enum HelperError: LocalizedError {
  case notRoot
  case unsupportedPowerMode
  case invalidTimeZone(String)
  case invalidManagedPowerSetting
  case staleProcess
  case invalidNiceDelta
  case timeZoneMismatch(expected: String, observed: String?)
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .notRoot:
      return "MenuCueHelper must run as a root LaunchDaemon."
    case .unsupportedPowerMode:
      return "This Mac does not expose a supported Low Power Mode pmset key."
    case .invalidTimeZone(let identifier):
      return "Unsupported system time zone: \(identifier)"
    case .invalidManagedPowerSetting:
      return "Unsupported power setting or power source."
    case .staleProcess:
      return "The process identity changed before the action could run."
    case .invalidNiceDelta:
      return "The priority adjustment must be between -1 and 1."
    case .timeZoneMismatch(let expected, let observed):
      return "Expected system time zone \(expected), observed \(observed ?? "unknown")."
    case .commandFailed(let message):
      return message
    }
  }
}

private enum HelperPreferenceKey {
  static let managesSleepDisabled = "managesSleepDisabled"
  static let previousSleepDisabled = "previousSleepDisabled"
}

private final class PowerHelperService: NSObject, PowerHelperProtocol {
  private let defaults =
    UserDefaults(suiteName: PowerHelperConstants.daemonLabel) ?? .standard

  func queryProtocolInfo(reply: @escaping (Int, UInt64) -> Void) {
    reply(
      PowerHelperProtocolInfo.currentVersion,
      PowerHelperProtocolInfo.currentCapabilities.rawValue
    )
  }

  func queryPowerState(
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  ) {
    respond(reply: reply) {
      try self.queryState()
    }
  }

  func setLowPowerMode(
    _ enabled: Bool,
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  ) {
    respond(reply: reply) {
      let custom = try self.runPMSet(["-g", "custom"]).output
      let key = try self.powerModeKey(from: custom)
      _ = try self.runPMSet(["-a", key, enabled ? "1" : "0"])
      return try self.queryState()
    }
  }

  func setSleepDisabled(
    _ enabled: Bool,
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  ) {
    respond(reply: reply) {
      if enabled {
        let currentState = try self.queryState()
        if !self.defaults.bool(forKey: HelperPreferenceKey.managesSleepDisabled) {
          self.defaults.set(
            currentState.sleepDisabled,
            forKey: HelperPreferenceKey.previousSleepDisabled
          )
          self.defaults.set(true, forKey: HelperPreferenceKey.managesSleepDisabled)
        }
        _ = try self.runPMSet(["-a", "disablesleep", "1"])
      } else {
        _ = try self.runPMSet(["-a", "disablesleep", "0"])
        self.clearManagedSleepState()
      }
      return try self.queryState()
    }
  }

  func querySystemTimeZone(
    reply: @escaping (Bool, String?, String?) -> Void
  ) {
    do {
      guard getuid() == 0 else { throw HelperError.notRoot }
      let output = try runSystemSetup(["-gettimezone"]).output
      guard let identifier = SystemTimeZoneCommand.observedIdentifier(from: output) else {
        throw HelperError.commandFailed("systemsetup returned an unreadable time zone.")
      }
      reply(true, identifier, nil)
    } catch {
      reply(false, nil, error.localizedDescription)
    }
  }

  func setSystemTimeZone(
    _ identifier: String,
    reply: @escaping (Bool, String?, String?) -> Void
  ) {
    do {
      guard getuid() == 0 else { throw HelperError.notRoot }
      guard let arguments = SystemTimeZoneCommand.arguments(for: identifier) else {
        throw HelperError.invalidTimeZone(identifier)
      }
      _ = try runSystemSetup(arguments)
      let output = try runSystemSetup(["-gettimezone"]).output
      let observed = SystemTimeZoneCommand.observedIdentifier(from: output)
      guard observed == identifier else {
        throw HelperError.timeZoneMismatch(expected: identifier, observed: observed)
      }
      reply(true, observed, nil)
    } catch {
      let observed = try? observedSystemTimeZone()
      reply(false, observed, error.localizedDescription)
    }
  }

  func setManagedPowerSetting(
    _ settingRawValue: Int,
    sourceRawValue: Int,
    enabled: Bool,
    reply: @escaping (Bool, String?) -> Void
  ) {
    do {
      guard getuid() == 0 else { throw HelperError.notRoot }
      guard let setting = ManagedPowerSetting(rawValue: settingRawValue),
        let source = ManagedPowerSource(rawValue: sourceRawValue),
        let arguments = ManagedPowerSettingCommand.arguments(
          settingRawValue: settingRawValue,
          sourceRawValue: sourceRawValue,
          enabled: enabled)
      else { throw HelperError.invalidManagedPowerSetting }

      _ = try runPMSet(arguments)
      let observed = try runPMSet(["-g", "custom"]).output
      guard ManagedPowerSettingCommand.observedValueMatches(
        settingRawValue: setting.rawValue,
        sourceRawValue: source.rawValue,
        enabled: enabled,
        customOutput: observed)
      else {
        throw HelperError.commandFailed("pmset did not retain the requested power setting.")
      }
      reply(true, nil)
    } catch {
      reply(false, error.localizedDescription)
    }
  }

  func terminateProcess(
    _ pid: Int32,
    startTimeMicroseconds: Int64,
    ownerUID: UInt32,
    executablePath: String,
    reply: @escaping (Bool, String?) -> Void
  ) {
    do {
      guard getuid() == 0 else { throw HelperError.notRoot }
      try validateProcess(
        pid: pid,
        startTimeMicroseconds: startTimeMicroseconds,
        ownerUID: ownerUID,
        executablePath: executablePath)
      guard Darwin.kill(pid, SIGTERM) == 0 else {
        throw HelperError.commandFailed(String(cString: strerror(errno)))
      }
      reply(true, nil)
    } catch {
      reply(false, error.localizedDescription)
    }
  }

  func reniceProcess(
    _ pid: Int32,
    startTimeMicroseconds: Int64,
    ownerUID: UInt32,
    executablePath: String,
    delta: Int,
    reply: @escaping (Bool, Int, String?) -> Void
  ) {
    do {
      guard getuid() == 0 else { throw HelperError.notRoot }
      try validateProcess(
        pid: pid,
        startTimeMicroseconds: startTimeMicroseconds,
        ownerUID: ownerUID,
        executablePath: executablePath)
      errno = 0
      let current = getpriority(PRIO_PROCESS, UInt32(pid))
      guard errno == 0 else { throw HelperError.commandFailed(String(cString: strerror(errno))) }
      guard let target = ProcessControlCommand.relativeNiceTarget(
        current: Int(current), delta: delta)
      else { throw HelperError.invalidNiceDelta }
      guard setpriority(PRIO_PROCESS, UInt32(pid), Int32(target)) == 0 else {
        throw HelperError.commandFailed(String(cString: strerror(errno)))
      }
      errno = 0
      let observed = getpriority(PRIO_PROCESS, UInt32(pid))
      guard errno == 0 else { throw HelperError.commandFailed(String(cString: strerror(errno))) }
      guard Int(observed) == target else {
        throw HelperError.commandFailed("renice did not retain the requested priority.")
      }
      reply(true, target, nil)
    } catch {
      reply(false, 0, error.localizedDescription)
    }
  }

  func prepareForRemoval(
    reply: @escaping (Bool, Bool, Bool, String?) -> Void
  ) {
    respond(reply: reply) {
      if self.defaults.bool(forKey: HelperPreferenceKey.managesSleepDisabled) {
        let previousValue = self.defaults.bool(
          forKey: HelperPreferenceKey.previousSleepDisabled
        )
        _ = try self.runPMSet([
          "-a", "disablesleep", previousValue ? "1" : "0",
        ])
        self.clearManagedSleepState()
      }
      return try self.queryState()
    }
  }

  private func respond(
    reply: @escaping (Bool, Bool, Bool, String?) -> Void,
    operation: () throws -> PowerState
  ) {
    do {
      guard getuid() == 0 else { throw HelperError.notRoot }
      let state = try operation()
      reply(true, state.lowPowerEnabled, state.sleepDisabled, nil)
    } catch {
      let fallback = try? queryState()
      reply(
        false,
        fallback?.lowPowerEnabled ?? false,
        fallback?.sleepDisabled ?? false,
        error.localizedDescription
      )
    }
  }

  private func validateProcess(
    pid: Int32,
    startTimeMicroseconds: Int64,
    ownerUID: UInt32,
    executablePath: String
  ) throws {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      throw HelperError.staleProcess
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
      throw HelperError.staleProcess
    }
    let observedMicroseconds = Int64(info.pbi_start_tvsec) * 1_000_000
      + Int64(info.pbi_start_tvusec)
    guard observedMicroseconds == startTimeMicroseconds,
      info.pbi_uid == ownerUID,
      String(cString: path) == executablePath
    else { throw HelperError.staleProcess }
  }

  private func clearManagedSleepState() {
    defaults.removeObject(forKey: HelperPreferenceKey.managesSleepDisabled)
    defaults.removeObject(forKey: HelperPreferenceKey.previousSleepDisabled)
  }

  private func queryState() throws -> PowerState {
    let custom = try runPMSet(["-g", "custom"]).output
    let powerSource = try runPMSet(["-g", "ps"]).output
    let system = try runPMSet(["-g"]).output
    let key = try powerModeKey(from: custom)
    let sourceHeader =
      powerSource.localizedCaseInsensitiveContains("Battery Power")
      ? "Battery Power:" : "AC Power:"
    let currentMode =
      value(for: key, in: custom, section: sourceHeader)
      ?? firstValue(for: key, in: custom)
      ?? 0
    let sleepDisabled = firstValue(for: "SleepDisabled", in: system) == 1

    return PowerState(
      lowPowerEnabled: currentMode == 1,
      sleepDisabled: sleepDisabled
    )
  }

  private func powerModeKey(from output: String) throws -> String {
    if firstValue(for: "powermode", in: output) != nil {
      return "powermode"
    }
    if firstValue(for: "lowpowermode", in: output) != nil {
      return "lowpowermode"
    }
    throw HelperError.unsupportedPowerMode
  }

  private func value(for key: String, in output: String, section: String) -> Int? {
    var isInSection = false
    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasSuffix("Power:") {
        isInSection = trimmed == section
        continue
      }
      if isInSection, let value = parsedValue(for: key, line: trimmed) {
        return value
      }
    }
    return nil
  }

  private func firstValue(for key: String, in output: String) -> Int? {
    for line in output.split(whereSeparator: \.isNewline) {
      if let value = parsedValue(for: key, line: String(line)) {
        return value
      }
    }
    return nil
  }

  private func parsedValue(for key: String, line: String) -> Int? {
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2 else { return nil }
    guard fields[0].caseInsensitiveCompare(key) == .orderedSame else { return nil }
    return Int(fields[1])
  }

  private func observedSystemTimeZone() throws -> String {
    let output = try runSystemSetup(["-gettimezone"]).output
    guard let identifier = SystemTimeZoneCommand.observedIdentifier(from: output) else {
      throw HelperError.commandFailed("systemsetup returned an unreadable time zone.")
    }
    return identifier
  }

  private func runPMSet(_ arguments: [String]) throws -> ProcessResult {
    try runProcess(executablePath: "/usr/bin/pmset", arguments: arguments)
  }

  private func runSystemSetup(_ arguments: [String]) throws -> ProcessResult {
    try runProcess(executablePath: SystemTimeZoneCommand.executablePath, arguments: arguments)
  }

  private func runProcess(executablePath: String, arguments: [String]) throws -> ProcessResult {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()

    let group = DispatchGroup()
    let lock = NSLock()
    var outputData = Data()
    var errorData = Data()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
      lock.lock(); outputData = data; lock.unlock()
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      lock.lock(); errorData = data; lock.unlock()
      group.leave()
    }
    process.waitUntilExit()
    group.wait()
    lock.lock()
    let capturedOutput = outputData
    let capturedError = errorData
    lock.unlock()

    let result = ProcessResult(
      status: process.terminationStatus,
      output: String(decoding: capturedOutput, as: UTF8.self),
      error: String(decoding: capturedError, as: UTF8.self)
    )
    guard result.status == 0 else {
      let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
      let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
      throw HelperError.commandFailed(
        message.isEmpty ? "\(executableName) failed with status \(result.status)." : message
      )
    }
    return result
  }
}

private final class PowerHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
  private struct ClientRequirement {
    let codeRequirement: SecRequirement
    let teamIdentifier: String?
  }

  private let expectedClientRequirement: ClientRequirement?

  override init() {
    self.expectedClientRequirement = Self.loadExpectedClientRequirement()
    super.init()
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    guard let expectedClientRequirement else {
      NSLog("MenuCueHelper rejected XPC connection: missing client requirement")
      return false
    }
    guard Self.validate(connection: connection, expected: expectedClientRequirement) else {
      NSLog(
        "MenuCueHelper rejected unauthorized XPC client pid %d",
        connection.processIdentifier
      )
      return false
    }

    connection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
    connection.exportedObject = PowerHelperService()
    connection.invalidationHandler = {
      NSLog("MenuCueHelper XPC connection invalidated")
    }
    connection.interruptionHandler = {
      NSLog("MenuCueHelper XPC connection interrupted")
    }
    connection.resume()
    return true
  }

  private static func loadExpectedClientRequirement() -> ClientRequirement? {
    let helperURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let contentsURL =
      helperURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let mainExecutableURL =
      contentsURL
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent(PowerHelperConstants.mainExecutableName)

    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(mainExecutableURL as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }

    var signingInfo: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
      let info = signingInfo as? [String: Any],
      info[kSecCodeInfoIdentifier as String] as? String == PowerHelperConstants.mainAppBundleIdentifier
    else { return nil }
    let appTeamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String

    var helperCode: SecStaticCode?
    var helperSigningInfo: CFDictionary?
    guard SecStaticCodeCreateWithPath(helperURL as CFURL, [], &helperCode) == errSecSuccess,
      let helperCode,
      SecCodeCopySigningInformation(
        helperCode, SecCSFlags(rawValue: kSecCSSigningInformation), &helperSigningInfo) == errSecSuccess
    else { return nil }
    let helperTeamIdentifier = (helperSigningInfo as? [String: Any])?[
      kSecCodeInfoTeamIdentifier as String] as? String
    if let helperTeamIdentifier, appTeamIdentifier != helperTeamIdentifier { return nil }

    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
      let requirement
    else { return nil }
    return ClientRequirement(
      codeRequirement: requirement,
      teamIdentifier: helperTeamIdentifier ?? appTeamIdentifier)
  }

  private static func validate(
    connection: NSXPCConnection,
    expected: ClientRequirement
  ) -> Bool {
    let attributes =
      [
        kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
      ] as CFDictionary
    var guestCode: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
      let guestCode
    else {
      return false
    }
    guard SecCodeCheckValidity(guestCode, [], expected.codeRequirement) == errSecSuccess else {
      return false
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(connection.processIdentifier, &path, UInt32(path.count)) > 0 else {
      return false
    }
    let guestURL = URL(fileURLWithPath: String(cString: path))
    var staticGuestCode: SecStaticCode?
    var signingInfo: CFDictionary?
    guard SecStaticCodeCreateWithPath(guestURL as CFURL, [], &staticGuestCode) == errSecSuccess,
      let staticGuestCode,
      SecCodeCopySigningInformation(
        staticGuestCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
      let info = signingInfo as? [String: Any],
      info[kSecCodeInfoIdentifier as String] as? String == PowerHelperConstants.mainAppBundleIdentifier
    else { return false }
    guard let expectedTeam = expected.teamIdentifier else { return true }
    return info[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeam
  }
}

private let delegate = PowerHelperListenerDelegate()
private let listener = NSXPCListener(
  machServiceName: PowerHelperConstants.machServiceName
)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
