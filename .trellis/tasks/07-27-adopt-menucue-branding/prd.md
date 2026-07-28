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

- [ ] `swift test` resolves and tests only `MenuCue` modules/targets.
- [ ] `swift build` produces `MenuCue` and `MenuCueHelper` executables.
- [ ] `scripts/build-app.sh` produces a valid signed `.build/app/MenuCue.app` with the new main and Helper identifiers.
- [ ] Generated plist, entitlements, LaunchDaemon, XPC, signing, Sparkle, preferences, paths, and release scripts use the new identity.
- [ ] Repository audit outside historical Trellis records contains no `TouchMacer`, `touchmacer`, or `touch-macer` references.
- [ ] GitHub repository is available as `TalexDreamSoul/menucue` and local `origin` points to it.
- [ ] `brew install --cask talexdreamsoul/tap/menucue` resolves to a valid MenuCue artifact and cask audit passes.
- [ ] Existing unrelated user changes remain present after directory/file migration.

## External Operations Approved

The user explicitly approved renaming the GitHub repository and Homebrew cask in this task. Force pushes, history rewrites, destructive resets, and unrelated releases remain prohibited.

## Release Decision

The user explicitly approved committing and pushing the complete current worktree, publishing `v0.4.4` with a real `MenuCue.app` archive, and updating the renamed Homebrew cask to that release.
