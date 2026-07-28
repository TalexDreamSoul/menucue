# Design: external notification and alert system

## Status

Planning for user review. No implementation is activated.

## Architecture

```text
Existing typed probes/events
  -> AlertObservation adapters
  -> AlertMetricCatalog / AlertRuleEngine
  -> AlertEvent (stable event ID, context variables)
  -> NotificationTemplateRenderer
  -> NotificationMessage
  -> NotificationDeliveryCoordinator
       -> any NotificationChannel (Feishu/Webhook/Bark/Telegram)
       -> NotificationSecretStore (Keychain)
       -> NotificationRuntimeStore (local cursors/outcomes)
```

Views edit typed local configuration through `AppModel` and invoke test/validation intents on a notification settings service. Views never read UserDefaults, Keychain, URLSession responses, or probe values directly.

## Core contracts

### Channel boundary

```swift
protocol NotificationChannel: Sendable {
  var kind: NotificationChannelKind { get }
  func send(_ message: NotificationMessage) async throws -> NotificationReceipt
}
```

Concrete channel instances are constructed from validated non-secret configuration plus secrets loaded at the runtime boundary. `NotificationDeliveryCoordinator` accepts `[any NotificationChannel]`; alert sources never switch on channel kind.

`NotificationMessage` contains stable event ID, device/rule/state metadata, occurred-at timestamp, rendered title/body, and an optional typed metric context. It contains no credentials and no channel-specific payload.

### Rule and metric boundary

```swift
protocol AlertMetricProvider: Sendable {
  var providedMetricIDs: Set<AlertMetricID> { get }
  func sample(_ request: AlertMetricSampleRequest) async -> AlertMetricSample
}

protocol AlertRuleEvaluating {
  mutating func evaluate(_ observation: AlertObservation, at date: Date) -> [AlertTransition]
}
```

The catalog, not the UI, owns metric IDs, units, supported operators, default thresholds/timing, probe ownership, target selectors, and formatting. The editor renders controls from catalog metadata.

### Template boundary

`NotificationTemplateRenderer` parses only `{{identifier}}` tokens against a versioned allowlist. It reports exact unknown-token/range errors and renders from a typed `NotificationVariableContext`. Escaping is the channel encoder's responsibility; template output is plain text.

## Metric catalog

### Direct scalar metrics

- CPU: aggregate busy percent, maximum selected/core busy percent, 1/5/15-minute load average.
- GPU: device and renderer utilization percent; GPU in-use memory bytes when available.
- Memory: used percent; kernel pressure severity; swap used bytes/percent.
- Storage: selected volume used percent/free bytes; aggregate disk read/write bytes per second; read/write operations per second.
- Network: aggregate or selected-interface download/upload bytes per second.
- Sensors: CPU temperature, selected thermal sensor temperature, selected fan RPM/load percent.
- Battery/power: battery level percent, charge/discharge watts, percent per hour when available.

### Event metrics

- Dark wake occurrence, backed by normalized `WakeEvent.id`.

### Explicit exclusions

Top-process/process-energy rankings, sleep assertions, scheduled wakes, wake-history rows, and power profiles are lists or configuration, not stable scalar observations. Treating them as numbers would erase target identity and create misleading generic rules. They require future typed event/list rule kinds.

## Rule state machine

Numeric rule states:

```text
idle -> pendingAlert -> active -> pendingRecovery -> cooldown -> idle
```

- Missing/unavailable/stale samples pause evaluation without advancing durations.
- `pendingAlert` uses wall-clock timestamps, not sample counts.
- Entering `active` emits exactly one logical alert event.
- Recovery uses a separate threshold to provide hysteresis and a required stable duration.
- Entering `cooldown` emits one recovery event.
- A relapse during `pendingRecovery` returns to `active` without another alert.
- Cooldown suppresses new alert events until expiry; observations still update status.

Event rules deduplicate by source event ID and apply cooldown where configured. Persist state transitions and source cursors atomically in `NotificationRuntimeStore`; no transport result may mutate wake history or metric caches.

