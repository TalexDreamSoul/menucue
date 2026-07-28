# Implementation plan: notification transport

## RED

- Add failing tests for message/config validation, URL redaction, UTF-8 byte/character payload limits, real URLSession redirect rejection, streaming response caps, and typed errors.
- Add mock-HTTP request/response fixtures for Feishu success/API error/signing, Webhook 2xx/4xx/5xx, Bark success/error/custom server, and Telegram success/auth/rate-limit/invalid-token.
- Add secret-store contract tests for exact service/account/accessibility/non-synchronizable query attributes, update-first duplicate-add recovery, and create/read/update/delete/missing/corrupt/locked/access failure.
- Add coordinator tests with lease-bearing fake outbox claims for disabled channels, mixed fan-out results, claim expiry/stale-ack identity, per-channel acknowledgement, bounded retry, and restart resume.

## GREEN

- Implement transport/message/configuration models and interfaces.
- Implement Security-framework Keychain store with `AfterFirstUnlockThisDeviceOnly`/non-synchronizable attributes and a test memory store.
- Implement bounded URLSession transport with a redirect-rejecting delegate and redacting error mapper.
- Implement Feishu, Webhook, Bark, and Telegram adapters and factory.
- Implement durable delivery coordinator with injected clock/sleeper.

## REFACTOR

- Centralize HTTP/API error classification, size/time limits, JSON encoding, and secret redaction.
- Confirm channel-specific logic remains inside adapters and tests can substitute protocol fakes.

## Validation

```sh
swift test --filter NotificationChannel
swift test --filter NotificationSecret
swift test --filter NotificationDelivery
swift test
./scripts/build-app.sh
```

## Rollback

All files are additive. Remove transport wiring without changing existing app state; never automatically delete Keychain entries during rollback.

## Completion

Completed in `bc31c95`: focused and full test suites pass, stable signed packaging passes,
and the implementation shipped in MenuCue v0.6.0 (build 16).
