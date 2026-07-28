import Combine
import Foundation
import ServiceManagement
import MenuCueHelperProtocol

enum PowerHelperRegistrationState: Equatable {
  case unavailable(String)
  case notRegistered
  case requiresApproval
  case refreshRequired
  case enabled
  case failed(String)

  var isEnabled: Bool {
    self == .enabled
  }

  var title: String {
    switch self {
    case .unavailable: return L10n.string("Unavailable")
    case .notRegistered: return L10n.string("Not Installed")
    case .requiresApproval: return L10n.string("Approval Required")
    case .refreshRequired: return L10n.string("Update Required")
    case .enabled: return L10n.string("Enabled")
    case .failed: return L10n.string("Error")
    }
  }

  var detail: String {
    switch self {
    case .unavailable(let reason), .failed(let reason):
      return L10n.format("%@", reason)
    case .notRegistered:
      return L10n.string("Install the privileged Helper to change protected power settings.")
    case .requiresApproval:
      return L10n.string(
        "Approve MenuCue in System Settings → General → Login Items & Extensions."
      )
    case .refreshRequired:
      return L10n.string("Refresh the installed Helper to match this MenuCue version.")
    case .enabled:
      return L10n.string("The Helper is approved and ready for protected power actions.")
    }
  }
}

private enum PowerHelperManagerError: LocalizedError {
  case unavailable(String)
  case connection(String)
  case operation(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let message), .connection(let message), .operation(let message):
      return L10n.format("%@", message)
    }
  }
}

final class PowerHelperManager: ObservableObject {
  private static let registeredHelperBuildKey = "powerHelper.registeredBuild"

  @Published private(set) var registrationState: PowerHelperRegistrationState
  @Published private(set) var lowPowerModeEnabled = false
  @Published private(set) var sleepDisabled = false
  @Published private(set) var helperProtocolVersion = 0
  @Published private(set) var helperCapabilities: PowerHelperCapabilities = []
  @Published private(set) var systemTimeZoneIdentifier: String?
  @Published private(set) var isWorking = false
  @Published private(set) var lastError: String?

  private let service: SMAppService
  private var connection: NSXPCConnection?
  private var requiresHelperRefresh = false
  private var registeredCurrentHelperInSession = false

  init(
    service: SMAppService = .daemon(
      plistName: PowerHelperConstants.daemonPlistName
    )
  ) {
    self.service = service
    self.registrationState = .notRegistered
    refreshStatus()
  }

  deinit {
    connection?.invalidate()
  }

  func refreshStatus() {
    guard isPackagedHelperAvailable else {
      registrationState = .unavailable(
        L10n.string("Run MenuCue from its packaged app bundle to install the power Helper.")
      )
      clearProtocolInfo()
      invalidateConnection()
      return
    }

    switch service.status {
    case .notRegistered:
      registrationState = .notRegistered
      clearProtocolInfo()
      invalidateConnection()
    case .requiresApproval:
      registrationState = .requiresApproval
      clearProtocolInfo()
      invalidateConnection()
    case .enabled:
      if shouldRefreshPackagedHelper {
        registrationState = .refreshRequired
        refreshHelperRegistration()
        return
      }
      guard !requiresHelperRefresh else {
        registrationState = .refreshRequired
        invalidateConnection()
        return
      }
      registrationState = .enabled
      queryProtocolInfo()
      queryState()
    case .notFound:
      registrationState = .unavailable(
        L10n.string("The packaged power Helper or LaunchDaemon configuration is missing.")
      )
      clearProtocolInfo()
      invalidateConnection()
    @unknown default:
      registrationState = .unavailable(L10n.string("macOS returned an unknown Helper status."))
      clearProtocolInfo()
      invalidateConnection()
    }
  }

