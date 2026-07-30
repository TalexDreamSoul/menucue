# Retrospective

## Root Cause

The release contained a validly signed Helper file, but three semantic/runtime contracts were wrong:

1. `SMAppService.daemon` did not recognize the daemon in `Contents/Library/HelperTools`; managed daemons use `Contents/MacOS` with the plist under `Contents/Library/LaunchDaemons`.
2. Moving the Helper invalidated its old directory-depth calculation for finding the main executable used in XPC client verification.
3. The raw Helper carried `managed-by-main-app` without a matching Helper provisioning profile, so AMFI rejected launch after codesign and notarization had already succeeded.
4. launchd supplies a relative `argv[0]`, so executable discovery based on `CommandLine.arguments[0]` was not reliable.

## Solution

- Co-located `MenuCue` and `MenuCueHelper` in `Contents/MacOS`.
- Updated `BundleProgram`, runtime package detection, build signing, and release verification.
- Used `_NSGetExecutablePath` and sibling resolution for XPC client requirement loading.
- Removed the unprovisioned restricted Helper entitlement while retaining Developer ID, hardened runtime, designated-requirement, bundle ID, and Team ID validation.
- Added structured plist tests, a relative-`argv[0]` subprocess test, and release gates for Label, MachServices, AssociatedBundleIdentifiers, BundleProgram, signing identifier, and entitlement absence.

## Validation

- 385 XCTest + 5 Swift Testing tests passed.
- Homebrew-installed `0.6.7 (26)` shows the Helper as enabled.
- launchd reports `job state = running`, parent bundle version 26.
- `MenuCueHelper` runs as root.
- `powerHelper.registeredBuild=26` proves `queryProtocolInfo` completed through XPC.
- Final ZIP SHA-256: `8f59e6c282d488ec79ba2138dc7094d3f35da1a612d1cfc8219e8df1476a9422`.
- Notarization ID: `c041d9f3-8259-4238-b9fe-4708e8103431`.
- Extracted and Homebrew-installed Apps passed strict codesign, stapler validation, and Gatekeeper as `Notarized Developer ID`.

## Prevention

Code signing, notarization, and file existence do not prove a managed daemon works. Future releases that change Helper packaging or signing must perform a real installed-App registration and XPC protocol handshake before publication.
