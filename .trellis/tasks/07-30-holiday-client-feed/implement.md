# Implementation plan: holiday client feed and fallback

## RED

- [ ] Add injected-transport tests for HTTP/MIME/size/timeout/304 and jittered scheduling.
- [ ] Add signature-envelope, trusted-key, digest, schema, revision, coverage, source, and record validation failures.
- [ ] Add fresh/stale/unavailable/update-failed state tests with an injected clock.
- [ ] Add atomic interruption, corrupt cache, bundled fallback, relaunch, and key-rotation tests.

## GREEN

- [ ] Implement manifest/signature DTOs, trusted key ring, validator, store, update service, and atomic cache.
- [ ] Add bundled artifact resources and local update metadata.
- [ ] Add Calendar and Events update status/manual refresh UI and localization.

## REFACTOR AND VALIDATE

```bash
swift test --filter HolidayFeed
swift test --filter Localization
./scripts/verify-localizations.swift \
  Sources/MenuCue/Resources/en.lproj/Localizable.strings \
  Sources/MenuCue/Resources/zh-Hans.lproj/Localizable.strings
swift test
swift build
```

Manually exercise valid update, 304, offline, stale, unavailable, bad signature, and cached fallback in the packaged app.