  func requestRegistration() {
    guard isPackagedHelperAvailable else {
      refreshStatus()
      return
    }

    if service.status == .requiresApproval {
      openSystemSettings()
      refreshStatus()
      return
    }
    if service.status == .enabled {
      if requiresHelperRefresh {
        refreshHelperRegistration()
      } else {
        refreshStatus()
      }
      return
    }

    lastError = nil
    isWorking = true
    do {
      try service.register()
      registeredCurrentHelperInSession = true
      isWorking = false
      refreshStatus()
      if service.status == .requiresApproval {
        openSystemSettings()
      }
    } catch {
      isWorking = false
      let message = L10n.format("Power Helper registration failed: %@", error.localizedDescription)
      registrationState = .failed(message)
      lastError = message
    }
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func refreshHelperRegistration() {
    guard service.status == .enabled else {
      requiresHelperRefresh = false
      requestRegistration()
      return
    }

    isWorking = true
    do {
      try service.unregister()
      invalidateConnection()
      try service.register()
      requiresHelperRefresh = false
      registeredCurrentHelperInSession = true
      isWorking = false
      refreshStatus()
      if service.status == .requiresApproval {
        openSystemSettings()
      }
    } catch {
      isWorking = false
      let message = L10n.format("Power Helper refresh failed: %@", error.localizedDescription)
      registrationState = .failed(message)
      lastError = message
    }
  }

  var supportsSystemTimeZone: Bool {
    helperProtocolVersion >= 2 && helperCapabilities.contains(.systemTimeZone)
  }

  var supportsManagedPowerSettings: Bool {
    helperProtocolVersion >= 3 && helperCapabilities.contains(.managedPowerSettings)
  }

  var supportsProcessControl: Bool {
    helperProtocolVersion >= 3 && helperCapabilities.contains(.processControl)
  }

  func queryProtocolInfo() {
    guard registrationState.isEnabled else {
      clearProtocolInfo()
      return
    }
    let proxy = helperProxy { [weak self] _ in
      DispatchQueue.main.async {
        self?.markHelperRefreshRequired()
      }
    }
    guard let proxy else {
      clearProtocolInfo()
      return
    }
    proxy.queryProtocolInfo { [weak self] version, capabilitiesRawValue in
      DispatchQueue.main.async {
        guard let self else { return }
        self.requiresHelperRefresh = false
        self.registeredCurrentHelperInSession = true
        UserDefaults.standard.set(
          self.currentAppBuild,
          forKey: Self.registeredHelperBuildKey
        )
        self.helperProtocolVersion = version
        self.helperCapabilities = PowerHelperCapabilities(rawValue: capabilitiesRawValue)
        if self.supportsSystemTimeZone {
          self.querySystemTimeZone()
        }
      }
    }
  }

  func queryState(completion: ((Result<Void, Error>) -> Void)? = nil) {
    guard registrationState.isEnabled else {
      completion?(
        .failure(
          PowerHelperManagerError.unavailable(registrationState.detail)
        )
      )
      return
    }

    callHelper(completion: completion) { proxy, reply in
      proxy.queryPowerState(reply: reply)
    }
  }

  func setLowPowerMode(
    _ enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    callHelper(completion: completion) { proxy, reply in
      proxy.setLowPowerMode(enabled, reply: reply)
    }
  }

  func setSleepDisabled(
    _ enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    callHelper(completion: completion) { proxy, reply in
      proxy.setSleepDisabled(enabled, reply: reply)
    }
  }

  func querySystemTimeZone(completion: ((Result<String, Error>) -> Void)? = nil) {
    callTimeZoneHelper(completion: completion) { proxy, reply in
      proxy.querySystemTimeZone(reply: reply)
    }
  }

  func setSystemTimeZone(
    _ identifier: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard SystemTimeZoneCommand.arguments(for: identifier) != nil else {
      completion(
        .failure(
          PowerHelperManagerError.operation(
            L10n.format("Unsupported system time zone: %@", identifier)
          )
        )
      )
      return
    }
    callTimeZoneHelper(completion: completion) { proxy, reply in
      proxy.setSystemTimeZone(identifier, reply: reply)
    }
  }

  func setManagedPowerSetting(
    _ setting: ManagedPowerSetting,
    source: ManagedPowerSource,
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard supportsManagedPowerSettings else {
      completion(
        .failure(
          PowerHelperManagerError.unavailable(
            "The installed Helper must be refreshed before changing power profiles."
          )
        )
      )
      return
    }
    callSimpleHelper(completion: completion) { proxy, reply in
      proxy.setManagedPowerSetting(
        setting.rawValue,
        sourceRawValue: source.rawValue,
        enabled: enabled,
        reply: reply)
    }
  }

  func terminateProcess(
    _ identity: ProcessIdentity,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard supportsProcessControl else {
      completion(
        .failure(
          PowerHelperManagerError.unavailable(
            "The installed Helper must be refreshed before controlling processes."
          )
        )
      )
      return
    }
    callSimpleHelper(completion: completion) { proxy, reply in
      proxy.terminateProcess(
        identity.pid,
        startTimeMicroseconds: ProcessControlCommand.startTimeMicroseconds(identity.startTime),
        ownerUID: identity.ownerUID,
        executablePath: identity.executablePath,
        reply: reply)
    }
  }

  func reniceProcess(
    _ identity: ProcessIdentity,
    delta: Int,
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    guard registrationState.isEnabled, supportsProcessControl else {
      completion(.failure(PowerHelperManagerError.unavailable(registrationState.detail)))
      return
    }
    isWorking = true
    let proxy = helperProxy { [weak self] error in
      DispatchQueue.main.async {
        self?.isWorking = false
        completion(.failure(error))
      }
    }
    guard let proxy else {
      isWorking = false
      completion(.failure(PowerHelperManagerError.connection("Unable to connect to MenuCueHelper.")))
      return
    }
    proxy.reniceProcess(
      identity.pid,
      startTimeMicroseconds: ProcessControlCommand.startTimeMicroseconds(identity.startTime),
      ownerUID: identity.ownerUID,
      executablePath: identity.executablePath,
      delta: delta
    ) { [weak self] success, observed, message in
      DispatchQueue.main.async {
        self?.isWorking = false
        if success {
          completion(.success(observed))
        } else {
          completion(.failure(PowerHelperManagerError.operation(message ?? "renice failed.")))
        }
      }
    }
  }

  func removeHelper(completion: @escaping (Result<Void, Error>) -> Void) {
    if service.status == .requiresApproval || service.status == .notRegistered {
      unregister(completion: completion)
      return
    }

    guard registrationState.isEnabled else {
      completion(
        .failure(
          PowerHelperManagerError.unavailable(registrationState.detail)
        )
      )
      return
    }

    callHelper(completion: { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.unregister(completion: completion)
      case .failure:
        completion(result)
      }
    }) { proxy, reply in
      proxy.prepareForRemoval(reply: reply)
    }
  }

