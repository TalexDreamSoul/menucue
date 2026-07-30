# Implementation Plan

1. Add RED packaging assertions for the managed daemon layout and plist association.
2. Move Helper copy/sign/runtime/release paths to `Contents/MacOS` and update `BundleProgram`.
3. Add RED tests for Helper-to-main executable resolution and replace old directory walking with a shared sibling-path function.
4. Add RED tests for launch-safe Helper signing, remove the unprovisioned restricted entitlement, and enforce its absence in release validation.
5. Add dyld executable discovery via `_NSGetExecutablePath` so launchd's relative `argv[0]` cannot break client verification.
6. Run focused tests, full tests, shell checks, and signed app builds.
7. Install the signed app in `/Applications`, register the daemon, and require all of:
   - UI state `Enabled`
   - launchd `job state = running`
   - root `MenuCueHelper` process
   - `powerHelper.registeredBuild` updated by the `queryProtocolInfo` callback
8. Notarize, staple, verify Gatekeeper, commit/push, publish the GitHub Release and Sparkle feed, update/audit/push the Homebrew Cask, and perform a real Homebrew upgrade.

## Validation Commands

```bash
swift test
bash -n scripts/build-app.sh scripts/build-update.sh
codesign --verify --deep --strict .build/app/MenuCue.app
launchctl print system/com.tagzxia.app.menucue.helper
spctl --assess --type execute --verbose=4 .build/app/MenuCue.app
brew style --cask menucue
brew audit --cask menucue
```
