# Design: holiday client feed and fallback

`StatutoryScheduleUpdateService` owns transport, scheduling, validators, atomic persistence, and update status. `StatutoryScheduleStore` owns typed bundled/cached lookup and active revision. Views receive typed status only.

Validation order is response status/MIME/size -> signature-envelope structure and trusted key -> exact manifest digest/signature -> decode/schema -> monotonic revision -> completeYears/validThrough/coverage -> source references -> unique records -> atomic write -> activate.

Freshness:

- fresh: requested year is in `completeYears`, date is covered, and current instant is not after `validThrough`
- stale: record is covered/usable but `validThrough` has passed
- unavailable: requested date is outside active coverage or year is explicitly incomplete for statutory interpretation
- update failed: last transport/validation attempt failed, independently of active-data freshness

A key ring supports bounded app-release-driven rotation. Conditional metadata, last check/success, and active revision remain local. Feed/cache bytes never enter iCloud.