## Background monitoring

Create an app-lifetime `AlertMonitoringService`, configured from local rules by `AppModel`/controller. It does not retain `SystemMetricsService` or `DashboardMetricsService`, because those services deliberately stop with UI visibility.

The monitor groups enabled metrics by provider and runs only required providers. Cheap counters may share a 15-second base cadence. Expensive GPU/sensor/volume providers use catalog minimum cadences and coalesce rules that need the same sample. Counter-based providers retain private baselines and discard the first unprimed rate sample.

Rule changes reconfigure timers atomically. No metric rules means no timer and no metric probes. Dark wake remains event/backfill driven. Sleep/wake pauses timers and resumes with fresh counter baselines; it never interprets the sleep interval as load.

## Delivery

`NotificationDeliveryCoordinator` creates one durable delivery record for each `(alertEventID, channelKind)`, then fans out with a task group. Outcomes are independent.

Retry only transient transport failures, HTTP 408/429, and 5xx, with capped exponential backoff and bounded `Retry-After`. Mark terminal API/auth/validation failures immediately. Generic Webhook gets `X-MenuCue-Event-ID`; other APIs do not guarantee idempotency, so a lost response can yield a duplicate remote message even though MenuCue keeps one logical delivery record.

Channel adapters:

- Feishu: text payload; optional CryptoKit HMAC signature; require body `code == 0`.
- Webhook: versioned fixed JSON envelope; optional bearer token; accept 2xx.
- Bark: POST JSON to validated base URL/device-key endpoint; require successful Bark response code.
- Telegram: `sendMessage` with chat/thread target; require `ok == true`.

All URLSession errors pass through a redacting typed error mapper. Never expose request URLs containing tokens.

## Persistence and secrets

Non-secret local settings:

- device display name override;
- channel enabled/configured markers and non-secret fields;
- rules and templates.

Keychain items:

- Feishu webhook URL and optional signing secret;
- Webhook bearer token;
- Bark device key;
- Telegram bot token.

A generic Webhook endpoint may itself contain a secret query token; store the full endpoint in Keychain as well. Bark server base URL and Telegram chat/thread IDs remain local settings. None of these fields joins `PortableSettingField` or iCloud envelopes.

Runtime incident/cursor/delivery state is versioned and machine-local under Application Support. Templates and rules use stable UUIDs. Unknown future metric IDs remain visible as unavailable rules so users can repair/delete them rather than silently losing configuration.

## Settings UX

Add a `Notifications` sidebar pane using the existing settings shell.

1. Identity group: editable device name with detected-name reset.
2. Channels group: four compact rows with icon/name, configured state, enable toggle, Configure, and Test. Configuration expands inline or uses a sheet only where secret entry needs focus. Test state remains per channel.
3. Rules group: list rows show name, metric/event, condition summary, runtime status, and enable toggle. Add/edit opens a detail editor; there are no cards inside cards.
4. Rule editor: metric/event picker, target selector when required, operator/threshold/unit, sustain/recovery/cooldown controls, then Alert and Recovery template tabs (event rules omit Recovery).
5. Template editor: title and body fields, searchable variable insertion menu, validation below the field, representative preview, and Reset. Variables unavailable for the chosen metric are not offered.

Use native Picker, Toggle, TextField/SecureField, Stepper, Menu, and tab/segmented controls. Use symbols for row actions with tooltips. Prevent enablement until channel/rule validation succeeds.

## Compatibility and rollout

- macOS 14 deployment floor; use Foundation, Security, CryptoKit, Combine, and SwiftUI only.
- Add no third-party dependency.
- Child 1 transport is independently testable with mock URLProtocol and mock Keychain.
- Child 2 rule engine is independently testable with fake clocks/providers/senders.
- Child 3 wires configuration and UI after both contracts stabilize.
- Rollback removes additive notification files/wiring and local keys; never delete Keychain entries silently on app downgrade. Provide explicit channel credential removal in UI.
