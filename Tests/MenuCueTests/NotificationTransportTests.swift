import CryptoKit
import Foundation
import Security
import XCTest

@testable import MenuCue

final class NotificationTransportTests: XCTestCase {
  private let occurredAt = Date(timeIntervalSince1970: 1_722_182_400)

  func testMessageValidationUsesCombinedCharacterLimit() throws {
    let valid = message(
      title: String(repeating: "😀", count: 1_999), body: String(repeating: "界", count: 2_000))
    XCTAssertNoThrow(try valid.validate())

    let oversized = message(title: "A", body: String(repeating: "界", count: 4_000))
    XCTAssertThrowsError(try oversized.validate()) { error in
      XCTAssertEqual(error as? NotificationDeliveryError, .payloadTooLarge)
    }
  }

  func testWebhookEncodesVersionedEnvelopeAndBearerToken() async throws {
    let endpoint = try XCTUnwrap(URL(string: "https://hooks.example.test/menucue"))
    let transport = RecordingNotificationHTTPTransport(
      response: NotificationHTTPResponse(statusCode: 204, headers: [:], data: Data()))
    let channel = try WebhookNotificationChannel(
      configuration: WebhookNotificationConfiguration(
        endpoint: endpoint,
        bearerToken: "bearer-secret"
      ),
      transport: transport
    )

    let receipt = try await channel.send(message())
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let metric = try XCTUnwrap(json["metric"] as? [String: Any])

    XCTAssertEqual(receipt.kind, .webhook)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url, endpoint)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("MenuCue/") == true)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-MenuCue-Event-ID"), "event-1")
    XCTAssertEqual(json["schema_version"] as? Int, 1)
    XCTAssertEqual(json["event_id"] as? String, "event-1")
    XCTAssertEqual(json["device_name"] as? String, "Studio Mac")
    XCTAssertEqual(json["state"] as? String, "alert")
    XCTAssertEqual(json["title"] as? String, "High CPU")
    XCTAssertEqual(json["body"] as? String, "CPU stayed above 90% for 5 minutes.")
    XCTAssertEqual(metric["id"] as? String, "cpu.total.busy")
    XCTAssertEqual(try XCTUnwrap(metric["value"] as? Double), 0.96, accuracy: 0.0001)
  }

  func testWebhookRejectsNonHTTPSAndRedirectStatus() async throws {
    XCTAssertThrowsError(
      try WebhookNotificationChannel(
        configuration: WebhookNotificationConfiguration(
          endpoint: XCTUnwrap(URL(string: "http://hooks.example.test/menucue")),
          bearerToken: nil
        ),
        transport: RecordingNotificationHTTPTransport.success()
      )
    ) { error in
      XCTAssertEqual(error as? NotificationDeliveryError, .invalidConfiguration)
    }

    let redirectTransport = RecordingNotificationHTTPTransport(
      response: NotificationHTTPResponse(
        statusCode: 302,
        headers: ["Location": "http://attacker.example/collect"],
        data: Data()
      ))
    let channel = try WebhookNotificationChannel(
      configuration: WebhookNotificationConfiguration(
        endpoint: XCTUnwrap(URL(string: "https://hooks.example.test/menucue")),
        bearerToken: "secret"
      ),
      transport: redirectTransport
    )

    do {
      _ = try await channel.send(message())
      XCTFail("Expected redirect response to fail")
    } catch {
      XCTAssertEqual(error as? NotificationDeliveryError, .httpStatus(302, retryAfter: nil))
    }

    let original = URLRequest(url: try XCTUnwrap(URL(string: "https://hooks.example.test")))
    let redirected = URLRequest(url: try XCTUnwrap(URL(string: "http://attacker.example")))
    XCTAssertNil(RedirectRejectingSessionDelegate.redirectedRequest(from: original, to: redirected))
  }

  func testURLSessionTransportDoesNotFollowCrossOriginRedirect() async throws {
    let source = try XCTUnwrap(URL(string: "https://redirect.example.test/start"))
    let target = try XCTUnwrap(URL(string: "http://attacker.example.test/collect"))
    NotificationTransportURLProtocol.configure(.redirect(target))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NotificationTransportURLProtocol.self]
    let transport = URLSessionNotificationHTTPTransport(
      timeout: 0.1,
      configuration: configuration
    )

    _ = try? await transport.data(for: URLRequest(url: source))

    XCTAssertEqual(NotificationTransportURLProtocol.requestedURLs(), [source])
  }

  func testURLSessionTransportStopsReadingAtResponseLimit() async throws {
    NotificationTransportURLProtocol.configure(.data(Data(repeating: 0x61, count: 1_024)))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NotificationTransportURLProtocol.self]
    let transport = URLSessionNotificationHTTPTransport(
      maximumResponseBytes: 64,
      configuration: configuration
    )

    do {
      _ = try await transport.data(
        for: URLRequest(url: XCTUnwrap(URL(string: "https://large.example.test"))))
      XCTFail("Expected streaming response limit")
    } catch {
      XCTAssertEqual(error as? NotificationDeliveryError, .responseTooLarge)
    }
  }

  func testChannelConfigurationRejectsCredentialInjectionAndAmbiguousEndpoints() throws {
    XCTAssertThrowsError(
      try WebhookNotificationChannel(
        configuration: WebhookNotificationConfiguration(
          endpoint: XCTUnwrap(URL(string: "https://hooks.example.test/menucue")),
          bearerToken: "safe\r\nX-Injected: value"
        ),
        transport: RecordingNotificationHTTPTransport.success()
      ),
      "Webhook bearer values containing CR/LF must be rejected"
    )

    XCTAssertThrowsError(
      try FeishuNotificationChannel(
        configuration: FeishuNotificationConfiguration(
          webhookURL: XCTUnwrap(URL(string: "https://open.feishu.cn/open-apis/bot/v2/hook/")),
          signingSecret: nil
        ),
        transport: RecordingNotificationHTTPTransport.success()
      ),
      "Feishu hook URLs require a non-empty token"
    )

    XCTAssertThrowsError(
      try BarkNotificationChannel(
        configuration: BarkNotificationConfiguration(
          serverBaseURL: XCTUnwrap(URL(string: "https://bark.example.test/base?token=secret")),
          deviceKey: "device-key",
          group: nil
        ),
        transport: RecordingNotificationHTTPTransport.success()
      ),
      "Bark server base URLs cannot contain query credentials"
    )

    XCTAssertThrowsError(
      try TelegramNotificationChannel(
        configuration: TelegramNotificationConfiguration(
          botToken: "123:", chatID: "1", messageThreadID: nil),
        transport: RecordingNotificationHTTPTransport.success()
      ),
      "Telegram token suffix must not be empty"
    )

    XCTAssertThrowsError(
      try TelegramNotificationChannel(
        configuration: TelegramNotificationConfiguration(
          botToken: "１２３:token", chatID: "1", messageThreadID: nil),
        transport: RecordingNotificationHTTPTransport.success()
      ),
      "Telegram tokens are ASCII-only"
    )
  }

  func testFeishuEncodesTextAndOfficialSigningVector() async throws {
    let transport = RecordingNotificationHTTPTransport(
      response: jsonResponse(status: 200, object: ["code": 0, "msg": "success"]))
    let channel = try FeishuNotificationChannel(
      configuration: FeishuNotificationConfiguration(
        webhookURL: XCTUnwrap(
          URL(string: "https://open.feishu.cn/open-apis/bot/v2/hook/test-token")),
        signingSecret: "demo"
      ),
      transport: transport,
      timestamp: { 1_599_360_473 }
    )

    _ = try await channel.send(message())
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    let content = try XCTUnwrap(json["content"] as? [String: Any])

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(json["msg_type"] as? String, "text")
    XCTAssertEqual(content["text"] as? String, "High CPU\nCPU stayed above 90% for 5 minutes.")
    XCTAssertEqual(json["timestamp"] as? String, "1599360473")
    XCTAssertEqual(json["sign"] as? String, "l1N0gAcBjdwBvGm1xMjOF0XSyaLRpR7tuO5dHfhAYc8=")
  }

  func testFeishuRequiresApplicationLevelSuccess() async throws {
    let transport = RecordingNotificationHTTPTransport(
      response: jsonResponse(status: 200, object: ["code": 19024, "msg": "Key Words Not Found"]))
    let channel = try FeishuNotificationChannel(
      configuration: FeishuNotificationConfiguration(
        webhookURL: XCTUnwrap(
          URL(string: "https://open.feishu.cn/open-apis/bot/v2/hook/test-token")),
        signingSecret: nil
      ),
      transport: transport
    )

    do {
      _ = try await channel.send(message())
      XCTFail("Expected Feishu API failure")
    } catch {
      XCTAssertEqual(
        error as? NotificationDeliveryError,
        .remoteRejected(code: "19024", retryAfter: nil)
      )
      XCTAssertFalse(error.localizedDescription.contains("Key Words Not Found"))
    }
  }

  func testBarkUsesPostJSONAndPreservesCustomBasePath() async throws {
    let transport = RecordingNotificationHTTPTransport(
      response: jsonResponse(status: 200, object: ["code": 200, "message": "success"]))
    let channel = try BarkNotificationChannel(
      configuration: BarkNotificationConfiguration(
        serverBaseURL: XCTUnwrap(URL(string: "https://bark.example.test/service")),
        deviceKey: "device-key",
        group: "MenuCue"
      ),
      transport: transport
    )

    _ = try await channel.send(message())
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://bark.example.test/service/push")
    XCTAssertEqual(json["device_key"] as? String, "device-key")
    XCTAssertEqual(json["title"] as? String, "High CPU")
    XCTAssertEqual(json["body"] as? String, "CPU stayed above 90% for 5 minutes.")
    XCTAssertEqual(json["group"] as? String, "MenuCue")
    XCTAssertFalse(request.url?.absoluteString.contains("High CPU") ?? true)
  }

  func testBarkRejectsOversizedFinalJSONPayload() async throws {
    let channel = try BarkNotificationChannel(
      configuration: BarkNotificationConfiguration(
        serverBaseURL: XCTUnwrap(URL(string: "https://bark.example.test")),
        deviceKey: "device-key",
        group: String(repeating: "x", count: 70_000)
      ),
      transport: RecordingNotificationHTTPTransport.success()
    )

    do {
      _ = try await channel.send(message())
      XCTFail("Expected encoded payload limit")
    } catch {
      XCTAssertEqual(error as? NotificationDeliveryError, .payloadTooLarge)
    }
  }

  func testTelegramEncodesSendMessageAndRedactsTokenFromTransportFailure() async throws {
    let successTransport = RecordingNotificationHTTPTransport(
      response: jsonResponse(status: 200, object: ["ok": true, "result": [:]]))
    let channel = try TelegramNotificationChannel(
      configuration: TelegramNotificationConfiguration(
        botToken: "123456:super-secret-token",
        chatID: "-100123456",
        messageThreadID: 42
      ),
      transport: successTransport
    )

    _ = try await channel.send(message())
    let capturedRequest = await successTransport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://api.telegram.org/bot123456:super-secret-token/sendMessage")
    XCTAssertEqual(json["chat_id"] as? String, "-100123456")
    XCTAssertEqual(json["message_thread_id"] as? Int, 42)
    XCTAssertEqual(json["text"] as? String, "High CPU\nCPU stayed above 90% for 5 minutes.")

    let failingTransport = RecordingNotificationHTTPTransport(
      error: URLError(
        .badServerResponse,
        userInfo: [
          NSURLErrorFailingURLStringErrorKey:
            "https://api.telegram.org/bot123456:super-secret-token/sendMessage"
        ]
      ))
    let failing = try TelegramNotificationChannel(
      configuration: TelegramNotificationConfiguration(
        botToken: "123456:super-secret-token",
        chatID: "123",
        messageThreadID: nil
      ),
      transport: failingTransport
    )

    do {
      _ = try await failing.send(message())
      XCTFail("Expected transport failure")
    } catch {
      XCTAssertEqual(error as? NotificationDeliveryError, .networkUnavailable)
      XCTAssertFalse(error.localizedDescription.contains("super-secret-token"))
      XCTAssertFalse(String(describing: error).contains("super-secret-token"))
    }
  }

  func testTelegramRateLimitCarriesSafeRetryDelay() async throws {
    let transport = RecordingNotificationHTTPTransport(
      response: jsonResponse(
        status: 429,
        object: [
          "ok": false,
          "description": "Too Many Requests: retry after 12",
          "parameters": ["retry_after": 12],
        ]
      ))
    let channel = try TelegramNotificationChannel(
      configuration: TelegramNotificationConfiguration(
        botToken: "123:secret",
        chatID: "123",
        messageThreadID: nil
      ),
      transport: transport
    )

    do {
      _ = try await channel.send(message())
      XCTFail("Expected rate limit")
    } catch {
      XCTAssertEqual(error as? NotificationDeliveryError, .httpStatus(429, retryAfter: 12))
      XCTAssertTrue((error as? NotificationDeliveryError)?.isRetryable == true)
    }
  }

  func testKeychainStoreUsesDeviceOnlyNonSynchronizableAttributes() throws {
    let client = RecordingSecItemClient()
    client.updateStatuses = [errSecItemNotFound]
    let store = KeychainNotificationSecretStore(client: client)
    let key = NotificationSecretKey(channel: .telegram, field: "bot-token")

    try store.set(Data("secret".utf8), for: key)
    let attributes = try XCTUnwrap(client.addedAttributes)

    XCTAssertEqual(
      attributes[kSecClass as String] as? String,
      kSecClassGenericPassword as String
    )
    XCTAssertEqual(
      attributes[kSecAttrService as String] as? String,
      "com.tagzxia.app.menucue.notifications"
    )
    XCTAssertEqual(
      attributes[kSecAttrAccount as String] as? String,
      "telegram.bot-token"
    )
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("secret".utf8))
  }

  func testKeychainStoreUpdatesReadsDeletesAndMapsAccessFailure() throws {
    let client = RecordingSecItemClient()
    let store = KeychainNotificationSecretStore(client: client)
    let key = NotificationSecretKey(channel: .bark, field: "device-key")

    client.copyStatus = errSecSuccess
    client.copyData = Data("existing".utf8)
    XCTAssertEqual(try store.data(for: key), Data("existing".utf8))
    XCTAssertEqual(client.lastCopyQuery?[kSecAttrSynchronizable as String] as? Bool, false)

    client.updateStatuses = [errSecSuccess]
    try store.set(Data("next".utf8), for: key)
    XCTAssertEqual(
      client.lastUpdateQuery?[kSecAttrService as String] as? String,
      "com.tagzxia.app.menucue.notifications")
    XCTAssertEqual(client.lastUpdateQuery?[kSecAttrSynchronizable as String] as? Bool, false)
    XCTAssertEqual(
      client.updatedAttributes?[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    XCTAssertEqual(client.updatedAttributes?[kSecAttrSynchronizable as String] as? Bool, false)
    XCTAssertEqual(client.updatedAttributes?[kSecValueData as String] as? Data, Data("next".utf8))

    client.deleteStatus = errSecItemNotFound
    XCTAssertNoThrow(try store.remove(key))
    XCTAssertEqual(client.lastDeleteQuery?[kSecAttrSynchronizable as String] as? Bool, false)

    client.copyStatus = errSecInteractionNotAllowed
    XCTAssertThrowsError(try store.data(for: key)) { error in
      XCTAssertEqual(
        error as? NotificationSecretStoreError,
        .keychainFailure(status: errSecInteractionNotAllowed)
      )
    }
  }

  func testKeychainStoreRetriesUpdateWhenConcurrentAddWins() throws {
    let client = RecordingSecItemClient()
    client.updateStatuses = [errSecItemNotFound, errSecSuccess]
    client.addStatus = errSecDuplicateItem
    let store = KeychainNotificationSecretStore(client: client)

    try store.set(
      Data("secret".utf8),
      for: NotificationSecretKey(channel: .feishu, field: "webhook")
    )

    XCTAssertEqual(client.updateCallCount, 2)
  }

  func testFactoryResolvesSecretsWithoutExposingThemInDescriptor() async throws {
    let secrets = InMemoryNotificationSecretStore()
    try secrets.setString("123:factory-secret", for: .init(channel: .telegram, field: "token"))
    let transport = RecordingNotificationHTTPTransport(
      response: jsonResponse(status: 200, object: ["ok": true, "result": [:]]))
    let descriptor = NotificationChannelDescriptor.telegram(
      tokenKey: .init(channel: .telegram, field: "token"),
      chatID: "321",
      messageThreadID: nil
    )

    let channel = try NotificationChannelFactory.make(
      descriptor,
      secrets: secrets,
      transport: transport
    )
    _ = try await channel.send(message())
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)

    XCTAssertEqual(channel.kind, .telegram)
    XCTAssertTrue(request.url?.absoluteString.contains("factory-secret") == true)
    XCTAssertFalse(String(describing: descriptor).contains("factory-secret"))
  }

  func testCoordinatorIsolatesSuccessTerminalFailureAndRetry() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let claims = [
      NotificationOutboxClaim(
        leaseID: "lease-bark", eventID: "event-1", channelKind: .bark,
        message: message(), attempt: 1),
      NotificationOutboxClaim(
        leaseID: "lease-feishu", eventID: "event-1", channelKind: .feishu,
        message: message(), attempt: 1),
      NotificationOutboxClaim(
        leaseID: "lease-telegram", eventID: "event-1", channelKind: .telegram,
        message: message(), attempt: 1),
    ]
    let outbox = RecordingNotificationOutbox(claims: claims)
    let coordinator = NotificationDeliveryCoordinator(
      outbox: outbox,
      channels: [
        .bark: StubNotificationChannel(kind: .bark, result: .success),
        .feishu: StubNotificationChannel(kind: .feishu, result: .terminalFailure),
        .telegram: StubNotificationChannel(kind: .telegram, result: .transientFailure),
      ],
      retryPolicy: NotificationRetryPolicy(maxAttempts: 3, baseDelay: 2, maximumDelay: 30),
      now: { now }
    )

    try await coordinator.drainOnce()
    let outcomes = await outbox.recordedOutcomes()

    XCTAssertEqual(outcomes.count, 3)
    XCTAssertEqual(outcomes.first(where: { $0.channelKind == .bark })?.leaseID, "lease-bark")
    XCTAssertEqual(outcomes.first(where: { $0.channelKind == .bark })?.status, .delivered)
    XCTAssertEqual(outcomes.first(where: { $0.channelKind == .feishu })?.status, .failed)
    XCTAssertEqual(
      outcomes.first(where: { $0.channelKind == .telegram })?.status,
      .retryScheduled(at: now.addingTimeInterval(2), attempt: 2)
    )
  }

  func testCoordinatorMarksMissingChannelTerminalWithoutBlockingSiblings() async throws {
    let outbox = RecordingNotificationOutbox(claims: [
      NotificationOutboxClaim(
        leaseID: "lease-webhook", eventID: "event-1", channelKind: .webhook,
        message: message(), attempt: 1),
      NotificationOutboxClaim(
        leaseID: "lease-bark", eventID: "event-1", channelKind: .bark,
        message: message(), attempt: 1),
    ])
    let coordinator = NotificationDeliveryCoordinator(
      outbox: outbox,
      channels: [.bark: StubNotificationChannel(kind: .bark, result: .success)]
    )

    try await coordinator.drainOnce()
    let outcomes = await outbox.recordedOutcomes()

    XCTAssertEqual(outcomes.first(where: { $0.channelKind == .webhook })?.status, .failed)
    XCTAssertEqual(outcomes.first(where: { $0.channelKind == .bark })?.status, .delivered)
  }

  func testCoordinatorSchedulesRetryFromFailureTimeNotClaimTime() async throws {
    let clock = SequenceNotificationClock([
      Date(timeIntervalSince1970: 10_000),
      Date(timeIntervalSince1970: 10_100),
    ])
    let outbox = RecordingNotificationOutbox(claims: [
      NotificationOutboxClaim(
        leaseID: "lease", eventID: "event-1", channelKind: .telegram,
        message: message(), attempt: 1)
    ])
    let coordinator = NotificationDeliveryCoordinator(
      outbox: outbox,
      channels: [
        .telegram: StubNotificationChannel(kind: .telegram, result: .transientFailure)
      ],
      retryPolicy: NotificationRetryPolicy(maxAttempts: 3, baseDelay: 2, maximumDelay: 30),
      now: { clock.next() }
    )

    try await coordinator.drainOnce()
    let outcomes = await outbox.recordedOutcomes()

    XCTAssertEqual(
      outcomes.first?.status,
      .retryScheduled(at: Date(timeIntervalSince1970: 10_102), attempt: 2)
    )
  }

  func testCoordinatorAcknowledgesFastSiblingBeforeSlowSiblingCompletes() async throws {
    let barkAcknowledged = expectation(description: "Bark acknowledged")
    let gate = NotificationChannelGate()
    let outbox = RecordingNotificationOutbox(
      claims: [
        NotificationOutboxClaim(
          leaseID: "lease-bark", eventID: "event-1", channelKind: .bark,
          message: message(), attempt: 1),
        NotificationOutboxClaim(
          leaseID: "lease-telegram", eventID: "event-1", channelKind: .telegram,
          message: message(), attempt: 1),
      ],
      onAcknowledge: { outcome in
        if outcome.channelKind == .bark { barkAcknowledged.fulfill() }
      }
    )
    let coordinator = NotificationDeliveryCoordinator(
      outbox: outbox,
      channels: [
        .bark: StubNotificationChannel(kind: .bark, result: .success),
        .telegram: GatedNotificationChannel(kind: .telegram, gate: gate),
      ]
    )

    let drain = Task { try await coordinator.drainOnce() }
    await fulfillment(of: [barkAcknowledged], timeout: 1)
    let slowChannelIsWaiting = await gate.isWaiting
    XCTAssertTrue(slowChannelIsWaiting)
    await gate.open()
    try await drain.value
  }

  func testCoordinatorDefersCredentialUnavailableWithoutConsumingAttemptBudget() async throws {
    let now = Date(timeIntervalSince1970: 500)
    let outbox = RecordingNotificationOutbox(claims: [
      NotificationOutboxClaim(
        leaseID: "lease-local", eventID: "event-1", channelKind: .bark,
        message: message(), attempt: 3)
    ])
    let coordinator = NotificationDeliveryCoordinator(
      outbox: outbox,
      channels: [.bark: StubNotificationChannel(kind: .bark, result: .credentialUnavailable)],
      retryPolicy: NotificationRetryPolicy(maxAttempts: 3, baseDelay: 2, maximumDelay: 30),
      now: { now }
    )

    try await coordinator.drainOnce()

    let outcomes = await outbox.recordedOutcomes()
    XCTAssertEqual(
      outcomes.first?.status,
      .retryScheduled(at: now.addingTimeInterval(8), attempt: 3)
    )
  }

  func testCoordinatorStopsRetryingAtMaximumAttempt() async throws {
    let outbox = RecordingNotificationOutbox(claims: [
      NotificationOutboxClaim(
        leaseID: "lease-final", eventID: "event-1", channelKind: .telegram,
        message: message(), attempt: 3)
    ])
    let coordinator = NotificationDeliveryCoordinator(
      outbox: outbox,
      channels: [
        .telegram: StubNotificationChannel(kind: .telegram, result: .transientFailure)
      ],
      retryPolicy: NotificationRetryPolicy(maxAttempts: 3, baseDelay: 2, maximumDelay: 30)
    )

    try await coordinator.drainOnce()

    let outcomes = await outbox.recordedOutcomes()
    XCTAssertEqual(outcomes.first?.status, .failed)
  }

  func testCoordinatorSurfacesOutboxClaimFailure() async throws {
    let coordinator = NotificationDeliveryCoordinator(
      outbox: ThrowingNotificationOutbox(),
      channels: [:]
    )

    do {
      try await coordinator.drainOnce()
      XCTFail("Expected outbox error")
    } catch {
      XCTAssertEqual(error as? NotificationOutboxTestError, .unavailable)
    }
  }

  private func message(
    title: String = "High CPU", body: String = "CPU stayed above 90% for 5 minutes."
  ) -> NotificationMessage {
    NotificationMessage(
      eventID: "event-1",
      deviceName: "Studio Mac",
      ruleID: "rule-1",
      state: .alert,
      occurredAt: occurredAt,
      title: title,
      body: body,
      metric: NotificationMetricContext(
        id: "cpu.total.busy",
        value: 0.96,
        unit: "percent",
        threshold: 0.90
      )
    )
  }

  private func jsonResponse(
    status: Int,
    object: Any,
    headers: [String: String] = [:]
  ) -> NotificationHTTPResponse {
    NotificationHTTPResponse(
      statusCode: status,
      headers: headers,
      data: try! JSONSerialization.data(withJSONObject: object)
    )
  }
}

