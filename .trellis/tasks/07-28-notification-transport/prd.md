# Notification transport and secure channel configuration

## Goal

Provide a channel-neutral delivery boundary, secure credential storage, and production implementations for Feishu, generic Webhook, Bark, and Telegram.

## Requirements

- Define `NotificationMessage`, channel kind/configuration metadata, receipts, and redacted typed errors.
- Define a `NotificationChannel` interface whose concrete implementations receive an already-rendered message.
- Implement a Keychain-backed secret-store interface with an in-memory test implementation.
- Implement Feishu text/custom-bot signing, versioned generic Webhook JSON, Bark POST JSON, and Telegram `sendMessage`.
- Construct enabled channels through a factory; downstream callers never switch on channel kinds.
- Fan out one event to all enabled channels concurrently, isolate outcomes, and persist per-event/per-channel delivery status.
- Retry only bounded transient failures; never leak credentials in errors, descriptions, logs, URLs, fixtures, or receipts.
- Validate HTTPS endpoints, required fields, payload lengths, API-level success bodies, and response size/time limits.
- Keep all configuration machine-local and out of iCloud.

## Acceptance Criteria

- [ ] Interface tests use fake channels without importing concrete sender types.
- [ ] Request tests prove exact method, URL construction, headers, body, encoding, and response handling for all four senders.
- [ ] Feishu optional signature matches official HMAC test vectors and requires API `code == 0`.
- [ ] Bark supports the default service and a validated custom server without putting title/body in the URL path.
- [ ] Telegram token is redacted from all surfaced failures and success requires `ok == true`.
- [ ] Generic Webhook emits the versioned envelope and stable event-ID header.
- [ ] Keychain create/read/update/delete and missing/corrupt/error behavior are covered with no secrets in local settings.
- [ ] Mixed fan-out outcomes and retry classification are deterministic under a fake clock/HTTP transport.
- [ ] Focused transport tests and full `swift test` pass.

## Dependencies

None. This child defines contracts consumed by the alert-rule and settings children.
