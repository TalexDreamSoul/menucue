# Harden Developer ID release pipeline

## Problem

The v0.6.4 artifact was signed with an Apple Development certificate and a device-bound development provisioning profile. Gatekeeper rejects that package on Macs not registered in the profile, so it is not a valid public release.

## Requirements

- Public release builds use `Developer ID Application: ZiXian Tang (2L5YC85FQ7)`.
- Public release builds use the MenuCue Developer ID provisioning profile, with `ProvisionsAllDevices=true`, no `ProvisionedDevices`, and `get-task-allow=false`.
- Every executable component is signed with hardened runtime and a trusted timestamp.
- Release packaging submits the app to Apple notarization, waits for acceptance, staples the ticket, validates it, and only then creates the Sparkle ZIP.
- Packaging fails closed when the signing authority, profile type, hardened-runtime flag, notarization credential, stapled ticket, or Gatekeeper assessment is missing or invalid.
- The existing MenuCue iCloud KVS entitlements and Sparkle feed/signature behavior remain intact.
- The invalid v0.6.4 release remains hidden until a corrected package passes all checks.
- Unrelated working-tree changes under existing Trellis tasks are preserved.

## Acceptance Criteria

- `scripts/build-app.sh` rejects Apple Development identities when stable release signing is requested.
- `scripts/build-app.sh` rejects device-bound or debug-enabled profiles for stable release signing.
- `scripts/build-update.sh` expects Developer ID authority, verifies hardened runtime and distribution profile properties, notarizes, staples, validates, and runs Gatekeeper assessment before ZIP creation.
- Regression tests assert the release-script guardrails.
- A release build of MenuCue 0.6.5 (21) passes `codesign`, `stapler validate`, `spctl --assess`, and Apple notarization.
- The corrected Sparkle archive and appcast signatures verify.
- The GitHub v0.6.5 asset is published and the online appcast points to 0.6.5 (21); the invalid v0.6.4 release remains hidden.
