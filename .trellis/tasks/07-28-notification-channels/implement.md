# Implementation plan: external notification and alert system

## Status

Planning for user review. Start child tasks, not this parent.

## Delivery order

### 1. Notification transport and secure configuration

Owns `07-28-notification-transport`.

- RED: lock message/config/error/receipt contracts; request/response fixtures for all four APIs; Keychain and retry tests.
- GREEN: implement secret store, HTTP client boundary, four channels, channel factory, and independent fan-out coordinator.
- REFACTOR: centralize status/body limits, redaction, URL validation, retry classification, and JSON encoding.

Gate:

```sh
swift test --filter NotificationChannel
swift test --filter NotificationSecret
swift test --filter NotificationDelivery
```

### 2. Metric rules and background monitor

Owns `07-28-metric-alert-rules`; depends on transport contracts, but tests use fake channels.

- RED: catalog completeness, value normalization, rule state transitions, timestamps, hysteresis, recovery, cooldown, relaunch, unavailable samples, dark-wake dedup, and targeted-provider lifecycle.
- GREEN: implement catalog, providers/adapters, rule engine, runtime store, monitor scheduling, template context events, and wake bridge.
- REFACTOR: ensure probes are grouped/coalesced and first counter-rate samples cannot alert.

Gate:

```sh
swift test --filter AlertMetric
swift test --filter AlertRule
swift test --filter AlertMonitoring
swift test --filter DarkWakeAlert
```

### 3. Settings and template editor

Owns `07-28-notification-settings-ui`; depends on both previous children.

- RED: non-secret persistence, device-name fallback, template parser/renderer, supported-variable filtering, settings pane routing, form validation, and enablement tests.
- GREEN: implement `Notifications` pane, channel forms/test state, rules list/editor, variable insertion/preview/reset, and app-lifetime wiring.
- REFACTOR: keep catalog metadata and validation out of SwiftUI; remove repeated channel form structure without erasing channel-specific fields.

Gate:

```sh
swift test --filter NotificationSettings
swift test --filter NotificationTemplate
swift test --filter AlertRuleSettings
./scripts/verify-localizations.swift
```

### 4. Parent integration verification

- Verify device name and one alert/recovery preview across all four channel encoders.
- Verify concurrent fan-out with mixed success, retry, authentication failure, and one disabled channel.
- Verify all catalog providers with available/unavailable fixtures and UI-closed monitor lifecycle.
- Verify dark-wake backfill does not replay historical events as new alerts on first enablement.
- Inspect UserDefaults/iCloud envelopes/test output for secrets.
- Check the Notifications pane at default 900x680 and minimum 720x540 sizes, keyboard navigation, VoiceOver labels, long Chinese strings, disabled/loading/error states, and no nested cards.
- Run full gate:

```sh
swift test
./scripts/verify-localizations.swift
./scripts/build-app.sh
codesign --verify --deep --strict .build/MenuCue.app
```

## Rollback points

- Transport: remove additive channels/coordinator; no existing system behavior changes.
- Rules: stop and remove monitor/runtime store; existing UI metric services remain unchanged.
- UI: remove sidebar pane and app wiring; retain no background service.
- Never clear user Keychain values as an automatic rollback/downgrade action.

## Review gates

- User approves parent requirements/design and child split before any `task.py start`.
- Activate `07-28-notification-transport` first.
- Do not activate UI before transport/rule public contracts are stable.
- Parent completion requires all child checks plus the full integration gate.
