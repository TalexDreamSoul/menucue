import XCTest

@testable import MenuCue

final class NotificationSettingsPersistenceTests: XCTestCase {
  func testLocalSettingsRoundTripWithoutSecrets() {
    let suite = "NotificationSettingsPersistenceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)
    var settings = store.load()
    settings.notificationSettings.setDeviceNameOverride("Studio Mac")
    settings.notificationSettings.updateChannel(.bark) {
      $0.isEnabled = true
      $0.barkServerURL = "https://push.example.com/base"
      $0.barkGroup = "Servers"
    }
    settings.notificationSettings.rules = [
      AlertRule(
        name: "CPU high", metricID: "cpu.total.busy",
        condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark])
    ]

    store.save(settings)
    let reloaded = store.load()

    XCTAssertEqual(reloaded.notificationSettings, settings.notificationSettings)
    let persisted = defaults.dictionaryRepresentation().description
    XCTAssertFalse(persisted.contains("device-secret"))
    XCTAssertFalse(persisted.contains("bot-token"))
  }

  func testMissingOrCorruptDataFallsBackToDefaults() {
    let suite = "NotificationSettingsCorruptTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not-json".utf8), forKey: "notificationSettings.v1")

    XCTAssertEqual(
      SettingsStore(defaults: defaults).load().notificationSettings,
      .default
    )
  }

  func testRuleSaveSanitizationCannotReenableDisabledChannel() {
    let rule = AlertRule(
      name: "CPU", metricID: "cpu.total.busy",
      condition: .numeric(operator: .above, threshold: 0.9),
      channels: [.bark, .telegram])

    let sanitized = rule.limitingChannels(to: [.bark])

    XCTAssertEqual(sanitized.channels, [.bark])
  }

  func testSettingsPaneRoutesToAlerts() {
    XCTAssertTrue(SettingsPane.allCases.contains(.alerts))
    XCTAssertEqual(SettingsPane.alerts.title, L10n.string("Alert Rules"))
    XCTAssertEqual(SettingsPane.alerts.systemImage, "bell.badge")
    XCTAssertEqual(SettingsPane.migrating(rawValue: "notifications"), .alerts)
  }

  func testDeviceNameOverrideTrimResetAndFallback() {
    var settings = NotificationSettings()
    XCTAssertEqual(settings.resolvedDeviceName(systemName: "Office Mac"), "Office Mac")
    settings.setDeviceNameOverride("  Build Mac  ")
    XCTAssertEqual(settings.resolvedDeviceName(systemName: "Office Mac"), "Build Mac")
    settings.setDeviceNameOverride("  ")
    XCTAssertEqual(settings.resolvedDeviceName(systemName: nil), "Mac")
  }

  /// The master switch was added to a struct that already had channels and rules on disk.
  /// `SettingsStore` keeps the stored value only when decoding succeeds, so a strict decoder
  /// would reset every configured channel and rule the first time this build launched.
  func testStoredPayloadWrittenBeforeTheGlobalSwitchKeptEverythingElse() throws {
    let suite = "NotificationSettingsUpgradeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    var legacy = NotificationSettings()
    legacy.updateChannel(.bark) {
      $0.isEnabled = true
      $0.barkGroup = "Servers"
    }
    let enabledRule = AlertRule(
      name: "CPU high", metricID: "cpu.total.busy",
      condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark])
    var disabledRule = AlertRule(
      name: "Memory high", metricID: "memory.used.percent",
      condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark])
    disabledRule.isEnabled = false
    legacy.rules = [enabledRule, disabledRule]

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    object.removeValue(forKey: "isGloballyEnabled")
    defaults.set(
      try JSONSerialization.data(withJSONObject: object), forKey: "notificationSettings.v1")

    let loaded = SettingsStore(defaults: defaults).load().notificationSettings

    XCTAssertTrue(
      loaded.isGloballyEnabled,
      "a switch nobody ever touched must decode as on, not reset the pane to off")
    XCTAssertEqual(loaded.channels[.bark]?.isEnabled, true)
    XCTAssertEqual(loaded.channels[.bark]?.barkGroup, "Servers")
    XCTAssertEqual(loaded.rules.map(\.id), [enabledRule.id, disabledRule.id])
    XCTAssertEqual(
      loaded.enabledRuleCount, 1,
      "the armed rule count has to follow the stored enabled flag, not the total")
  }

  func testAlertsMasterSwitchRoundTripsThroughTheSettingsStore() {
    let suite = "NotificationSettingsSwitchTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)

    var settings = store.load()
    settings.notificationSettings.isGloballyEnabled = false
    store.save(settings)
    XCTAssertFalse(store.load().notificationSettings.isGloballyEnabled)

    settings.notificationSettings.isGloballyEnabled = true
    store.save(settings)
    XCTAssertTrue(store.load().notificationSettings.isGloballyEnabled)
  }
}

