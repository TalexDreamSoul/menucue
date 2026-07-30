# Implementation plan: holiday data publishing pipeline

## RED

- [ ] Add official and LunarBar-compatible adapter fixtures plus malformed/date/status drift cases.
- [ ] Add comparison tests for missing authority, conflict, duplicate, and reviewed resolution.
- [ ] Add byte-exact manifest and signature-envelope golden fixtures with a test key.
- [ ] Add repeat-run determinism and completeYears/validThrough consistency tests.

## GREEN

- [ ] Implement source DTOs/adapters, strict normalizer, comparator, review decoder, and provenance report.
- [ ] Implement canonical encoder, digest, detached Ed25519 signer, and immutable artifact naming.
- [ ] Add publication command with private-key/logging guardrails.
- [ ] Generate the first reviewed bundled manifest candidate.

## REFACTOR AND VALIDATE

```bash
swift test --filter HolidayPublishing
swift test
swift build
```

Run publication twice against frozen fixtures and compare manifest/signature-envelope SHA-256 values. Inspect outputs to confirm no secret path/content is included.
