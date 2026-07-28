# Configurable external notification channels and alert rules

## Goal

Let users identify each Mac, create metric/event alert rules, customize variable-based alert text, and deliver matching alerts through independently enabled Feishu, generic Webhook, Bark, and Telegram channels.

## Background

- MenuCue already exposes typed system, Dashboard, battery, power, and normalized sleep/wake data.
- Existing UI metric services are visibility-scoped; reliable remote alerts require a separate low-cadence background monitor that runs only for enabled rules.
- Existing NapWatch planning deferred abnormal-wake notifications to a separate feature.
- The repository currently has no outbound notification channel, Keychain credential store, alert rule engine, or notification settings UI.
- The user explicitly requested a channel interface, multiple concurrent channels, a configurable device name for multi-Mac identification, all available metrics in a rule editor, and editable notification variables.

## Product Decisions

- Feishu, generic Webhook, Bark, and Telegram are all implemented in this delivery.
- Channels are independently enabled and matching alerts fan out concurrently with isolated outcomes.
- Users can override the local Mac name shown in notifications.
- The rule editor is catalog-driven and covers the complete reviewed set of user-visible, time-varying scalar/ordered values with stable identity, truthful units, and meaningful incident semantics; the authoritative include/exclude inventory is `research/metric-inventory.md`.
- Dark wake is included as an event rule. Once a normalized dark-wake event is discovered, MenuCue atomically queues it and immediately attempts delivery; unavailable execution/network is retried on the next full wake.
- CPU/GPU and other metric rules continue low-cadence monitoring while the UI is closed, but only while at least one metric rule is enabled.
- Metric incidents send one alert after the sustained threshold is met and one recovery after the recovery condition remains stable.
- Alert and recovery title/body templates are edited per rule through one channel-neutral variable editor.

## Requirements

### Shared contracts

- Define typed interfaces for notification channels, metric providers/catalog entries, alert rules/evaluation, template rendering, secret storage, and runtime-state persistence.
- Channel implementations accept a rendered `NotificationMessage`; they do not import wake, Dashboard, or settings-view models.
- Rule evaluation consumes typed metric/event observations and commits stable logical alert events to a durable outbox; it does not perform network delivery.
- Rule runtime transitions, source cursors, rendered message snapshots, and new outbox records commit in one atomic store transaction so a crash cannot create a lost-event window.
- One coordinator idempotently claims outbox records, owns per-channel fan-out, transient retry, outcome aggregation, acknowledgement, and credential redaction.

### Channels and credentials

- Implement Feishu custom bot, versioned generic Webhook JSON, Bark, and Telegram Bot API senders.
- Support configure, validate, enable/disable, and test actions independently for each channel.
- Store secret-bearing values in macOS Keychain with an app-owned service/account namespace, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and `kSecAttrSynchronizable = false`; store only non-secret metadata in local settings.
- Require HTTPS endpoints and reject redirects by default so credentials cannot cross scheme/origin. Use fixed methods/payloads and bounded URLSession timeouts; arbitrary scripts/request code are not allowed.
- Never place secrets in logs, errors, iCloud, analytics, notification history, or test fixtures.

### Alert rules and monitoring

- Implement the exact Included catalog from `research/metric-inventory.md`; it covers aggregate/per-core CPU, load average, GPU utilization/memory, memory usage/pressure, swap, disk/volume capacity and I/O rates, aggregate/per-interface network rates, CPU/thermal temperatures, fan RPM/load, battery state/level/flow, and AC state.
- Add a nonlocalized, cross-launch `ThermalReading.sensorID` before thermal rules; localized labels remain display-only and legacy/unknown targets become unavailable rather than being guessed.
- Catalog entries define stable ID, localized name, value type, unit, comparison operators, source/probe, target selector where needed, availability, default sampling cadence, and formatting.
- Exclude the reviewed fields in the inventory when they are static denominators, monotonic counters, presentation derivatives, dynamic ranked identities, lists, or configuration. Add future domain-specific rule kinds instead of coercing them into generic scalars.
- Support numeric above/below rules, categorical severity rules where applicable, and dark-wake event rules.
- Numeric rules configure threshold, sustained duration, recovery threshold/duration, and cooldown; event rules configure cooldown/deduplication.
- Probe only metrics required by enabled rules. Unsupported or unavailable values produce no false alert and surface an availability state in Settings.
- Persist runtime state and delivery records in one versioned atomic outbox store so refresh, relaunch, repeated wake backfill, retry, or a crash between state transition and delivery handoff cannot lose or recreate a logical event.
- Dark-wake monitoring is reference-counted by the existing Power-history feature and enabled dark-wake rules. With neither active, no wake observer/history timer runs; with only dark-wake rules active, reconciliation must not run full profiles/assertions diagnostics.
- Existing opt-in Power history may continue background reconciliation independently; no enabled notification metric rules means no notification-owned metric timer/probe work.

