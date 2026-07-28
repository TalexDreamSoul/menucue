import CryptoKit
import Foundation

// MARK: - Channel-neutral contracts

enum NotificationChannelKind: String, CaseIterable, Codable, Hashable, Sendable {
  case feishu
  case webhook
  case bark
  case telegram
}

enum NotificationEventState: String, Codable, Equatable, Sendable {
  case alert
  case recovery
  case test
}

struct NotificationMetricContext: Codable, Equatable, Sendable {
  let id: String
  let value: Double
  let unit: String
  let threshold: Double
}

struct NotificationMessage: Codable, Equatable, Sendable {
  static let maximumRenderedCharacters = 4_000

  let eventID: String
  let deviceName: String
  let ruleID: String
  let state: NotificationEventState
  let occurredAt: Date
  let title: String
  let body: String
  let metric: NotificationMetricContext?

  var renderedText: String {
    body.isEmpty ? title : "\(title)\n\(body)"
  }

  func validate() throws {
    guard !eventID.isEmpty, !deviceName.isEmpty, !ruleID.isEmpty,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw NotificationDeliveryError.invalidConfiguration
    }
    guard renderedText.count <= Self.maximumRenderedCharacters else {
      throw NotificationDeliveryError.payloadTooLarge
    }
  }
}

struct NotificationReceipt: Equatable, Sendable {
  let kind: NotificationChannelKind
  let eventID: String
}

protocol NotificationChannel: Sendable {
  var kind: NotificationChannelKind { get }
  func send(_ message: NotificationMessage) async throws -> NotificationReceipt
}

enum NotificationDeliveryError: Error, Equatable, Sendable {
  case invalidConfiguration
  case missingSecret
  case credentialUnavailable
  case payloadTooLarge
  case responseTooLarge
  case invalidResponse
  case httpStatus(Int, retryAfter: TimeInterval?)
  case remoteRejected(code: String?, retryAfter: TimeInterval?)
  case timedOut
  case networkUnavailable

  var retryAfter: TimeInterval? {
    switch self {
    case .httpStatus(_, let retryAfter), .remoteRejected(_, let retryAfter):
      return retryAfter
    default:
      return nil
    }
  }

  var isRetryable: Bool {
    switch self {
    case .timedOut, .networkUnavailable, .credentialUnavailable:
      return true
    case .httpStatus(let status, _):
      return status == 408 || status == 429 || (500...599).contains(status)
    case .remoteRejected(_, let retryAfter):
      return retryAfter != nil
    default:
      return false
    }
  }
}

extension NotificationDeliveryError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "The notification channel configuration is invalid."
    case .missingSecret:
      return "A required notification credential is missing."
    case .credentialUnavailable:
      return "The notification credential is temporarily unavailable."
    case .payloadTooLarge:
      return "The notification message is too long."
    case .responseTooLarge:
      return "The notification service returned too much data."
    case .invalidResponse:
      return "The notification service returned an invalid response."
    case .httpStatus(let status, _):
      return "The notification service returned HTTP \(status)."
    case .remoteRejected(let code, _):
      if let code, !code.isEmpty {
        return "The notification service rejected the request (\(code))."
      }
      return "The notification service rejected the request."
    case .timedOut:
      return "The notification request timed out."
    case .networkUnavailable:
      return "The notification service could not be reached."
    }
  }
}

// MARK: - HTTP boundary

struct NotificationHTTPResponse: Equatable, Sendable {
  let statusCode: Int
  let headers: [String: String]
  let data: Data

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

protocol NotificationHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> NotificationHTTPResponse
}

final class RedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  static func redirectedRequest(from original: URLRequest, to proposed: URLRequest) -> URLRequest? {
    nil
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(Self.redirectedRequest(from: task.originalRequest ?? request, to: request))
  }
}

final class URLSessionNotificationHTTPTransport: NotificationHTTPTransport, @unchecked Sendable {
  static let defaultMaximumResponseBytes = 64 * 1_024

  private let delegate: RedirectRejectingSessionDelegate
  private let session: URLSession
  private let maximumResponseBytes: Int

