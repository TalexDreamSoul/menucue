# Implementation Plan

1. Add failing release-script contract tests for Developer ID authority, distribution profile checks, hardened runtime, notarization, stapling, and Gatekeeper assessment.
2. Harden `scripts/build-app.sh` to reject non-Developer-ID stable signing and device-bound/debug profiles, and apply runtime/timestamp codesign options to every component.
3. Harden `scripts/build-update.sh` to validate Developer ID/profile/runtime properties and notarize/staple/assess before creating the final Sparkle ZIP.
4. Run focused tests, shell syntax checks, `git diff --check`, and the full Swift test suite.
5. Build MenuCue 0.6.5 (21) with the Developer ID identity/profile.
6. Package with the `MenuCue-Notarization` Keychain profile and require Apple acceptance.
7. Validate code signatures, profile properties, stapled ticket, Gatekeeper acceptance, Sparkle signatures, and archive hash.
8. Replace the draft v0.6.4 asset, publish the release, upload the corrected appcast, and verify the remote artifacts.
9. Update release guidance/spec knowledge, commit the pipeline fix, archive the task, and push without modifying unrelated task files.

## Validation Commands

```bash
swift test --filter ProductBrandTests
bash -n scripts/build-app.sh scripts/build-update.sh
swift test
BUILD_CONFIG=release REQUIRE_STABLE_SIGNING=true CODESIGN_IDENTITY="Developer ID Application: ZiXian Tang (2L5YC85FQ7)" APPLE_TEAM_ID=2L5YC85FQ7 PROVISIONING_PROFILE="$HOME/Library/Application Support/MenuCue Signing/MenuCue-DeveloperID.provisionprofile" scripts/build-app.sh
NOTARYTOOL_PROFILE=MenuCue-Notarization EXPECTED_VERSION=0.6.5 EXPECTED_BUILD=21 scripts/build-update.sh
codesign --verify --deep --strict .build/app/MenuCue.app
xcrun stapler validate .build/app/MenuCue.app
spctl --assess --type execute --verbose=4 .build/app/MenuCue.app
```