private final class NotificationTransportURLProtocol: URLProtocol, @unchecked Sendable {
  enum Mode {
    case redirect(URL)
    case data(Data)
  }

  private static let lock = NSLock()
  private static var mode = Mode.data(Data())
  private static var urls: [URL] = []

  static func configure(_ mode: Mode) {
    lock.lock()
    self.mode = mode
    urls = []
    lock.unlock()
  }

  static func requestedURLs() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return urls
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    Self.lock.lock()
    Self.urls.append(url)
    let mode = Self.mode
    Self.lock.unlock()

    switch mode {
    case .redirect(let target):
      let response = HTTPURLResponse(
        url: url,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString]
      )!
      client?.urlProtocol(
        self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    case .data(let data):
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

private actor RecordingNotificationHTTPTransport: NotificationHTTPTransport {
  private let response: NotificationHTTPResponse?
  private let error: Error?
  private var requests: [URLRequest] = []

  init(response: NotificationHTTPResponse) {
    self.response = response
    self.error = nil
  }

  init(error: Error) {
    self.response = nil
    self.error = error
  }

  static func success() -> RecordingNotificationHTTPTransport {
    RecordingNotificationHTTPTransport(
      response: NotificationHTTPResponse(statusCode: 204, headers: [:], data: Data()))
  }

  func data(for request: URLRequest) async throws -> NotificationHTTPResponse {
    requests.append(request)
    if let error { throw error }
    return response!
  }

  func lastRequest() -> URLRequest? { requests.last }
}

private final class RecordingSecItemClient: SecItemClient, @unchecked Sendable {
  var copyStatus: OSStatus = errSecItemNotFound
  var copyData: Data?
  var addStatus: OSStatus = errSecSuccess
  var updateStatuses: [OSStatus] = [errSecSuccess]
  var deleteStatus: OSStatus = errSecSuccess
  var addedAttributes: [String: Any]?
  var updatedAttributes: [String: Any]?
  var lastCopyQuery: [String: Any]?
  var lastUpdateQuery: [String: Any]?
  var lastDeleteQuery: [String: Any]?
  private(set) var updateCallCount = 0

  func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
    lastCopyQuery = query
    return (copyStatus, copyData)
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    addedAttributes = attributes
    return addStatus
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    updateCallCount += 1
    lastUpdateQuery = query
    updatedAttributes = attributes
    return updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    lastDeleteQuery = query
    return deleteStatus
  }
}

private actor RecordingNotificationOutbox: NotificationOutboxClaiming {
  private var claims: [NotificationOutboxClaim]
  private var outcomes: [NotificationDeliveryOutcome] = []
  private let onAcknowledge: (@Sendable (NotificationDeliveryOutcome) -> Void)?

  init(
    claims: [NotificationOutboxClaim],
    onAcknowledge: (@Sendable (NotificationDeliveryOutcome) -> Void)? = nil
  ) {
    self.claims = claims
    self.onAcknowledge = onAcknowledge
  }

  func claimPending(now: Date) async throws -> [NotificationOutboxClaim] {
    defer { claims = [] }
    return claims
  }

  func acknowledge(_ outcome: NotificationDeliveryOutcome) async throws {
    outcomes.append(outcome)
    onAcknowledge?(outcome)
  }

  func recordedOutcomes() -> [NotificationDeliveryOutcome] { outcomes }
}

private enum NotificationOutboxTestError: Error, Equatable {
  case unavailable
}

private struct ThrowingNotificationOutbox: NotificationOutboxClaiming {
  func claimPending(now: Date) async throws -> [NotificationOutboxClaim] {
    throw NotificationOutboxTestError.unavailable
  }