  init(
    timeout: TimeInterval = 15,
    maximumResponseBytes: Int = defaultMaximumResponseBytes,
    configuration: URLSessionConfiguration = .ephemeral
  ) {
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = RedirectRejectingSessionDelegate()
    self.delegate = delegate
    self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    self.maximumResponseBytes = max(1, maximumResponseBytes)
  }

  func data(for request: URLRequest) async throws -> NotificationHTTPResponse {
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw NotificationDeliveryError.invalidResponse
    }
    if response.expectedContentLength > Int64(maximumResponseBytes) {
      throw NotificationDeliveryError.responseTooLarge
    }

    var data = Data()
    data.reserveCapacity(min(maximumResponseBytes, max(0, Int(response.expectedContentLength))))
    for try await byte in bytes {
      guard data.count < maximumResponseBytes else {
        throw NotificationDeliveryError.responseTooLarge
      }
      data.append(byte)
    }

    let headerPairs: [(String, String)] = response.allHeaderFields.compactMap { key, value in
      guard let key = key as? String else { return nil }
      return (key, String(describing: value))
    }
    let headers = Dictionary(uniqueKeysWithValues: headerPairs)
    return NotificationHTTPResponse(statusCode: response.statusCode, headers: headers, data: data)
  }
}

private enum NotificationRequestSupport {
  static let jsonContentType = "application/json"
  static let maximumRequestBytes = 64 * 1_024

  static var userAgent: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return "MenuCue/\(version ?? "dev")"
  }

  static func validateHTTPS(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
      url.user == nil, url.password == nil, url.fragment == nil
    else {
      throw NotificationDeliveryError.invalidConfiguration
    }
  }

  static func request(url: URL, body: Data, headers: [String: String] = [:]) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 15
    request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  static func validateBody(_ data: Data, maximumBytes: Int = maximumRequestBytes) throws {
    guard data.count <= maximumBytes else { throw NotificationDeliveryError.payloadTooLarge }
  }

  static func retryAfter(from response: NotificationHTTPResponse) -> TimeInterval? {
    guard let raw = response.header("Retry-After"), let value = TimeInterval(raw), value >= 0 else {
      return nil
    }
    return value
  }

  static func validateSuccess(_ response: NotificationHTTPResponse) throws {
    guard (200...299).contains(response.statusCode) else {
      throw NotificationDeliveryError.httpStatus(
        response.statusCode,
        retryAfter: retryAfter(from: response)
      )
    }
  }

  static func mapped(_ error: Error) -> NotificationDeliveryError {
    if let error = error as? NotificationDeliveryError { return error }
    if let error = error as? URLError, error.code == .timedOut { return .timedOut }
    return .networkUnavailable
  }

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    do { return try JSONEncoder().encode(value) } catch {
      throw NotificationDeliveryError.invalidConfiguration
    }
  }
}

// MARK: - Generic Webhook

struct WebhookNotificationConfiguration: Equatable, Sendable {
  let endpoint: URL
  let bearerToken: String?
}

struct WebhookNotificationChannel: NotificationChannel {
  let kind = NotificationChannelKind.webhook
  private let configuration: WebhookNotificationConfiguration
  private let transport: any NotificationHTTPTransport

  init(
    configuration: WebhookNotificationConfiguration,
    transport: any NotificationHTTPTransport = URLSessionNotificationHTTPTransport()
  ) throws {
    try NotificationRequestSupport.validateHTTPS(configuration.endpoint)
    if let token = configuration.bearerToken,
      token.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 })
    {
      throw NotificationDeliveryError.invalidConfiguration
    }
    self.configuration = configuration
    self.transport = transport
  }

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    try message.validate()
    let body = try NotificationRequestSupport.encode(WebhookEnvelope(message: message))
    try NotificationRequestSupport.validateBody(body)
    var headers = ["X-MenuCue-Event-ID": message.eventID]
    if let token = configuration.bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    {
      headers["Authorization"] = "Bearer \(token)"
    }
    let request = NotificationRequestSupport.request(
      url: configuration.endpoint,
      body: body,
      headers: headers
    )
    do {
      let response = try await transport.data(for: request)
      try NotificationRequestSupport.validateSuccess(response)
      return NotificationReceipt(kind: kind, eventID: message.eventID)
    } catch {
      throw NotificationRequestSupport.mapped(error)
    }
  }
}

