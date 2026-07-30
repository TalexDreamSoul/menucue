# Design: holiday visual overrides and iCloud merge

The month projection consumes one `ResolvedStatutoryStatus` containing final status, official status, custom flag, active feed revision, and freshness. Cells render only compact status; selected detail owns editing/provenance.

Portable envelope:

`{ generation, entries: CivilDateKey -> { value|tombstone, modifiedAt, origin } }`

For ordinary external notifications, compare top-level generation first:

- remote generation higher: replace the complete local envelope
- local generation higher: reject the lower remote envelope and write the complete local envelope back
- generations equal: compare `(modifiedAt, origin)` per date and write the union back only when bytes differ

This specialized merge runs before the existing generic portable-field outer timestamp check.

For first merge, account change, `Use iCloud`, or `Use This Mac`, the user chose an authoritative side: promote that complete map to `max(localGeneration, cloudGeneration) + 1`, save it, and export without unioning rejected entries. LWW remains deterministic but not causal under clock skew.

Individual tombstones never expire. Reset-all increments generation and starts an empty map, permitting lower-generation compaction. Enforce a conservative field-size limit within the existing 1 MB KVS total; local `UserDefaults` remains authoritative and cloud export reports paused on overflow.

Views mutate settings only through `AppModel`; the sync service cannot edit UI state or feed cache.