  func acknowledge(_ outcome: NotificationDeliveryOutcome) async throws {}
}

private final class SequenceNotificationClock: @unchecked Sendable {
  private let lock = NSLock()
  private var dates: [Date]

  init(_ dates: [Date]) { self.dates = dates }

  func next() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return dates.count > 1 ? dates.removeFirst() : dates[0]
  }
}

private actor NotificationChannelGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var isWaiting = false

  func wait() async {
    isWaiting = true
    await withCheckedContinuation { continuation = $0 }
    isWaiting = false
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}

private struct GatedNotificationChannel: NotificationChannel {
  let kind: NotificationChannelKind
  let gate: NotificationChannelGate

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    await gate.wait()
    return NotificationReceipt(kind: kind, eventID: message.eventID)
  }
}

private struct StubNotificationChannel: NotificationChannel {
  enum Result: Sendable {
    case success
    case transientFailure
    case terminalFailure
    case credentialUnavailable
  }

  let kind: NotificationChannelKind
  let result: Result

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    switch result {
    case .success:
      return NotificationReceipt(kind: kind, eventID: message.eventID)
    case .transientFailure:
      throw NotificationDeliveryError.httpStatus(503, retryAfter: nil)
    case .terminalFailure:
      throw NotificationDeliveryError.remoteRejected(code: "denied", retryAfter: nil)
    case .credentialUnavailable:
      throw NotificationDeliveryError.credentialUnavailable
    }
  }
}
