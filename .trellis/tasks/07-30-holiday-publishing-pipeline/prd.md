# Holiday data publishing pipeline

## Goal

Build a reproducible, review-gated pipeline that aggregates official and corroborating holiday sources into byte-canonical, signed MenuCue statutory schedule artifacts.

## Requirements

- Decode each upstream through a typed adapter; include official normalized input and LunarBar-compatible JSON as separate fixtures/adapters.
- Treat official government notices as authoritative and third-party inputs only as corroboration/anomaly signals.
- Block unresolved conflicts or records without official provenance and require an explicit reviewed resolution file.
- Emit exact canonical UTF-8 JSON: sorted object keys, deterministic arrays, RFC 3339 UTC second-precision timestamps, defined escaping, no insignificant whitespace, and no trailing newline.
- Include schema version, monotonic revision, `publishedAt`, `completeYears`, `validThrough`, coverage, source references/digests, and unique holiday/workday records.
- Emit a detached Ed25519 signature envelope binding algorithm, key id, revision, lowercase SHA-256 digest, and base64 signature.
- Keep production private keys and reviewer credentials outside the repository and logs.

## Acceptance Criteria

- [ ] Malformed dates/statuses, missing provenance, source conflicts, duplicate records, and invalid review resolutions fail closed.
- [ ] Identical frozen inputs produce byte-identical manifest/signature-envelope structures; a test key verifies the signature and digest.
- [ ] `completeYears`, `validThrough`, coverage, source digests, and record provenance are internally consistent.
- [ ] LunarBar-compatible source drift is detected without redistributing its unlicensed data as MenuCue authority.
- [ ] CI/manual publication commands require reviewed input and never print or persist the production private key.

## Constraints

- Pipeline only; no client networking, UI, caching, or iCloud work.
- Foundation/CryptoKit preferred; no unnecessary runtime dependency.
