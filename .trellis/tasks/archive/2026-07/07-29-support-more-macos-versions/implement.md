# Implementation Plan

1. Add a failing product contract test for macOS 13 in both SwiftPM and app-bundle metadata.
2. Change the package and bundle deployment targets to macOS 13.0 and bump the release to 0.6.6 (22).
3. Add shared availability-gated SwiftUI modifiers for optional macOS 13.3/14 presentation and keyboard APIs.
4. Convert current two-parameter `onChange` call sites to the compatible overload.
5. Add EventKit access fallback and replace the macOS-14-only empty state.
6. Run a clean macOS 13 build, then fix every remaining availability diagnostic without disabling core features.
7. Run focused tests, shell checks, full tests, and release packaging.
8. Verify Info.plist and Mach-O minimum OS metadata, notarization, stapling, Gatekeeper acceptance, Sparkle signatures, and appcast minimum system version.
9. Commit and push MenuCue changes, publish v0.6.6, then update, audit, commit, and push the Homebrew Cask.
10. Install the Homebrew release and confirm the running process uses v0.6.6.

## Validation Commands

```bash
swift test --filter ProductBrandTests
swift build -c release
swift test
bash -n scripts/build-app.sh scripts/build-update.sh
BUILD_CONFIG=release REQUIRE_STABLE_SIGNING=true CODESIGN_IDENTITY="Developer ID Application: ZiXian Tang (2L5YC85FQ7)" APPLE_TEAM_ID=2L5YC85FQ7 PROVISIONING_PROFILE="$HOME/Library/Application Support/MenuCue Signing/MenuCue-DeveloperID.provisionprofile" scripts/build-app.sh
NOTARYTOOL_PROFILE=MenuCue-Notarization EXPECTED_VERSION=0.6.6 EXPECTED_BUILD=22 scripts/build-update.sh
otool -l .build/app/MenuCue.app/Contents/MacOS/MenuCue
xcrun stapler validate .build/app/MenuCue.app
spctl --assess --type execute --verbose=4 .build/app/MenuCue.app
brew style --cask menucue
brew audit --cask menucue
```
