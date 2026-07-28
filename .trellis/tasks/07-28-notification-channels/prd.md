# Configurable external notification channels

## Goal

Allow users to configure an external notification channel for MenuCue power events, with Bark delivered first behind a channel-neutral interface that can also support Feishu, generic Webhook, and Telegram.

## Background

- MenuCue already records normalized sleep, dark-wake, and user-wake events through `PowerDiagnosticsService` and `WakeHistoryStore`.
- The existing NapWatch integration explicitly deferred external/abnormal-wake notifications to a separate product decision.
- The repository currently contains no outbound notification implementation or channel configuration UI.
- The user-supplied reference screenshot shows sleep/wake diagnostics and recent wake events.

## Requirements

- Define a typed notification-channel protocol/interface that accepts a channel-independent message and asynchronously reports success or a typed failure.
- Model the supported channel kinds as Feishu, Webhook, Bark, and Telegram without branching on channel details in power-diagnostics code.
- Implement Bark delivery and a user-facing Bark configuration flow.
- Support enable/disable, endpoint/device-key configuration, and a test-notification action before relying on the channel for live events.
- Keep channel credentials machine-local and out of iCloud preference sync, logs, errors, and analytics.
- Send network requests off the main thread with bounded timeouts and validated HTTPS URLs.
- Reuse the existing normalized wake-event pipeline as the notification source; do not parse `pmset` again in the notification layer.
- Preserve wake-history behavior when notification configuration is missing, disabled, or delivery fails.
- Add localized English and Simplified Chinese UI strings.

## Scope Boundary

- Bark is the first fully working sender.
- Feishu, generic Webhook, and Telegram must be representable by the shared protocol/factory boundary; whether their concrete senders ship in this task remains an explicit scope decision.
- Notification trigger policy remains an explicit product decision.
- Local macOS notification permission and UI are out of scope unless required by the chosen trigger policy.

## Acceptance Criteria

- [ ] A channel-independent protocol is covered by unit tests and power-diagnostics code depends only on that abstraction.
- [ ] The supported channel-kind model contains Feishu, Webhook, Bark, and Telegram.
- [ ] A user can configure, enable, disable, and test a Bark channel from Settings.
- [ ] Valid Bark configuration produces the documented HTTPS request and handles Bark API/network failures without blocking the UI.
- [ ] Invalid or incomplete Bark configuration cannot be enabled and produces actionable validation feedback.
- [ ] Newly discovered matching wake events are delivered at most once, including across background reconciliation and repeated refreshes.
- [ ] Delivery failure does not lose or corrupt local wake history and does not expose credentials.
- [ ] Notification configuration remains machine-local and is excluded from portable iCloud settings.
- [ ] Focused unit tests, `swift test`, localization verification, and `./scripts/build-app.sh` pass.

## Open Product Decision

- Which normalized power events should trigger external notifications in the first release?