private struct WebhookEnvelope: Encodable {
  let schemaVersion = 1
  let eventID: String
  let deviceName: String
  let ruleID: String
  let state: NotificationEventState
  let occurredAt: String
  let title: String
  let body: String
  let metric: NotificationMetricContext?

  init(message: NotificationMessage) {
    eventID = message.eventID
    deviceName = message.deviceName
    ruleID = message.ruleID
    state = message.state
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    occurredAt = formatter.string(from: message.occurredAt)
    title = message.title
    body = message.body
    metric = message.metric
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case eventID = "event_id"
    case deviceName = "device_name"
    case ruleID = "rule_id"
    case state
    case occurredAt = "occurred_at"
    case title
    case body
    case metric
  }
}

// MARK: - Feishu

struct FeishuNotificationConfiguration: Equatable, Sendable {
  let webhookURL: URL
  let signingSecret: String?
}

struct FeishuNotificationChannel: NotificationChannel {
  let kind = NotificationChannelKind.feishu
  private let configuration: FeishuNotificationConfiguration
  private let transport: any NotificationHTTPTransport
  private let timestamp: @Sendable () -> Int64

  init(
    configuration: FeishuNotificationConfiguration,
    transport: any NotificationHTTPTransport = URLSessionNotificationHTTPTransport(),
    timestamp: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
  ) throws {
    try NotificationRequestSupport.validateHTTPS(configuration.webhookURL)
    let hookPrefix = "/open-apis/bot/v2/hook/"
    let hookToken = configuration.webhookURL.path.dropFirst(hookPrefix.count)
    guard configuration.webhookURL.host?.lowercased() == "open.feishu.cn",
      configuration.webhookURL.path.hasPrefix(hookPrefix),
      !hookToken.isEmpty, !hookToken.contains("/"),
      configuration.webhookURL.query == nil
    else {
      throw NotificationDeliveryError.invalidConfiguration
    }
    self.configuration = configuration
    self.transport = transport
    self.timestamp = timestamp
  }

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    try message.validate()
    let now = timestamp()
    let signature = configuration.signingSecret.flatMap { secret in
      Self.signature(timestamp: now, secret: secret)
    }
    let payload = FeishuPayload(
      content: .init(text: message.renderedText),
      timestamp: signature == nil ? nil : String(now),
      sign: signature
    )
    let body = try NotificationRequestSupport.encode(payload)
    try NotificationRequestSupport.validateBody(body, maximumBytes: 20 * 1_024)
    let request = NotificationRequestSupport.request(url: configuration.webhookURL, body: body)

    do {
      let response = try await transport.data(for: request)
      try NotificationRequestSupport.validateSuccess(response)
      let result = try JSONDecoder().decode(FeishuResponse.self, from: response.data)
      guard result.code == 0 else {
        throw NotificationDeliveryError.remoteRejected(
          code: String(result.code),
          retryAfter: nil
        )
      }
      return NotificationReceipt(kind: kind, eventID: message.eventID)
    } catch {
      if error is DecodingError { throw NotificationDeliveryError.invalidResponse }
      throw NotificationRequestSupport.mapped(error)
    }
  }

  static func signature(timestamp: Int64, secret: String) -> String? {
    guard !secret.isEmpty else { return nil }
    let key = SymmetricKey(data: Data("\(timestamp)\n\(secret)".utf8))
    let code = HMAC<SHA256>.authenticationCode(for: Data(), using: key)
    return Data(code).base64EncodedString()
  }
}

private struct FeishuPayload: Encodable {
  struct Content: Encodable { let text: String }
  let messageType = "text"
  let content: Content
  let timestamp: String?
  let sign: String?

  private enum CodingKeys: String, CodingKey {
    case messageType = "msg_type"
    case content
    case timestamp
    case sign
  }
}

private struct FeishuResponse: Decodable {
  let code: Int
}

