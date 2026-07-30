# Signed statutory holiday data and overrides

## Goal

Deliver trustworthy mainland China statutory holiday and make-up workday markers through a multi-source publishing pipeline, a signed canonical client feed, offline fallback, and visual per-date user overrides.

## Background

- LunarBar proves the value of bundled data, cached online updates, and custom precedence, but its client accepts a GitHub Raw dictionary after only HTTP and broad shape checks.
- LunarBar's separate `Holidays` data repository has no explicit license. It may be used as a corroboration adapter in the publishing pipeline, not as MenuCue's runtime trust boundary or redistributed source.
- The shared `CivilDateKey` and month projection come from `07-30-lunar-month-calendar`.

## Requirements

### Publishing pipeline

- Fetch multiple candidate sources outside the app and normalize them into strict Gregorian date/status records with provenance.
- Treat official government notices as authoritative. LunarBar-compatible and other third-party data only corroborate or report anomalies.
- Block publication on conflict or missing official provenance; require a reviewer to approve a source-linked resolution.
- Produce deterministic canonical bytes containing schema version, monotonic revision, publication time, `completeYears`, `validThrough`, coverage, source metadata, and unique holiday/workday records.
- Define canonical UTF-8 JSON key/order/escaping/date/newline rules and a detached signature envelope containing algorithm, key id, manifest revision, SHA-256 digest, and signature encoding.
- Sign canonical bytes with a dedicated Ed25519 data key. Keep the private key outside the repository; publish only the public key and signed artifacts.

### Client update and fallback

- Bundle a last-known-good canonical snapshot and keep a validated atomic cache.
- Contact only a MenuCue-controlled canonical endpoint on delayed jittered weekly checks and manual refresh.
- Use conditional requests, timeout and size limits, and validate status/content type, signature, schema, revision, coverage, strict dates, known statuses, uniqueness, and internal source references before activation.
- Reject bad or regressive data without changing the active snapshot. Define `fresh` as current date within a complete year and not after `validThrough`; define `stale` as usable data past `validThrough`; define `unavailable` as no record coverage for the requested date. Update failures remain distinct from freshness.
- Resolve display data as `user override > validated cache > bundled snapshot > unavailable`.

### UI and overrides

- Show compact `休`/`班` corner markers without replacing lunar text or event/reminder indicators.
- In selected-date detail show resolved status, source/coverage state, whether a custom override is active, and inline actions: official, holiday, workday, or suppress marker.
- Keep overrides separate from source data and apply/reset them immediately without mutating cached/bundled files.
- Store overrides in one portable envelope with a top-level generation and per-date values/tombstones ordered by deterministic `(modifiedAt, origin)`.
- During normal external updates, compare generation first: higher replaces lower; lower remote data is rejected and repaired from higher local data; equal generations merge per entry and write the union back. Individual tombstones remain permanent.
- During first merge, account change, `Use iCloud`, or `Use This Mac`, promote the explicitly chosen complete map to `max(localGeneration, cloudGeneration) + 1` and export it, so the source choice remains authoritative.
- Route this field through specialized merge before the existing generic whole-field outer-timestamp rejection.
- Explicit reset-all also increments generation before compaction. Enforce a portable encoded-size budget; if exceeded, keep local overrides working and report that additional cloud sync is paused.
- Default mainland markers on only for `CN` when no stored choice exists. Persist later user choice and never overwrite it after region changes.
- Do not add JSON-folder customization in the MVP.

## Acceptance Criteria

- [ ] Source adapters normalize deterministic records and attach retrieval revision/digest plus official provenance.
- [ ] Any official conflict blocks publishing until a reviewed source-linked resolution is recorded.
- [ ] Repeated pipeline runs over identical inputs produce byte-identical manifest bytes; golden tests lock JSON encoding and the signature envelope verifies the manifest digest/revision/key id with the embedded test public key.
- [ ] Client tests reject bad signature, oversized/truncated body, invalid MIME/status, unknown schema/status, invalid/duplicate date, broken source reference, lower/equal conflicting revision, and invalid coverage.
- [ ] Client freshness tests cover `completeYears`, `validThrough`, stale-but-usable data, unavailable dates, and update failure as separate states.
- [ ] Conditional requests and weekly jitter avoid unnecessary downloads; manual refresh reports success/failure.
- [ ] `休`/`班` markers remain distinct from lunar and EventKit indicators and have complete VoiceOver text.
- [ ] Visual official/holiday/workday/suppress actions update immediately and reset to the current official value after a feed revision.
- [ ] Per-date sync tests cover higher-remote replacement, higher-local repair, equal-generation deterministic merge, permanent tombstones, and iCloud failure.
- [ ] First merge, account change, `Use iCloud`, and `Use This Mac` promote the chosen full map to a higher top-level generation before export; generic outer-field timestamps cannot bypass this path.
- [ ] Reset-all prevents lower-generation resurrection and payload limits preserve local data while pausing cloud export.
- [ ] First `CN` default, non-`CN` default, persistence, migration, and feed-cache exclusion from iCloud are tested.
- [ ] Focused tests, `swift test`, localization verification, and `swift build` pass.

## Task Map

- `07-30-holiday-publishing-pipeline`: source adapters, official conflict review, deterministic canonical encoding, signing, and publication artifacts.
- `07-30-holiday-client-feed`: bundled/cached store, canonical download/validation, freshness, fallback, and update diagnostics.
- `07-30-holiday-overrides-sync`: month/detail markers, visual overrides, regional defaults, and per-entry iCloud convergence.
- This parent owns the shared manifest/override contracts and final integration acceptance.

## Constraints

- Client code must not directly contact government, LunarBar, MacCalendar, or other upstream providers.
- Do not copy MacCalendar source/data. Do not redistribute the unlicensed LunarBar `Holidays` repository as MenuCue data.
- No private signing key, token, or reviewer credential enters the app, repository, logs, or task artifacts.
- The core Gregorian/lunar calendar remains offline even when statutory data is absent.
