# Design: external notification and alert system

## Status

Planning for user review. No implementation is activated.

## Architecture

```text
Existing typed probes/events
  -> AlertObservation adapters
  -> AlertMetricCatalog / AlertRuleEngine
  -> NotificationTemplateRenderer
  -> NotificationRuntimeStore.atomicCommit(
       rule state + source cursor + rendered NotificationMessage outbox record)
  -> NotificationDeliveryCoordinator.claim(event ID)
       -> any NotificationChannel (Feishu/Webhook/Bark/Telegram)
       -> NotificationSecretStore (Keychain)
       -> NotificationRuntimeStore.ack(per-channel outcome)
```

`NotificationRuntimeStore` is the single durability owner for rule state, source cursors, rendered-message snapshots, outbox claims, attempts, and per-channel acknowledgements. There is no callback-only handoff between a committed rule transition and a pending delivery record.

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

`NotificationTemplateRenderer` parses only `{{identifier}}` tokens against a versioned allowlist. It reports exact unknown-token/range errors and renders from a typed `NotificationVariableContext`. Escaping is the channel encoder's responsibility; template output is plain text. The combined rendered title/newline/body is capped at 4,000 Swift `Character` values, then each adapter validates its final encoded request (including Feishu's 20 KB UTF-8 JSON-body limit and Telegram's 4,096-character text limit).

## Metric catalog

### Direct scalar metrics

The authoritative field-by-field catalog is `research/metric-inventory.md`. Inclusion requires a user-visible, time-varying scalar or ordered value, a stable target identity, a truthful unit, and meaningful incident/recovery semantics.

Included families are:

- CPU: aggregate busy/user/system/idle, per-core busy, and 1/5/15-minute load average.
- GPU: device/renderer utilization and in-use memory.
- Memory: used/app/wired/compressed/cached bytes, used percent, pressure severity, and swap used bytes/percent.
- Storage: selected volume used/free bytes and used percent; aggregate read/write rates and operation rates.
- Network: current-primary and selected-interface download/upload rates.
- Sensors: aggregate CPU and selected thermal temperatures; selected fan RPM/load.
- Battery/power: level, signed flow watts/percent-per-hour, charging state, and AC state.

### Event metrics

- Dark wake occurrence, backed by normalized `WakeEvent.id`.

### Explicit exclusions

Top-process/process-energy rankings, sleep assertions, scheduled wakes, wake-history rows, power profiles, static capacities/hardware facts, monotonic lifetime counters, and presentation-only histories are excluded for the reasons recorded in the inventory.

Before thermal rules ship, `ThermalReading` gains a nonlocalized `sensorID` sourced from the HID cluster identifier or Intel SMC key. `label` remains localized display text. Existing label-based values are never migrated by guessing; an unresolved target is shown as unavailable.

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

Event rules deduplicate by source event ID and apply cooldown where configured. A transition is not considered committed until `NotificationRuntimeStore` atomically writes the next rule state/source cursor and the rendered `NotificationMessage` outbox record together. The coordinator idempotently claims stable event IDs and writes per-channel acknowledgements back to the same store.

Crash behavior is therefore explicit:

- before atomic commit: neither state nor event exists and evaluation may safely repeat;
- after commit/before claim: the event remains pending;
- after claim/before remote result: the claim lease expires and delivery retries;
- after remote acceptance/before acknowledgement: remote duplication remains possible for APIs without idempotency, but the logical event is not lost;
- after acknowledgement: that channel is terminal for the event.

## Background monitoring

Create an app-lifetime `AlertMonitoringService`, configured from local rules by `AppModel`/controller. It does not retain `SystemMetricsService` or `DashboardMetricsService`, because those services deliberately stop with UI visibility.

The monitor groups enabled metrics by provider and runs only required providers. Cheap counters may share a 15-second base cadence. Expensive GPU/sensor/volume providers use catalog minimum cadences and coalesce rules that need the same sample. Counter-based providers retain private baselines and discard the first unprimed rate sample.

Rule changes reconfigure timers atomically. No enabled metric rules means no notification-owned metric timer or probe. Existing opt-in Power history may continue for its own feature.

Wake observation/history reconciliation becomes reference-counted: the existing Power-history feature and enabled dark-wake rules each retain it. Zero references means no wake observer or history timer. Dark-wake-only monitoring runs history reconciliation, never the full profiles/assertions/scheduled-wake refresh. When a normalized post-baseline dark wake is discovered, its state/message outbox transaction commits first, then delivery is attempted immediately; pending work resumes on the next full wake. macOS does not guarantee execution during every dark wake, so “immediate” means as soon as reconciliation discovers the event.

Sleep/wake pauses metric timers and resumes with fresh counter baselines; it never interprets the sleep interval as load.

## Delivery

`NotificationDeliveryCoordinator` idempotently leases pending outbox records, then fans out unacknowledged channels with a task group. Outcomes and retry schedules are independently acknowledged in the same runtime store.

Retry only transient transport failures, HTTP 408/429, and 5xx, with capped exponential backoff and bounded `Retry-After`. Mark terminal API/auth/validation failures immediately. Generic Webhook gets `X-MenuCue-Event-ID`; other APIs do not guarantee idempotency, so a lost response can yield a duplicate remote message even though MenuCue keeps one logical delivery record.

Channel adapters:

- Feishu: text payload; optional CryptoKit HMAC signature; require body `code == 0`.
- Webhook: versioned fixed JSON envelope; optional bearer token; accept 2xx.
- Bark: POST JSON to validated base URL/device-key endpoint; require successful Bark response code.
- Telegram: `sendMessage` with chat/thread target; require `ok == true`.

All adapters use a URLSession whose task delegate rejects redirects by default. A future redirect allowance would require same-origin HTTPS validation and explicit sensitive-header stripping, but no channel in this scope needs it. URLSession and API errors pass through a redacting typed mapper; request URLs containing tokens are never surfaced. Tests cover HTTPS-to-HTTP, cross-host, loop/excess redirects, and token-bearing error paths.

## Persistence and secrets

Non-secret local settings:

- device display name override;
- channel enabled/configured markers and non-secret fields;
- rules and templates.

Keychain items use service namespace `com.tagzxia.app.menucue.notifications`, stable channel/field account identifiers, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and `kSecAttrSynchronizable = false`. This allows app-owned credentials after the first user unlock while keeping them device-local. Tests inspect add/update queries and cover duplicate, missing, locked/access-denied, migration, and corrupt-data behavior.

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
- Rollback removes additive notification code/wiring and stops its workers; never delete Keychain entries silently on app downgrade. Provide explicit channel credential removal in UI.