@MainActor
final class NotificationConfigurationServiceTests: XCTestCase {
  func testChannelEnablementRequiresTypedMetadataAndRequiredSecret() throws {
    let secrets = InMemoryNotificationSecretStore()
    let service = NotificationConfigurationService(
      secrets: secrets, transport: SuccessfulNotificationTransport())
    var settings = NotificationSettings()

    XCTAssertFalse(service.canEnable(.feishu, settings: settings))
    try service.saveSecret(
      "https://open.feishu.cn/open-apis/bot/v2/hook/abc",
      for: NotificationSecretField.feishuWebhook)
    XCTAssertTrue(service.canEnable(.feishu, settings: settings))

    try service.saveSecret("123:ABC_def", for: NotificationSecretField.telegramBotToken)
    XCTAssertFalse(service.canEnable(.telegram, settings: settings))
    settings.updateChannel(.telegram) { $0.telegramChatID = "-100123" }
    XCTAssertTrue(service.canEnable(.telegram, settings: settings))
  }

  func testSecretsCanBeRemovedWithoutEnteringSettingsModel() throws {
    let secrets = InMemoryNotificationSecretStore()
    let service = NotificationConfigurationService(
      secrets: secrets, transport: SuccessfulNotificationTransport())
    try service.saveSecret("device-secret", for: NotificationSecretField.barkDeviceKey)

    XCTAssertTrue(service.hasSavedSecret(NotificationSecretField.barkDeviceKey))
    // The secret lifecycle never writes through the settings model, so the seeded product
    // default an untouched install boots from has to survive it intact: the native channel
    // stays the only enabled one and its shipped rules stay enabled.
    XCTAssertTrue(NotificationSettings.default.channel(.system).isEnabled)
    XCTAssertEqual(Set(NotificationSettings.default.channels.keys), [.system])
    XCTAssertEqual(NotificationSettings.default.enabledRuleCount, 5)

    try service.removeSecret(NotificationSecretField.barkDeviceKey)
    XCTAssertFalse(service.hasSavedSecret(NotificationSecretField.barkDeviceKey))
    XCTAssertNil(try secrets.string(for: NotificationSecretField.barkDeviceKey))
  }

  func testPerChannelTestStatesRemainIndependent() async throws {
    let secrets = InMemoryNotificationSecretStore()
    let service = NotificationConfigurationService(
      secrets: secrets, transport: SuccessfulNotificationTransport())
    var settings = NotificationSettings()
    try service.saveSecret("bark-key", for: NotificationSecretField.barkDeviceKey)
    try service.saveSecret("123:ABC_def", for: NotificationSecretField.telegramBotToken)
    settings.updateChannel(.telegram) { $0.telegramChatID = "-100123" }

    await service.testChannel(.bark, settings: settings, systemDeviceName: "Test Mac")
    XCTAssertEqual(service.testState(for: .bark), .succeeded)
    XCTAssertEqual(service.testState(for: .telegram), .idle)

    await service.testChannel(.telegram, settings: settings, systemDeviceName: "Test Mac")
    XCTAssertEqual(service.testState(for: .bark), .succeeded)
    XCTAssertEqual(service.testState(for: .telegram), .succeeded)
  }