// MARK: - Bark

struct BarkNotificationConfiguration: Equatable, Sendable {
  let serverBaseURL: URL
  let deviceKey: String
  let group: String?
}

struct BarkNotificationChannel: NotificationChannel {
  let kind = NotificationChannelKind.bark
  private let configuration: BarkNotificationConfiguration
  private let endpoint: URL
  private let transport: any NotificationHTTPTransport

  init(
    configuration: BarkNotificationConfiguration,
    transport: any NotificationHTTPTransport = URLSessionNotificationHTTPTransport()
  ) throws {
    try NotificationRequestSupport.validateHTTPS(configuration.serverBaseURL)
    guard configuration.serverBaseURL.query == nil,
      !configuration.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw NotificationDeliveryError.invalidConfiguration
    }
    self.configuration = configuration
    self.endpoint = configuration.serverBaseURL.appendingPathComponent("push")
    self.transport = transport
  }

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    try message.validate()
    let body = try NotificationRequestSupport.encode(
      BarkPayload(
        deviceKey: configuration.deviceKey,
        title: message.title,
        body: message.body,
        group: configuration.group
      ))
    try NotificationRequestSupport.validateBody(body)
    let request = NotificationRequestSupport.request(url: endpoint, body: body)
    do {
      let response = try await transport.data(for: request)
      try NotificationRequestSupport.validateSuccess(response)
      let result = try JSONDecoder().decode(BarkResponse.self, from: response.data)
      guard result.code == 200 else {
        throw NotificationDeliveryError.remoteRejected(
          code: String(result.code),
          retryAfter: nil
        )
      }
      return NotificationReceipt(kind: kind, eventID: message.eventID)
    } catch {
      if error is DecodingError { throw NotificationDeliveryError.invalidResponse }
      throw NotificationRequestSupport.mapped(error)
    }
  }
}

private struct BarkPayload: Encodable {
  let deviceKey: String
  let title: String
  let body: String
  let group: String?

  private enum CodingKeys: String, CodingKey {
    case deviceKey = "device_key"
    case title
    case body
    case group
  }
}

private struct BarkResponse: Decodable { let code: Int }

// MARK: - Telegram

struct TelegramNotificationConfiguration: Equatable, Sendable {
  let botToken: String
  let chatID: String
  let messageThreadID: Int?
}

struct TelegramNotificationChannel: NotificationChannel {
  let kind = NotificationChannelKind.telegram
  private let configuration: TelegramNotificationConfiguration
  private let endpoint: URL
  private let transport: any NotificationHTTPTransport

  init(
    configuration: TelegramNotificationConfiguration,
    transport: any NotificationHTTPTransport = URLSessionNotificationHTTPTransport()
  ) throws {
    let token = configuration.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let chatID = configuration.chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    let tokenParts = token.split(separator: ":", omittingEmptySubsequences: false)
    let tokenIsValid =
      tokenParts.count == 2
      && !tokenParts[0].isEmpty
      && !tokenParts[1].isEmpty
      && tokenParts[0].utf8.allSatisfy { (48...57).contains($0) }
      && tokenParts[1].utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 95
      }
    guard tokenIsValid, !chatID.isEmpty,
      configuration.messageThreadID.map({ $0 > 0 }) ?? true,
      let endpoint = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")
    else {
      throw NotificationDeliveryError.invalidConfiguration
    }
    self.configuration = configuration
    self.endpoint = endpoint
    self.transport = transport
  }

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    try message.validate()
    guard message.renderedText.count <= 4_096 else {
      throw NotificationDeliveryError.payloadTooLarge
    }
    let body = try NotificationRequestSupport.encode(
      TelegramPayload(
        chatID: configuration.chatID,
        text: message.renderedText,
        messageThreadID: configuration.messageThreadID
      ))
    try NotificationRequestSupport.validateBody(body)
    let request = NotificationRequestSupport.request(url: endpoint, body: body)
    do {
      let response = try await transport.data(for: request)
      let result = try? JSONDecoder().decode(TelegramResponse.self, from: response.data)
      guard (200...299).contains(response.statusCode) else {
        throw NotificationDeliveryError.httpStatus(
          response.statusCode,
          retryAfter: NotificationRequestSupport.retryAfter(from: response)
            ?? result?.parameters?.retryAfter.map(TimeInterval.init)
        )
      }
      guard let result else { throw NotificationDeliveryError.invalidResponse }
      guard result.ok else {
        throw NotificationDeliveryError.remoteRejected(
          code: result.errorCode.map(String.init),
          retryAfter: result.parameters?.retryAfter.map(TimeInterval.init)
        )
      }
      return NotificationReceipt(kind: kind, eventID: message.eventID)
    } catch {
      if error is DecodingError { throw NotificationDeliveryError.invalidResponse }
      throw NotificationRequestSupport.mapped(error)
    }
  }
}

