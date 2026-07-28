# Notification channel API and platform research

## Sources

- Bark upstream README: <https://github.com/Finb/Bark/blob/master/README.md>
- Feishu custom bot guide (official Markdown): <https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot.md>
- Telegram Bot API: <https://core.telegram.org/bots/api#sendmessage>
- Telegram Bot API server repository: <https://github.com/tdlib/telegram-bot-api>
- Apple Keychain Services: <https://developer.apple.com/documentation/security/keychain-services>
- Project state contract: `.trellis/spec/frontend/state-management.md`

## Verified external contracts

### Bark

Bark accepts GET or POST. The upstream contract supports `key`, `title`, `body`, and optional fields including `group`, `sound`, `icon`, and `level`. It explicitly supports self-hosted servers. MenuCue should use POST JSON so user text never enters a URL path.

Minimum configuration:

- server base URL, default `https://api.day.app`
- device key (secret)
- optional group

The device key must be stored in Keychain. The base URL is non-secret unless the user pastes a full key-bearing URL; the UI should use separate fields and reject path-embedded keys.

### Feishu custom bot

The official guide specifies HTTPS POST with `Content-Type: application/json` and a text payload:

```json
{"msg_type":"text","content":{"text":"request example"}}
```

A successful response uses `code: 0`; HTTP success alone is insufficient. The webhook URL itself is a credential. Optional signing uses a current Unix timestamp and Base64 HMAC-SHA256 with `timestamp + "\n" + secret` as the HMAC key and an empty message. The API body limit is 20 KB and documented limits are 100 requests/minute and 5 requests/second per tenant/bot.

Minimum configuration:

- webhook URL (secret)
- optional signing secret (secret)

### Telegram

The hosted Bot API base is `https://api.telegram.org/bot<token>/`. `sendMessage` requires `chat_id` and `text`; `message_thread_id` is optional for forum topics. The response body uses an `ok` boolean and may include `description` and `parameters.retry_after` on failure.

Minimum configuration:

- bot token (secret)
- chat ID
- optional message thread ID

The bot token must never appear in a logged URL or user-visible raw error.

### Generic Webhook

There is no universal third-party payload contract. MenuCue must own and version a stable JSON envelope rather than exposing arbitrary scripts or raw request templates:

```json
{
  "schema_version": 1,
  "event_id": "...",
  "device_name": "...",
  "rule_id": "...",
  "state": "alert|recovery|test",
  "occurred_at": "ISO-8601",
  "title": "...",
  "body": "...",
  "metric": {
    "id": "...",
    "value": 0,
    "unit": "...",
    "threshold": 0
  }
}
```

Minimum configuration:

- HTTPS endpoint URL
- optional bearer token (secret)

Send `Content-Type: application/json`, `User-Agent: MenuCue/<version>`, and `X-MenuCue-Event-ID`. Arbitrary headers, methods, and body code are out of scope because they turn a notification setting into a request-programming surface with unclear secret handling.

## Keychain and local settings

Apple describes Keychain Services as encrypted storage for small secret values. Store Bark device key, Feishu webhook URL/signing secret, Telegram bot token, and generic Webhook bearer token under stable service/account identifiers. Store only non-secret channel metadata, enablement, rule definitions, device display name, and templates in `AppSettings`/`SettingsStore`.

Follow the project contract:

- views never access `UserDefaults` or Keychain directly;
- `AppModel` owns persisted non-secret setting mutation;
- a notification configuration service owns Keychain writes and runtime validation/test state;
- no notification configuration enters `PortableSettingField` or iCloud sync.

## Existing metric evidence

Current sources provide these threshold-capable values:

- `SystemMetricsSnapshot`: total CPU busy, memory used fraction, primary disk used fraction/read/write rate, aggregate network download/upload rate, fan RPM/load, CPU temperature, battery/power-source context.
- `DashboardSnapshot`/probes: per-core CPU busy, load averages, GPU device/renderer utilization and memory, swap usage, memory pressure, mounted-volume usage, disk operation rates, per-interface network rates, thermal sensors.
- `PowerDiagnosticsSnapshot`: battery level/flow through `BatteryStatus`, wake events, assertion durations, and wake statistics.

Lists such as top processes, sleep assertions, scheduled wakes, wake history rows, and power profiles are not generic scalar metrics. They require event/list-specific rules and are excluded from the first generic threshold catalog except dark wake, which is an explicit event rule.

## Delivery and retry constraints

- Use one logical delivery record per `(eventID, channelKind)`.
- Fan out independently; one channel failure cannot cancel siblings.
- Retry only timeouts, connection loss, HTTP 408/429, and 5xx with bounded exponential delay and a maximum attempt count.
- Respect bounded `Retry-After` where provided.
- A lost response after remote acceptance can still duplicate a message because Feishu, Bark, and Telegram do not expose MenuCue idempotency keys. Document this transport limitation; stable event IDs make generic Webhook receivers deduplicate.
- Never retry validation errors, authentication failures, malformed payloads, or other 4xx responses.