  func testEnabledChannelFactorySkipsInvalidSiblingOnly() throws {
    let secrets = InMemoryNotificationSecretStore()
    let service = NotificationConfigurationService(
      secrets: secrets, transport: SuccessfulNotificationTransport())
    var settings = NotificationSettings()
    try service.saveSecret("bark-key", for: NotificationSecretField.barkDeviceKey)
    settings.updateChannel(.bark) { $0.isEnabled = true }
    settings.updateChannel(.telegram) { $0.isEnabled = true }

    let channels = service.makeEnabledChannels(settings: settings)

    XCTAssertNotNil(channels[.bark])
    XCTAssertNotNil(channels[.telegram])
  }
  func testOptionalCredentialKeychainFailureAlsoDefersDelivery() async throws {
    let secrets = ToggleNotificationSecretStore()
    try secrets.setString(
      "https://open.feishu.cn/open-apis/bot/v2/hook/abc",
      for: NotificationSecretField.feishuWebhook)
    let service = NotificationConfigurationService(
      secrets: secrets, transport: SuccessfulNotificationTransport())
    var settings = NotificationSettings()
    settings.updateChannel(.feishu) { $0.isEnabled = true }
    secrets.unavailableKeys = [NotificationSecretField.feishuSigningSecret]

    let channel = try XCTUnwrap(service.makeEnabledChannels(settings: settings)[.feishu])
    do {
      _ = try await channel.send(testMessage())
      XCTFail("Expected credential failure")
    } catch let error as NotificationDeliveryError {
      XCTAssertEqual(error, .credentialUnavailable)
    }
  }

  func testTemporaryKeychainFailureCreatesRetryableChannelAndCanRecover() async throws {
    let secrets = ToggleNotificationSecretStore()
    try secrets.setString("bark-key", for: NotificationSecretField.barkDeviceKey)
    let service = NotificationConfigurationService(
      secrets: secrets, transport: SuccessfulNotificationTransport())
    var settings = NotificationSettings()
    settings.updateChannel(.bark) { $0.isEnabled = true }
    secrets.isUnavailable = true

    let unavailable = try XCTUnwrap(service.makeEnabledChannels(settings: settings)[.bark])
    do {
      _ = try await unavailable.send(testMessage())
      XCTFail("Expected credential failure")
    } catch let error as NotificationDeliveryError {
      XCTAssertEqual(error, .credentialUnavailable)
      XCTAssertTrue(error.isRetryable)
    }

    secrets.isUnavailable = false
    let recovered = try XCTUnwrap(service.makeEnabledChannels(settings: settings)[.bark])
    _ = try await recovered.send(testMessage())
  }

  private func testMessage() -> NotificationMessage {
    NotificationMessage(
      eventID: "test", deviceName: "Mac", ruleID: "test", state: .test,
      occurredAt: Date(), title: "Test", body: "Body", metric: nil)
  }
}

private final class ToggleNotificationSecretStore: NotificationSecretStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [NotificationSecretKey: Data] = [:]
  var isUnavailable = false
  var unavailableKeys: Set<NotificationSecretKey> = []

  func data(for key: NotificationSecretKey) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if isUnavailable || unavailableKeys.contains(key) {
      throw NotificationSecretStoreError.keychainFailure(status: errSecInteractionNotAllowed)
    }
    return values[key]
  }

  func set(_ data: Data, for key: NotificationSecretKey) throws {
    lock.lock()
    values[key] = data
    lock.unlock()
  }

  func remove(_ key: NotificationSecretKey) throws {
    lock.lock()
    values.removeValue(forKey: key)
    lock.unlock()
  }
}

private struct SuccessfulNotificationTransport: NotificationHTTPTransport {
  func data(for request: URLRequest) async throws -> NotificationHTTPResponse {
    let path = request.url?.path ?? ""
    let data: Data
    let status: Int
    if path.contains("sendMessage") {
      data = Data(#"{"ok":true}"#.utf8)
      status = 200
    } else if path.hasSuffix("/push") {
      data = Data(#"{"code":200}"#.utf8)
      status = 200
    } else if path.contains("/open-apis/bot/v2/hook/") {
      data = Data(#"{"code":0}"#.utf8)
      status = 200
    } else {
      data = Data()
      status = 204
    }
    return NotificationHTTPResponse(statusCode: status, headers: [:], data: data)
  }
}
