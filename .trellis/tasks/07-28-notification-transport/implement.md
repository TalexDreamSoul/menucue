# Implementation plan: notification transport

## RED

- Add failing tests for message/config validation, URL redaction, payload limits, and typed errors.
- Add mock-HTTP request/response fixtures for Feishu success/API error/signing, Webhook 2xx/4xx/5xx, Bark success/error/custom server, and Telegram success/auth/rate-limit.
- Add secret-store contract tests for create/read/update/delete/missing/corrupt/access failure.
- Add coordinator tests for disabled channels, mixed fan-out results, per-channel durable status, bounded retry, and restart resume.

## GREEN

- Implement transport/message/configuration models and interfaces.
- Implement Security-framework Keychain store and test memory store.
- Implement bounded URLSession transport and redacting error mapper.
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