  private var currentAppBuild: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
  }

  private var shouldRefreshPackagedHelper: Bool {
    !registeredCurrentHelperInSession
      && UserDefaults.standard.string(forKey: Self.registeredHelperBuildKey) != currentAppBuild
  }

  private var isPackagedHelperAvailable: Bool {
    let bundleURL = Bundle.main.bundleURL
    let helperURL =
      bundleURL
      .appendingPathComponent("Contents/Library/HelperTools", isDirectory: true)
      .appendingPathComponent("MenuCueHelper")
    let plistURL =
      bundleURL
      .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
      .appendingPathComponent(PowerHelperConstants.daemonPlistName)
    return FileManager.default.isExecutableFile(atPath: helperURL.path)
      && FileManager.default.fileExists(atPath: plistURL.path)
  }

  private func unregister(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      try service.unregister()
      requiresHelperRefresh = false
      registeredCurrentHelperInSession = false
      UserDefaults.standard.removeObject(forKey: Self.registeredHelperBuildKey)
      clearProtocolInfo()
      invalidateConnection()
      refreshStatus()
      completion(.success(()))
    } catch {
      let message = L10n.format("Power Helper removal failed: %@", error.localizedDescription)
      let localizedError = PowerHelperManagerError.operation(message)
      registrationState = .failed(message)
      lastError = message
      completion(.failure(localizedError))
    }
  }

  private func callSimpleHelper(
    completion: @escaping (Result<Void, Error>) -> Void,
    invocation: (PowerHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
  ) {
    guard registrationState.isEnabled else {
      completion(.failure(PowerHelperManagerError.unavailable(registrationState.detail)))
      return
    }
    isWorking = true
    let proxy = helperProxy { [weak self] error in
      DispatchQueue.main.async {
        self?.isWorking = false
        completion(.failure(error))
      }
    }
    guard let proxy else {
      isWorking = false
      completion(.failure(PowerHelperManagerError.connection("Unable to connect to MenuCueHelper.")))
      return
    }
    invocation(proxy) { [weak self] success, message in
      DispatchQueue.main.async {
        self?.isWorking = false
        if success {
          completion(.success(()))
        } else {
          completion(.failure(PowerHelperManagerError.operation(message ?? "Helper operation failed.")))
        }
      }
    }
  }

  private func callHelper(
    completion: ((Result<Void, Error>) -> Void)?,
    invocation: (PowerHelperProtocol, @escaping (Bool, Bool, Bool, String?) -> Void) -> Void
  ) {
    guard registrationState.isEnabled else {
      completion?(
        .failure(
          PowerHelperManagerError.unavailable(registrationState.detail)
        )
      )
      return
    }

    isWorking = true
    let proxy = helperProxy { [weak self] error in
      DispatchQueue.main.async {
        let message = L10n.format(
          "Power Helper connection failed: %@",
          error.localizedDescription
        )
        let localizedError = PowerHelperManagerError.connection(message)
        self?.isWorking = false
        self?.lastError = message
        self?.invalidateConnection()
        completion?(.failure(localizedError))
      }
    }
    guard let proxy else {
      isWorking = false
      let error = PowerHelperManagerError.connection(
        L10n.string("Unable to connect to MenuCueHelper.")
      )
      lastError = L10n.format("%@", error.localizedDescription)
      completion?(.failure(error))
      return
    }

    invocation(proxy) { [weak self] success, lowPower, sleepDisabled, errorMessage in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isWorking = false
        self.lowPowerModeEnabled = lowPower
        self.sleepDisabled = sleepDisabled
        if success {
          self.registrationState = .enabled
          self.lastError = nil
          completion?(.success(()))
        } else {
          let error = PowerHelperManagerError.operation(
            Self.localizedHelperMessage(
              errorMessage,
              fallbackKey: "The power Helper operation failed."
            )
          )
          self.registrationState = .enabled
          self.lastError = L10n.format("%@", error.localizedDescription)
          completion?(.failure(error))
        }
      }
    }
  }

  private func callTimeZoneHelper(
    completion: ((Result<String, Error>) -> Void)?,
    invocation: (PowerHelperProtocol, @escaping (Bool, String?, String?) -> Void) -> Void
  ) {
    guard registrationState.isEnabled else {
      completion?(.failure(PowerHelperManagerError.unavailable(registrationState.detail)))
      return
    }
    guard supportsSystemTimeZone else {
      completion?(
        .failure(
          PowerHelperManagerError.unavailable(
            L10n.string(
              "The installed Helper must be refreshed before changing the system time zone."
            )
          )
        )
      )
      return
    }

    isWorking = true
    let proxy = helperProxy { [weak self] error in
      DispatchQueue.main.async {
        let message = L10n.format(
          "Power Helper connection failed: %@",
          error.localizedDescription
        )
        let localizedError = PowerHelperManagerError.connection(message)
        self?.isWorking = false
        self?.lastError = message
        self?.clearProtocolInfo()
        self?.invalidateConnection()
        completion?(.failure(localizedError))
      }
    }
    guard let proxy else {
      isWorking = false
      let error = PowerHelperManagerError.connection(
        L10n.string("Unable to connect to MenuCueHelper.")
      )
      lastError = L10n.format("%@", error.localizedDescription)
      completion?(.failure(error))
      return
    }

    invocation(proxy) { [weak self] success, identifier, errorMessage in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isWorking = false
        self.systemTimeZoneIdentifier = identifier
        if success, let identifier {
          self.lastError = nil
          completion?(.success(identifier))
        } else {
          let error = PowerHelperManagerError.operation(
            Self.localizedHelperMessage(
              errorMessage,
              fallbackKey: "The system time zone operation failed."
            )
          )
          self.lastError = L10n.format("%@", error.localizedDescription)
          completion?(.failure(error))
        }
      }
    }
  }

  private func markHelperRefreshRequired() {
    requiresHelperRefresh = true
    registrationState = .refreshRequired
    lastError = registrationState.detail
    clearProtocolInfo()
    invalidateConnection()
  }

  private func clearProtocolInfo() {
    helperProtocolVersion = 0
    helperCapabilities = []
    systemTimeZoneIdentifier = nil
  }

  private func helperProxy(
    errorHandler: @escaping (Error) -> Void
  ) -> PowerHelperProtocol? {
    if connection == nil {
      let connection = NSXPCConnection(
        machServiceName: PowerHelperConstants.machServiceName,
        options: .privileged
      )
      connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
      connection.interruptionHandler = { [weak self] in
        DispatchQueue.main.async {
          guard let self else { return }
          let message = L10n.string(
            "The power Helper connection was interrupted. Try the action again."
          )
          self.registrationState = .failed(message)
          self.lastError = message
          self.clearProtocolInfo()
          self.invalidateConnection()
        }
      }
      connection.invalidationHandler = { [weak self] in
        DispatchQueue.main.async {
          self?.connection = nil
        }
      }
      connection.resume()
      self.connection = connection
    }

    return connection?.remoteObjectProxyWithErrorHandler(errorHandler)
      as? PowerHelperProtocol
  }

  private static func localizedHelperMessage(
    _ message: String?,
    fallbackKey: String
  ) -> String {
    guard let message, !message.isEmpty else { return L10n.string(fallbackKey) }

    switch message {
    case "MenuCueHelper must run as a root LaunchDaemon.",
      "This Mac does not expose a supported Low Power Mode pmset key.",
      "systemsetup returned an unreadable time zone.":
      return L10n.string(message)
    default:
      let unsupportedPrefix = "Unsupported system time zone: "
      if message.hasPrefix(unsupportedPrefix) {
        return L10n.format(
          "Unsupported system time zone: %@",
          String(message.dropFirst(unsupportedPrefix.count))
        )
      }

      let mismatchPrefix = "Expected system time zone "
      let mismatchSeparator = ", observed "
      if message.hasPrefix(mismatchPrefix),
        let separatorRange = message.range(of: mismatchSeparator)
      {
        let expected = String(message[message.index(
          message.startIndex,
          offsetBy: mismatchPrefix.count
        )..<separatorRange.lowerBound])
        let observed = String(message[separatorRange.upperBound...].dropLast(message.hasSuffix(".") ? 1 : 0))
        return L10n.format(
          "Expected system time zone %@, observed %@.",
          expected,
          observed == "unknown" ? L10n.string("unknown") : observed
        )
      }

      let statusSeparator = " failed with status "
      if let separatorRange = message.range(of: statusSeparator) {
        let executable = String(message[..<separatorRange.lowerBound])
        let statusText = String(
          message[separatorRange.upperBound...].dropLast(message.hasSuffix(".") ? 1 : 0)
        )
        if let status = Int(statusText) {
          return L10n.format("%@ failed with status %d.", executable, status)
        }
      }

      return L10n.format("Power Helper error: %@", message)
    }
  }

  private func invalidateConnection() {
    connection?.invalidate()
    connection = nil
  }
}
