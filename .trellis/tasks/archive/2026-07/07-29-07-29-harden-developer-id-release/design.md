# Design

## Signing boundary

`build-app.sh` remains responsible for assembling and code-signing the app bundle. Stable release mode is explicit through `REQUIRE_STABLE_SIGNING=true`; in that mode the script validates a Developer ID Application identity and a distribution provisioning profile before signing. A shared codesign argument array applies hardened runtime and timestamping consistently to Sparkle components, the helper, and the app.

## Packaging boundary

`build-update.sh` remains the only path that creates a Sparkle release archive. Before archiving it verifies:

- Developer ID authority and team identity for every executable component.
- Hardened runtime flags and non-ad-hoc designated requirements.
- A non-device-bound, non-debug Developer ID provisioning profile.
- App/profile iCloud entitlement consistency.

It then creates a temporary notarization ZIP, submits it through a required notarytool Keychain profile, waits for an Accepted result, staples the ticket to the app, validates the ticket, and requires a successful Gatekeeper assessment. The final Sparkle ZIP is produced only after stapling, so downloaded updates contain the notarization ticket.

## Credential handling

Certificate private keys, provisioning profiles, and App Store Connect API keys live outside the repository under `~/Library/Application Support/MenuCue Signing` or in the login Keychain. Scripts receive only paths/profile names through environment variables. No secret material or Apple account token is committed or printed.

## Rollback

The current v0.6.4 GitHub Release stays draft and the public appcast remains at v0.6.3 until the corrected artifact passes all checks. If notarization fails, no public asset or appcast is changed.
