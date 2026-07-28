# Design: notification transport

## Boundaries

Add notification transport models/protocols, a Keychain secret store, a URLSession client abstraction, four channel adapters, a channel factory, and a delivery coordinator. Keep AppSettings/UI/rule models outside this module.

Core shapes:

```swift
struct NotificationMessage: Sendable, Equatable { /* no secrets */ }
protocol NotificationChannel: Sendable {
  var kind: NotificationChannelKind { get }
  func send(_ message: NotificationMessage) async throws -> NotificationReceipt
}
protocol NotificationSecretStoring { /* data by stable account key */ }
protocol NotificationHTTPTransport { func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) }
protocol NotificationOutboxClaiming {
  func claimPending(now: Date) async throws -> [NotificationOutboxClaim] // includes leaseID
  func acknowledge(_ outcome: NotificationDeliveryOutcome) async throws // echoes leaseID
}
```

Concrete channels are initialized only after typed validation. The factory resolves Keychain references and returns type-erased protocol values.

## Channel contracts

- Feishu: Keychain stores full webhook URL and optional signing secret. Encode plain text as title + newline + body. Use CryptoKit HMAC when configured. Decode body `code` and `msg`.
- Webhook: Keychain stores full endpoint and optional bearer token. Encode schema-v1 envelope and event-ID header. Any 2xx succeeds.
- Bark: settings store base URL/group; Keychain stores device key. POST JSON with key/title/body/group. Decode Bark application result.
- Telegram: Keychain stores bot token; settings store chat/thread IDs. POST form or JSON to fixed hosted API method and decode `ok`/description/retry parameters.

All response/error mapping strips endpoint/token/key values before constructing descriptions. A URLSession data-byte stream is cancelled as soon as it exceeds the response cap; `Content-Length` above the cap fails before body consumption. Permit only HTTPS and reject URL user-info/fragments. A URLSession task delegate rejects every redirect; no scoped channel requires redirects.

## Delivery state

The coordinator idempotently leases pending messages from `NotificationOutboxClaiming`, fans out only unacknowledged channels, and echoes the exact lease ID in every acknowledgement so the concrete store can reject stale workers after lease expiry/reclaim. It records success or terminal/transient failure by `(eventID, kind, leaseID)`. The concrete atomic store is supplied by the rule/monitor child; transport tests use a crash-aware fake. A fake retry clock makes backoff tests deterministic. Never hold Keychain data in receipts or durable delivery state.

Keychain writes use update-first. An item-not-found result falls back to add; a concurrent add winner (`errSecDuplicateItem`) retries update. This avoids check-then-add races while preserving the fixed service/accessibility/synchronizable attributes.

Keychain uses service `com.tagzxia.app.menucue.notifications`, stable channel/field accounts, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and `kSecAttrSynchronizable = false`. Tests assert complete SecItem query attributes rather than merely mocking successful reads.

## Compatibility

Use Foundation, Security, and CryptoKit only; no package additions. Stable protocols let tests and later channels avoid changing rule sources.
