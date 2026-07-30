# Holiday visual overrides and iCloud merge

## Goal

Render signed statutory status in the month/date UI and let users visually override individual dates with convergent, bounded iCloud preference sync.

## Requirements

- Depend on the typed schedule store and shared `CivilDateKey`/month projection.
- Show compact `休`/`班` corner markers independent of lunar and EventKit indicators.
- Show resolved/official status, provenance/freshness, and custom state in selected-date detail.
- Provide official, holiday, workday, and suppress actions; reset follows the latest active official feed.
- Resolve `custom > cached feed > bundled > unavailable` without mutating source files.
- Default markers on only for `CN` when no stored value exists.
- Store one portable envelope with a top-level generation plus per-date value/tombstone, modified time, and origin.
- During normal sync, compare generation first: a higher generation replaces the complete lower-generation map; a lower remote generation is rejected and repaired by writing back the higher local envelope; equal generations merge entries by deterministic `(modifiedAt, origin)` and write back the union. Individual tombstones remain permanent.
- During first merge, account change, `Use iCloud`, or `Use This Mac`, promote the chosen full map to `maxGeneration + 1` before export; execute this specialized path before generic outer-field LWW.
- Reset-all also increments generation before compaction; enforce an encoded-size budget and preserve local behavior if cloud export pauses.

## Acceptance Criteria

- [ ] Marker geometry, color-independent semantics, VoiceOver, and largest-text layout do not collide with lunar/event/reminder content.
- [ ] Inline override/reset updates immediately and feed refresh never erases custom state.
- [ ] Ordinary sync converges across higher-remote, higher-local, and equal-generation cases; equal-generation ties are deterministic and permanent tombstones prevent stale resurrection.
- [ ] First/account merge and explicit local/cloud source choices promote only the chosen full map and bypass generic outer-field LWW.
- [ ] Higher-generation reset-all defeats a long-offline lower-generation upload.
- [ ] Payload overflow pauses cloud export with visible status but keeps all local overrides.
- [ ] CN/non-CN default, migration, local persistence, and feed-cache exclusion from iCloud pass.

## Constraints

- No JSON-folder customization.
- No sync of feed bytes or EventKit identifiers/content.
