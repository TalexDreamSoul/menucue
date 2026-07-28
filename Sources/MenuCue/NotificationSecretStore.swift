import Foundation
import Security

struct NotificationSecretKey: Hashable, Sendable {
  let channel: NotificationChannelKind
  let field: String

  var account: String { "\(channel.rawValue).\(field)" }
}

enum NotificationSecretStoreError: Error, Equatable, Sendable {
  case invalidValue
  case keychainFailure(status: OSStatus)
}

extension NotificationSecretStoreError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidValue:
      return "The stored notification credential is invalid."
    case .keychainFailure:
      return "The notification credential could not be accessed."
    }
  }
}

protocol NotificationSecretStoring: Sendable {
  func data(for key: NotificationSecretKey) throws -> Data?
  func set(_ data: Data, for key: NotificationSecretKey) throws
  func remove(_ key: NotificationSecretKey) throws
}

extension NotificationSecretStoring {
  func string(for key: NotificationSecretKey) throws -> String? {
    guard let data = try data(for: key) else { return nil }
    guard let value = String(data: data, encoding: .utf8) else {
      throw NotificationSecretStoreError.invalidValue
    }
    return value
  }

  func setString(_ value: String, for key: NotificationSecretKey) throws {
    guard let data = value.data(using: .utf8) else {
      throw NotificationSecretStoreError.invalidValue
    }
    try set(data, for: key)
  }
}

protocol SecItemClient: Sendable {
  func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemSecItemClient: SecItemClient, Sendable {
  func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result as? Data)
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    SecItemAdd(attributes as CFDictionary, nil)
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    SecItemDelete(query as CFDictionary)
  }
}

struct KeychainNotificationSecretStore: NotificationSecretStoring, Sendable {
  static let service = "com.tagzxia.app.menucue.notifications"

  private let client: any SecItemClient

  init(client: any SecItemClient = SystemSecItemClient()) {
    self.client = client
  }

  func data(for key: NotificationSecretKey) throws -> Data? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, data) = client.copyMatching(query)
    switch status {
    case errSecSuccess:
      guard let data else { throw NotificationSecretStoreError.invalidValue }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw NotificationSecretStoreError.keychainFailure(status: status)
    }
  }

  func set(_ data: Data, for key: NotificationSecretKey) throws {
    guard !data.isEmpty else { throw NotificationSecretStoreError.invalidValue }
    let query = baseQuery(for: key)
    let updateAttributes: [String: Any] = [
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
      kSecValueData as String: data,
    ]

    let updateStatus = client.update(query, attributes: updateAttributes)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addAttributes = query
      for (key, value) in updateAttributes { addAttributes[key] = value }
      let addStatus = client.add(addAttributes)
      if addStatus == errSecDuplicateItem {
        let retryStatus = client.update(query, attributes: updateAttributes)
        guard retryStatus == errSecSuccess else {
          throw NotificationSecretStoreError.keychainFailure(status: retryStatus)
        }
        return
      }
      guard addStatus == errSecSuccess else {
        throw NotificationSecretStoreError.keychainFailure(status: addStatus)
      }
    default:
      throw NotificationSecretStoreError.keychainFailure(status: updateStatus)
    }
  }

  func remove(_ key: NotificationSecretKey) throws {
    let status = client.delete(baseQuery(for: key))
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NotificationSecretStoreError.keychainFailure(status: status)
    }
  }

  private func baseQuery(for key: NotificationSecretKey) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: key.account,
      kSecAttrSynchronizable as String: false,
    ]
  }
}

final class InMemoryNotificationSecretStore: NotificationSecretStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [NotificationSecretKey: Data] = [:]

  func data(for key: NotificationSecretKey) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  func set(_ data: Data, for key: NotificationSecretKey) throws {
    guard !data.isEmpty else { throw NotificationSecretStoreError.invalidValue }
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
