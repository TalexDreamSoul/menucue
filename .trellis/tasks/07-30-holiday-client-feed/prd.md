# Holiday client feed and fallback

## Goal

Consume only MenuCue canonical signed statutory manifests with fail-closed validation, atomic cache activation, offline fallback, and executable freshness diagnostics.

## Requirements

- Depend on frozen manifest/signature fixtures from `07-30-holiday-publishing-pipeline` and shared civil dates from `07-30-lunar-month-calendar`.
- Bundle a last-known-good signed manifest and maintain one validated atomic cache.
- Contact only the configured MenuCue canonical endpoint after delayed jitter and weekly thereafter, plus explicit manual refresh.
- Use conditional requests, timeout/body limits, and strict response metadata.
- Validate signature envelope/key id/digest before manifest decode, then schema/revision/completeYears/validThrough/coverage/sources/records before activation.
- Reject bad, equal-conflicting, or regressive revisions without replacing the active snapshot.
- Define fresh, stale-but-usable, unavailable, and update-failed as separate statuses.
- Keep Gregorian/lunar calendar usable without network or statutory data.

## Acceptance Criteria

- [ ] Bad status/MIME/body size/signature/key/digest/schema/revision/date/status/provenance fails closed.
- [ ] Atomic-write interruption and app relaunch retain the prior valid manifest.
- [ ] Conditional 304 and weekly jitter avoid redundant downloads.
- [ ] `completeYears` and `validThrough` drive deterministic fresh/stale/unavailable status; transport failure remains separate.
- [ ] Manual refresh and last-success diagnostics are localized and never block month rendering.
- [ ] Trusted-key rotation fixtures accept the intended overlap and reject unknown keys.

## Constraints

- No direct government/LunarBar/MacCalendar client requests.
- No private key in the app.
- No user override or iCloud implementation in this task.
