import Combine
import Foundation

enum NotificationSecretField {
  static let feishuWebhook = NotificationSecretKey(channel: .feishu, field: "webhook")
  static let feishuSigningSecret = NotificationSecretKey(channel: .feishu, field: "signing-secret")
  static let webhookEndpoint = NotificationSecretKey(channel: .webhook, field: "endpoint")
  static let webhookBearerToken = NotificationSecretKey(channel: .webhook, field: "bearer-token")
  static let barkDeviceKey = NotificationSecretKey(channel: .bark, field: "device-key")
  static let telegramBotToken = NotificationSecretKey(channel: .telegram, field: "bot-token")

  static func required(for kind: NotificationChannelKind) -> [NotificationSecretKey] {
    switch kind {
    case .feishu: return [feishuWebhook]
    case .webhook: return [webhookEndpoint]
    case .bark: return [barkDeviceKey]
    case .telegram: return [telegramBotToken]
    }
  }

  static func optional(for kind: NotificationChannelKind) -> [NotificationSecretKey] {
    switch kind {
    case .feishu: return [feishuSigningSecret]
    case .webhook: return [webhookBearerToken]
    case .bark, .telegram: return []
    }
  }
}

struct NotificationChannelSettings: Codable, Equatable, Sendable {
  var isEnabled = false
  var barkServerURL = "https://api.day.app"
  var barkGroup = "MenuCue"
  var telegramChatID = ""
  var telegramThreadID: Int?
}

struct NotificationSettings: Codable, Equatable, Sendable {
  var deviceNameOverride: String?
  var channels: [NotificationChannelKind: NotificationChannelSettings]
  var rules: [AlertRule]

  init(
    deviceNameOverride: String? = nil,
    channels: [NotificationChannelKind: NotificationChannelSettings] = [:],
    rules: [AlertRule] = []
  ) {
    self.deviceNameOverride = Self.normalizedName(deviceNameOverride)
    self.channels = channels
    self.rules = rules
  }

  static let `default` = NotificationSettings()

  func channel(_ kind: NotificationChannelKind) -> NotificationChannelSettings {
    channels[kind] ?? NotificationChannelSettings()
  }

  mutating func updateChannel(
    _ kind: NotificationChannelKind,
    _ update: (inout NotificationChannelSettings) -> Void
  ) {
    var value = channel(kind)
    update(&value)
    channels[kind] = value
  }

  mutating func setDeviceNameOverride(_ value: String?) {
    deviceNameOverride = Self.normalizedName(value)
  }

  func resolvedDeviceName(systemName: String?) -> String {
    if let deviceNameOverride { return deviceNameOverride }
    let system = Self.normalizedName(systemName)
    return system ?? "Mac"
  }

  private static func normalizedName(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
  }
}

enum NotificationChannelTestState: Equatable {
  case idle
  case testing
  case succeeded
  case failed(String)
}

final class NotificationConfigurationService: ObservableObject, @unchecked Sendable {
  @Published private(set) var testStates: [NotificationChannelKind: NotificationChannelTestState] =
    [:]
  @Published private(set) var savedSecretFields: Set<NotificationSecretKey> = []

  private let secrets: any NotificationSecretStoring
  private let transport: any NotificationHTTPTransport

  init(
    secrets: any NotificationSecretStoring = KeychainNotificationSecretStore(),
    transport: any NotificationHTTPTransport = URLSessionNotificationHTTPTransport()
  ) {
    self.secrets = secrets
    self.transport = transport
    refreshSecretPresence()
  }

  func testState(for kind: NotificationChannelKind) -> NotificationChannelTestState {
    testStates[kind] ?? .idle
  }

  func hasSavedSecret(_ key: NotificationSecretKey) -> Bool {
    savedSecretFields.contains(key)
  }