private struct TelegramPayload: Encodable {
  let chatID: String
  let text: String
  let messageThreadID: Int?

  private enum CodingKeys: String, CodingKey {
    case chatID = "chat_id"
    case text
    case messageThreadID = "message_thread_id"
  }
}

private struct TelegramResponse: Decodable {
  struct Parameters: Decodable {
    let retryAfter: Int?
    private enum CodingKeys: String, CodingKey { case retryAfter = "retry_after" }
  }

  let ok: Bool
  let errorCode: Int?
  let parameters: Parameters?

  private enum CodingKeys: String, CodingKey {
    case ok
    case errorCode = "error_code"
    case parameters
  }
}

// MARK: - Factory

enum NotificationChannelDescriptor: Sendable {
  case feishu(webhookKey: NotificationSecretKey, signingSecretKey: NotificationSecretKey?)
  case webhook(endpointKey: NotificationSecretKey, bearerTokenKey: NotificationSecretKey?)
  case bark(serverBaseURL: URL, deviceKey: NotificationSecretKey, group: String?)
  case telegram(tokenKey: NotificationSecretKey, chatID: String, messageThreadID: Int?)
}

enum NotificationChannelFactory {
  static func make(
    _ descriptor: NotificationChannelDescriptor,
    secrets: any NotificationSecretStoring,
    transport: any NotificationHTTPTransport = URLSessionNotificationHTTPTransport()
  ) throws -> any NotificationChannel {
    switch descriptor {
    case .feishu(let webhookKey, let signingSecretKey):
      let webhook = try requiredSecret(webhookKey, from: secrets)
      guard let url = URL(string: webhook) else {
        throw NotificationDeliveryError.invalidConfiguration
      }
      let signingSecret = try signingSecretKey.flatMap { try secrets.string(for: $0) }
      return try FeishuNotificationChannel(
        configuration: .init(webhookURL: url, signingSecret: signingSecret),
        transport: transport
      )
    case .webhook(let endpointKey, let bearerTokenKey):
      let endpoint = try requiredSecret(endpointKey, from: secrets)
      guard let url = URL(string: endpoint) else {
        throw NotificationDeliveryError.invalidConfiguration
      }
      let bearer = try bearerTokenKey.flatMap { try secrets.string(for: $0) }
      return try WebhookNotificationChannel(
        configuration: .init(endpoint: url, bearerToken: bearer),
        transport: transport
      )
    case .bark(let serverBaseURL, let deviceKey, let group):
      return try BarkNotificationChannel(
        configuration: .init(
          serverBaseURL: serverBaseURL,
          deviceKey: try requiredSecret(deviceKey, from: secrets),
          group: group
        ),
        transport: transport
      )
    case .telegram(let tokenKey, let chatID, let messageThreadID):
      return try TelegramNotificationChannel(
        configuration: .init(
          botToken: try requiredSecret(tokenKey, from: secrets),
          chatID: chatID,
          messageThreadID: messageThreadID
        ),
        transport: transport
      )
    }
  }

  private static func requiredSecret(
    _ key: NotificationSecretKey,
    from store: any NotificationSecretStoring
  ) throws -> String {
    guard let value = try store.string(for: key), !value.isEmpty else {
      throw NotificationDeliveryError.missingSecret
    }
    return value
  }
}

