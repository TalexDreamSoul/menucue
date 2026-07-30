# Design: signed statutory holiday data and overrides

## Artifact contract

The publishing pipeline emits a raw manifest plus detached Ed25519 signature. The signature covers the exact downloaded manifest bytes so the client never reserializes JSON to verify it.

Manifest fields:

- `schemaVersion`
- monotonic `revision`
- RFC 3339 UTC second-precision `publishedAt`
- `completeYears` and RFC 3339 UTC second-precision `validThrough`
- `coverage.start` / `coverage.end`
- `sources[]`: stable id, kind, URL/reference, observed revision/time, and input digest
- `records[]`: strict `YYYY-MM-DD`, `holiday|workday`, authoritative source id, and corroborating source ids

Canonical manifest bytes are UTF-8 JSON with lexicographically sorted object keys, deterministic arrays, defined slash/control-character escaping, no insignificant whitespace, and no trailing newline. A detached UTF-8 JSON signature envelope binds `algorithm=ed25519`, `keyID`, manifest revision, lowercase SHA-256 hex digest, and base64 signature. The signature covers exact manifest bytes. Golden fixtures lock this representation across toolchain changes.

## Pipeline boundary

Keep upstream-specific decoding in adapters. Adapters return typed candidate records and never write canonical files directly.

1. Official adapter/manual official-source input produces authoritative records and source references.
2. LunarBar-compatible JSON adapter decodes only strict year + `MMDD` + `1|2` data and marks it corroborative.
3. Normalizer validates Gregorian dates and creates candidates.
4. Comparator requires every publishable record to have official authority and reports missing/extra/conflicting third-party candidates.
5. Review file records explicit human resolution and official reference for every blocker.
6. Deterministic builder emits manifest bytes.
7. Signing step consumes a CI secret/private-key path and emits the detached signature.

Use Foundation/CryptoKit and repository scripts or a small Swift executable; add no runtime package dependency. Pipeline tests use fixed fixtures and a test key only.

## Client service

`StatutoryScheduleUpdateService` owns the canonical endpoint, conditional-request metadata, delayed weekly schedule, manual refresh, transport limits, signature/schema validation, atomic cache activation, and published status. It does not own UI settings or user overrides.

`StatutoryScheduleStore` owns bundled/cached typed lookup and source metadata. It receives a validated manifest from the updater and increments a revision used by month-cache keys.

Validation order is fail-closed: response metadata/size -> signature envelope/key id/digest -> manifest decode/schema -> monotonic revision -> `completeYears`/`validThrough`/coverage -> sources -> records -> atomic write -> activate. `Fresh` means the requested year is complete and current time is not after `validThrough`; stale data may remain usable and labeled; dates outside coverage are unavailable. An update transport failure is reported separately and never deletes the previous file.

## Overrides and sync

Persist a typed map under one portable settings field:

`{ generation, entries: CivilDateKey -> { value: holiday|workday|suppressed|tombstone, modifiedAt, origin } }`

For normal external changes, compare generation first: higher replaces the complete lower-generation envelope; lower remote data is rejected and repaired by writing back higher local data; equal generations merge by deterministic `(modifiedAt, origin)` and write back the union. The specialized override merge runs before `AppModel`'s generic portable-field outer-`modifiedAt` rejection.

First merge, account change, `Use iCloud`, and `Use This Mac` are explicit authoritative-source choices: take the chosen complete map, set generation to `max(localGeneration, cloudGeneration) + 1`, save locally, and export. This intentionally does not union the rejected source.

Wall-clock skew remains deterministic LWW rather than causal ordering. Individual tombstones are permanent. Explicit reset-all also increments generation and starts an empty map. Enforce a conservative encoded-size budget within the existing 1 MB KVS total; overflow pauses further cloud export but never drops local data. Feed refresh does not touch this envelope.

## UI

The month projection asks one resolver for final status and provenance. The cell receives only compact status/override state. Selected-date detail provides inline state controls, official value, canonical revision/coverage, and stale/failure status. Network/update diagnostics live in Calendar and Events settings, including last successful check and manual refresh.

## Child boundaries

The publishing pipeline, client feed, and override/iCloud work execute in separate child tasks. This design owns their typed contracts; the parent is not a fourth implementation path.

## Security and operations

Embed only the data public key. Support public-key rotation through an app release that trusts old and new key ids during a bounded transition. Keep app-update Sparkle signing separate from data signing. Log status/revision/error class, never full downloaded bodies or credentials.