  func saveSecret(_ value: String, for key: NotificationSecretKey) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw NotificationSecretStoreError.invalidValue }
    try secrets.setString(trimmed, for: key)
    savedSecretFields.insert(key)
    testStates[key.channel] = .idle
  }

  func removeSecret(_ key: NotificationSecretKey) throws {
    try secrets.remove(key)
    savedSecretFields.remove(key)
    testStates[key.channel] = .idle
  }

  func refreshSecretPresence() {
    var fields = Set<NotificationSecretKey>()
    for kind in NotificationChannelKind.allCases {
      for key in NotificationSecretField.required(for: kind)
        + NotificationSecretField.optional(for: kind)
      {
        if (try? secrets.data(for: key)) != nil { fields.insert(key) }
      }
    }
    savedSecretFields = fields
  }

  func canEnable(_ kind: NotificationChannelKind, settings: NotificationSettings) -> Bool {
    (try? makeChannel(kind, settings: settings)) != nil
  }

  func makeEnabledChannels(
    settings: NotificationSettings
  ) -> [NotificationChannelKind: any NotificationChannel] {
    var channels: [NotificationChannelKind: any NotificationChannel] = [:]
    for kind in NotificationChannelKind.allCases where settings.channel(kind).isEnabled {
      do {
        channels[kind] = try makeChannel(kind, settings: settings)
      } catch {
        channels[kind] = DeferredNotificationChannel(
          kind: kind,
          error: Self.deliveryError(for: error)
        )
      }
    }
    return channels
  }

  @MainActor
  func testChannel(
    _ kind: NotificationChannelKind,
    settings: NotificationSettings,
    systemDeviceName: String? = Host.current().localizedName
  ) async {
    testStates[kind] = .testing
    do {
      let channel = try makeChannel(kind, settings: settings)
      let message = NotificationMessage(
        eventID: "test|\(UUID().uuidString)",
        deviceName: settings.resolvedDeviceName(systemName: systemDeviceName),
        ruleID: "test",
        state: .test,
        occurredAt: Date(),
        title: L10n.string("MenuCue test notification"),
        body: L10n.string("Notifications from this Mac are configured."),
        metric: nil
      )
      _ = try await channel.send(message)
      testStates[kind] = .succeeded
    } catch {
      testStates[kind] = .failed(Self.safeMessage(for: error))
    }
  }

  private func makeChannel(
    _ kind: NotificationChannelKind,
    settings: NotificationSettings
  ) throws -> any NotificationChannel {
    let channel = settings.channel(kind)
    let descriptor: NotificationChannelDescriptor
    switch kind {
    case .feishu:
      descriptor = .feishu(
        webhookKey: NotificationSecretField.feishuWebhook,
        signingSecretKey: try configuredOptionalSecret(
          NotificationSecretField.feishuSigningSecret)
      )
    case .webhook:
      descriptor = .webhook(
        endpointKey: NotificationSecretField.webhookEndpoint,
        bearerTokenKey: try configuredOptionalSecret(
          NotificationSecretField.webhookBearerToken)
      )
    case .bark:
      guard let url = URL(string: channel.barkServerURL) else {
        throw NotificationDeliveryError.invalidConfiguration
      }
      let group = channel.barkGroup.trimmingCharacters(in: .whitespacesAndNewlines)
      descriptor = .bark(
        serverBaseURL: url,
        deviceKey: NotificationSecretField.barkDeviceKey,
        group: group.isEmpty ? nil : group
      )
    case .telegram:
      let chatID = channel.telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chatID.isEmpty else { throw NotificationDeliveryError.invalidConfiguration }
      descriptor = .telegram(
        tokenKey: NotificationSecretField.telegramBotToken,
        chatID: chatID,
        messageThreadID: channel.telegramThreadID
      )
    }
    return try NotificationChannelFactory.make(descriptor, secrets: secrets, transport: transport)
  }

  private func configuredOptionalSecret(
    _ key: NotificationSecretKey
  ) throws -> NotificationSecretKey? {
    try secrets.data(for: key) == nil ? nil : key
  }

  private static func deliveryError(for error: Error) -> NotificationDeliveryError {
    if let secretError = error as? NotificationSecretStoreError,
      case .keychainFailure = secretError
    {
      return .credentialUnavailable
    }
    if let deliveryError = error as? NotificationDeliveryError { return deliveryError }
    return .invalidConfiguration
  }

  private static func safeMessage(for error: Error) -> String {
    if let error = error as? NotificationDeliveryError {
      return error.localizedDescription
    }
    if error is NotificationSecretStoreError {
      return "The notification credential could not be accessed."
    }
    return "The test notification could not be sent."
  }
}

private struct DeferredNotificationChannel: NotificationChannel {
  let kind: NotificationChannelKind
  let error: NotificationDeliveryError

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    throw error
  }
}