// MARK: - Outbox delivery coordinator

struct NotificationOutboxClaim: Equatable, Sendable {
  let leaseID: String
  let eventID: String
  let channelKind: NotificationChannelKind
  let message: NotificationMessage
  let attempt: Int
}

enum NotificationDeliveryStatus: Equatable, Sendable {
  case delivered
  case retryScheduled(at: Date, attempt: Int)
  case failed
}

struct NotificationDeliveryOutcome: Equatable, Sendable {
  let leaseID: String
  let eventID: String
  let channelKind: NotificationChannelKind
  let status: NotificationDeliveryStatus
}

protocol NotificationOutboxClaiming: Sendable {
  func claimPending(now: Date) async throws -> [NotificationOutboxClaim]
  func acknowledge(_ outcome: NotificationDeliveryOutcome) async throws
}

struct NotificationRetryPolicy: Equatable, Sendable {
  let maxAttempts: Int
  let baseDelay: TimeInterval
  let maximumDelay: TimeInterval

  init(maxAttempts: Int = 3, baseDelay: TimeInterval = 2, maximumDelay: TimeInterval = 60) {
    self.maxAttempts = max(1, maxAttempts)
    self.baseDelay = max(0, baseDelay)
    self.maximumDelay = max(0, maximumDelay)
  }

  func delay(after attempt: Int, requested: TimeInterval?) -> TimeInterval {
    if let requested { return min(maximumDelay, max(0, requested)) }
    let exponent = max(0, attempt - 1)
    return min(maximumDelay, baseDelay * pow(2, Double(exponent)))
  }
}

struct NotificationDeliveryCoordinator: Sendable {
  private let outbox: any NotificationOutboxClaiming
  private let channels: [NotificationChannelKind: any NotificationChannel]
  private let retryPolicy: NotificationRetryPolicy
  private let now: @Sendable () -> Date

  init(
    outbox: any NotificationOutboxClaiming,
    channels: [NotificationChannelKind: any NotificationChannel],
    retryPolicy: NotificationRetryPolicy = NotificationRetryPolicy(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.outbox = outbox
    self.channels = channels
    self.retryPolicy = retryPolicy
    self.now = now
  }

  func drainOnce() async throws {
    let claims = try await outbox.claimPending(now: now())
    guard !claims.isEmpty else { return }

    var firstAcknowledgementError: Error?
    await withTaskGroup(of: NotificationDeliveryOutcome.self) { group in
      for claim in claims {
        group.addTask { await outcome(for: claim) }
      }
      for await outcome in group {
        do { try await outbox.acknowledge(outcome) } catch {
          if firstAcknowledgementError == nil { firstAcknowledgementError = error }
        }
      }
    }
    if let firstAcknowledgementError { throw firstAcknowledgementError }
  }

  private func outcome(
    for claim: NotificationOutboxClaim
  ) async -> NotificationDeliveryOutcome {
    let status: NotificationDeliveryStatus
    guard let channel = channels[claim.channelKind] else {
      return NotificationDeliveryOutcome(
        leaseID: claim.leaseID,
        eventID: claim.eventID,
        channelKind: claim.channelKind,
        status: .failed
      )
    }

    do {
      _ = try await channel.send(claim.message)
      status = .delivered
    } catch {
      let failure = NotificationRequestSupport.mapped(error)
      if failure == .credentialUnavailable {
        let delay = retryPolicy.delay(after: claim.attempt, requested: nil)
        status = .retryScheduled(at: now().addingTimeInterval(delay), attempt: claim.attempt)
      } else if failure.isRetryable, claim.attempt < retryPolicy.maxAttempts {
        let nextAttempt = claim.attempt + 1
        let delay = retryPolicy.delay(after: claim.attempt, requested: failure.retryAfter)
        status = .retryScheduled(at: now().addingTimeInterval(delay), attempt: nextAttempt)
      } else {
        status = .failed
      }
    }

    return NotificationDeliveryOutcome(
      leaseID: claim.leaseID,
      eventID: claim.eventID,
      channelKind: claim.channelKind,
      status: status
    )
  }
}