### Templates and identity

- Default device name from the local Mac name with a hostname fallback; allow a local override.
- Each rule has alert title/body templates; metric rules also have recovery title/body templates.
- Support a fixed variable allowlist with insertion controls, validation, representative preview, and reset defaults.
- Universal variables include app name, device name, rule name, state, event ID, event time, metric name/value/unit, threshold, duration, and recovery duration; event-specific variables such as wake reason are available only when valid.
- Unknown variables, invalid nesting, and output over the channel-neutral size limit prevent saving/enabling the rule.
- Templates interpolate values only; they cannot execute code, access files, perform conditionals, or author network payloads.

### Settings UI

- Add a dedicated Notifications settings pane using existing sidebar, `SettingsGroup`, form-control, localization, and accessibility conventions.
- Keep channel rows compact with status, enable toggle, configure, and test actions; secrets are masked and never loaded into ordinary labels.
- Provide a rule list plus inline/detail editor for metric/event selection, target, comparison, thresholds, timing, cooldown, and alert/recovery templates.
- Provide loading, unavailable, validating, testing, success, failure, empty, and disabled states without nested cards.
- Add English and Simplified Chinese localization for all new user-visible strings.

## Child Tasks

- `07-28-notification-transport`: shared message/channel contracts, Keychain store, four concrete senders, fan-out coordinator, retries, and delivery tests.
- `07-28-metric-alert-rules`: metric catalog, template parser/renderer, targeted background probes, rule state machine, atomic runtime/outbox store, dark-wake bridge, and rule tests.
- `07-28-notification-settings-ui`: device identity, channel/rule persistence, settings pane, channel forms, rule/template editors, preview, and localization.

Implementation order is transport, then rules, then UI/integration. The parent owns final cross-child verification.

## Out of Scope

- Arbitrary shell commands, scripts, expression execution, custom HTTP methods, raw request bodies, or unrestricted custom headers.
- Multiple configurations of the same channel kind in the first release; users can enable all four kinds concurrently.
- Local macOS notification delivery/permission.
- Cloud syncing of device identity, channels, secrets, rules, templates, incidents, or outcomes.
- Generic rules over dynamic process rankings, assertions, scheduled wakes, power settings, or other list/configuration values.
- A production server, account system, or cross-device configuration sync.

## Acceptance Criteria

- [ ] All three child tasks meet their acceptance criteria and integration dependencies.
- [ ] Alert/rule code depends only on notification interfaces, never concrete channel types.
- [ ] Feishu, generic Webhook, Bark, and Telegram can be configured, enabled concurrently, and tested independently.
- [ ] Keychain contains secret fields under the defined non-synchronizable ThisDeviceOnly accessibility policy; local settings and iCloud projections contain none.
- [ ] The literal expected metric-ID test matches every Included row in `research/metric-inventory.md`, and each entry has a stable target, unit, source, availability behavior, comparison semantics, and focused test.
- [ ] Thermal targets survive language changes through a nonlocalized sensor ID and unknown targets become unavailable.
- [ ] Enabled metric rules monitor with the UI closed; no enabled metric rules cause no notification-owned metric probes.
- [ ] Dark-wake observer/reconciliation work is reference-counted, queues discovered events atomically, attempts immediate delivery, and resumes pending delivery on full wake.
- [ ] Crash-injection tests at every state/outbox/claim/ack boundary prove no logical alert is lost or created twice.
- [ ] One logical event fans out to every enabled channel; failures and retries are isolated per channel and secrets stay redacted.
- [ ] Device naming and variable-aware alert/recovery template editing, validation, preview, insertion, and reset work in Settings.
- [ ] Redirect, redaction, UTF-8 payload-size, Keychain access-denied/locked, and cross-channel mixed-failure tests pass without leaking secrets.
- [ ] Existing wake history, visible Dashboard sampling, iCloud synchronization, and app launch behavior remain intact.
- [ ] `swift test`, `./scripts/verify-localizations.swift`, `./scripts/build-app.sh`, and packaged codesign verification pass.
