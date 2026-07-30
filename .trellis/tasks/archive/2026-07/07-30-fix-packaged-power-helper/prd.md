# Fix packaged power Helper registration

## Problem

The Homebrew-installed MenuCue 0.6.6 contains a signed `MenuCueHelper` and valid LaunchDaemon plist, but `SMAppService.daemon(...).status` returns `.notFound`. The UI therefore reports that the packaged Helper or LaunchDaemon configuration is missing.

## Requirements

- Package the managed daemon in the bundle location recognized by `SMAppService`.
- Keep the Helper executable name, bundle identifier, Mach service, protocol, client-signature checks, and persisted registration build key unchanged.
- Preserve the main App's entitlements and provisioning profile; remove any Helper entitlement that is not backed by a matching Helper provisioning profile.
- Align the LaunchDaemon `BundleProgram`, runtime package detection, release signature verification, and build copy/sign paths.
- Preserve Developer ID signing, hardened runtime, notarization, macOS 13 support, and Homebrew delivery.
- Do not modify unrelated active calendar/reminder/holiday work.

## Acceptance Criteria

- Packaging contract tests require `MenuCueHelper` at `Contents/MacOS/MenuCueHelper` and the plist `BundleProgram` matches that path.
- The signed app contains both main and Helper executables under `Contents/MacOS` and strict codesign verification passes.
- A Homebrew-installed build no longer reports `.notFound`; it reports a valid registration lifecycle state (`notRegistered`, `requiresApproval`, `refreshRequired`, or `enabled`).
- Full tests pass.
- A notarized release is published, Homebrew Cask is updated, and the installed app passes Gatekeeper assessment.
