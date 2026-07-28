# Complete MenuCue technical identity migration

## Goal

Rename the application from TouchMacer to MenuCue across all local technical identities and approved external distribution resources because there are no compatibility obligations to existing users.

## Requirements

- Rename the Swift package, executable targets, modules, source directories, test target/directory, app entry point, app bundle, Helper, and Helper protocol from `TouchMacer*` to `MenuCue*`.
- Use `com.tagzxia.app.menucue` as the main bundle identifier.
- Use `com.tagzxia.app.menucue.helper` for the privileged Helper bundle/daemon/XPC identity.
- Rename entitlements and LaunchDaemon plist resources and update every embedded identifier, executable path, signing requirement, and ServiceManagement constant.
- Rename persisted preference namespaces, test suite names, queue/cache labels, Sparkle Keychain account, build artifact directories, update archive names, temporary paths, and settings-window autosave keys to the MenuCue identity.
- Rename generated artifacts to `MenuCue.app`, `MenuCueHelper`, and `MenuCue-v<version>-macos.zip`.
- Update README, build/update scripts, generated Info.plist, privacy strings, GitHub/release URLs, Homebrew command, and project metadata.
- Rename GitHub repository `TalexDreamSoul/touch-macer` to `TalexDreamSoul/menucue` and update the local origin URL.
- Rename the Homebrew cask token/file from `touchmacer` to `menucue` and ensure it installs a real `MenuCue.app` release artifact.
- Preserve all unrelated working-tree changes while moving renamed files and directories.

## Acceptance Criteria

- [x] `swift test` resolves and tests only `MenuCue` modules/targets.
- [x] `swift build` produces `MenuCue` and `MenuCueHelper` executables.
- [x] `scripts/build-app.sh` produces a valid signed `.build/app/MenuCue.app` with the new main and Helper identifiers.
- [x] Generated plist, entitlements, LaunchDaemon, XPC, signing, Sparkle, preferences, paths, and release scripts use the new identity.
- [x] Repository audit outside historical Trellis records contains no legacy product-name references.
- [x] GitHub repository is available as `TalexDreamSoul/menucue` and local `origin` points to it.
- [x] `brew install --cask talexdreamsoul/tap/menucue` resolves to a valid MenuCue artifact and cask audit passes.
- [x] Existing unrelated user changes remain present after directory/file migration.

## Validation Evidence

- `swift test`: 141 XCTest cases passed; 2 Swift Testing identity contract tests passed.
- Stable packaging: `MenuCue.app` version `0.4.4`, build `13`, signed by the configured Apple Development identity.
- Main designated identifier: `com.tagzxia.app.menucue`.
- Helper designated identifier: `com.tagzxia.app.menucue.helper`.
- Localization verification: 469 English/Simplified Chinese keys match and both resource sets are packaged.
- Release archive: `MenuCue-v0.4.4-macos.zip`, SHA-256 `ee8d2b288b17f04bd68b777aaabf222953837eacbd29c40a0f645b7f7ab95b5c`.
- Appcast contains only MenuCue `v0.4.4` and references the new repository/archive.
- GitHub: `https://github.com/TalexDreamSoul/menucue`, release `v0.4.4` published and appcast-feed replaced.
- Homebrew: cask `menucue` version `0.4.4`; `brew audit`, `brew style`, download/SHA verification, installation, bundle-ID inspection, and codesign verification passed.
- Recovery backup: `/tmp/menucue-migration-20260727-191718`.

## External Operations Approved

The user explicitly approved renaming the GitHub repository and Homebrew cask in this task. Force pushes, history rewrites, destructive resets, and unrelated releases remain prohibited.

## Release Decision

The user explicitly approved committing and pushing the complete current worktree, publishing `v0.4.4` with a real `MenuCue.app` archive, and updating the renamed Homebrew cask to that release.
