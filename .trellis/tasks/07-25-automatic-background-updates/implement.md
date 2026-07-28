# Implementation plan: automatic background updates

## 1. RED: update-service contracts

- Add focused tests for default 12-hour configuration, paired automatic check/download toggle behavior, manual checks while scheduling is disabled, status/error projection, and no `AppSettings`/portable-field ownership.
- Introduce a narrow updater-engine protocol so tests use a fake rather than network or Sparkle UI.
- Run `swift test --filter UpdateServiceTests` and confirm failure before implementation.

## 2. GREEN: Sparkle runtime integration

- Pin Sparkle 2.9.4 in `Package.swift` and resolve `Package.resolved`.
- Add `UpdateService` and its Sparkle adapter/delegate bridge.
- Instantiate it in `AppDelegate`, inject it into `AppModel`, and keep it alive for the process lifetime.
- Replace the custom GitHub checker/About state with the automatic toggle, last-check/status text, and standard manual check action.
- Remove obsolete GitHub release DTO/checker code.
- Run focused tests, then `swift test` and `swift build -c release`.

## 3. RED/GREEN: forward-compatible Helper contract

- Add protocol/manager/helper tests for `protocolVersion`, declared capabilities, typed time-zone query/set replies, valid identifier allowlisting, fixed `/usr/sbin/systemsetup` argument arrays, observed-result verification, unsupported capability, and connection interruption.
- Ship these selectors in v0.4.0 while keeping language/region UI hidden.
- Sign test v0.4.0/v0.4.1 bundles with the same release identity and prove the main app designated requirement remains stable across builds and is accepted by a long-running v0.4.0 Helper.

## 4. RED/GREEN: packaged framework and stable code identity

- Add packaging checks that fail before Sparkle is embedded.
- Update `scripts/build-app.sh` to create `Contents/Frameworks`, preserve the complete Sparkle framework hierarchy/symlinks, provide the executable rpath, and write required Info.plist keys.
- Keep non-sandboxed Sparkle configuration; do not add sandbox-only service keys.
- Require one stable Apple Development signing identity for both OTA releases; ad-hoc signing is forbidden for the live update chain.
- Sign deepest nested Sparkle XPC/apps/tools/framework and TouchMacer Helper/main app before the outer bundle, then inspect authority/team/designated requirement for each critical component.
- Build the app and verify `otool -L`, framework components, Info.plist values, nested/outer signatures, designated-requirement continuity, and local smoke launch.

## 5. Security gate: Ed25519 identity

- Before running `generate_keys`, obtain explicit approval because it creates a durable private key in the login Keychain.
- Generate the key with Sparkle 2.9.4 tooling, capture only the public key in source/Info.plist, and verify no private material appears in Git status, logs, task artifacts, app resources, or shell history files.
- Back up the private key through the user's approved secure mechanism outside this repository; do not invent or upload a backup destination.

## 6. Release tooling and signed feed

- Add a deterministic release helper that uses the checksum-verified Sparkle 2.9.4 SPM artifact tools, packages the app, and generates the appcast from an isolated updates directory.
- Explicitly sign the final appcast XML after all content changes; never modify it afterward.
- Extract each enclosure signature and verify its ZIP with `sign_update --verify <zip> <signature>`; separately verify the embedded feed signature with `sign_update --verify appcast.xml`.
- Ensure appcast archive URLs are immutable/tag-specific and `SUFeedURL` points to the dedicated `appcast-feed` prerelease asset, not `releases/latest`.
- Test malformed feed, modified appcast, modified ZIP, non-newer version, and offline behavior without modifying `/Applications/TouchMacer.app`.

## 7. Ship and bootstrap v0.4.0

- Set app version `0.4.0`, build `9`.
- Run `swift test`, release build, packaged app smoke test, signature verification, and appcast verification.
- Stage only updater-owned product/docs/tests/scripts; commit and push `master`.
- Publish GitHub Release `v0.4.0` with its ZIP; create/update the dedicated `appcast-feed` prerelease asset only after ZIP/feed verification. Verify tag/commit identity, public download SHA, feed signature, archive signature, and stable feed URL.
- Update and push Homebrew cask `0.4.0`.
- Stop remote-installed `v0.3.1`, manually install remote `v0.4.0` once, launch from `/Applications`, and record version/build/path/SHA.

## 8. Integration gate before v0.4.1

- Confirm installed `v0.4.0` can open Sparkle's manual check UI and parse the signed feed as current with no configuration errors.
- Confirm 12-hour scheduling and automatic download defaults from updater properties/defaults.
- Confirm helper protocol version/capabilities and stable signed client requirement before the daemon can be used by v0.4.1.
- Do not manually replace, rebuild, or launch any local v0.4.1 app under the proof user account after this gate.

## Validation commands

```bash
swift test
swift build -c release
./scripts/build-app.sh
otool -L .build/app/TouchMacer.app/Contents/MacOS/TouchMacer
codesign --verify --deep --strict --verbose=2 .build/app/TouchMacer.app
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' .build/app/TouchMacer.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' .build/app/TouchMacer.app/Contents/Info.plist
# Sparkle pinned tools:
sign_update --verify appcast.xml
sign_update --verify TouchMacer-vX.Y.Z-macos.zip '<sparkle:edSignature>'
curl -fL https://github.com/TalexDreamSoul/touch-macer/releases/download/appcast-feed/appcast.xml
```

## Review gates

- No custom app replacement or installer code.
- No private key material in repository-visible surfaces.
- Sparkle owns updater persistence and UI workflow.
- Feed and archive both reject tampering.
- `/Applications` is manually replaced only for the one-time v0.4.0 bootstrap.
