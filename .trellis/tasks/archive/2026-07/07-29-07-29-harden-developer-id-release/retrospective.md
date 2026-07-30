# Retrospective

## Root cause

The prior release scripts treated any non-ad-hoc Apple signature as stable. `build-update.sh` explicitly expected an Apple Development authority, and neither script distinguished device-bound development profiles from Developer ID distribution profiles. The pipeline also produced the Sparkle ZIP without Apple notarization or a stapled ticket.

## Correction

- Created and installed a Developer ID Application G2 identity for team `2L5YC85FQ7`.
- Created a non-device-bound Developer ID profile for `com.tagzxia.app.menucue` with iCloud KVS entitlement.
- Added a dedicated App Store Connect API key and validated the `MenuCue-Notarization` Keychain profile.
- Hardened release scripts to require Developer ID, distribution profile properties, runtime/timestamp flags, Apple notarization acceptance, stapling, and Gatekeeper acceptance.
- Added regression contract tests and documented the release contract.
- Kept invalid v0.6.4 hidden and moved the corrected public release to v0.6.5.

## Verification

- 382 XCTest tests and 3 Swift Testing tests passed.
- Notarization submission `3b3c41d5-084f-4327-b45f-ed2b11be6c7f` returned `Accepted`.
- The app extracted from `MenuCue-v0.6.5-macos.zip` passed strict codesign verification, stapler validation, and `spctl --assess` with `source=Notarized Developer ID`.
- Public appcast rollback was repaired to point to valid versioned historical URLs while v0.6.5 remained pending publication.
