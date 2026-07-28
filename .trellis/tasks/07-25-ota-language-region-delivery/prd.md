# OTA delivery and language-region controls

## Goal

Prove TouchMacer's complete self-update chain by bootstrapping a secure updater release, then delivering app language and system time-zone controls exclusively through that updater to the installed application.

## Source Requirements

- Remove mixed local/manual TouchMacer installations and install a clean remote baseline.
- Add automatic 12-hour update checks, background download, signed verification, and one-click install/relaunch.
- Add English and Simplified Chinese app language selection.
- Add one-click system time-zone changes.
- Provide safe access to macOS global language settings without undocumented global preference mutation.
- Commit, push, and publish the completed versions.
- Demonstrate the installed older build discovering, downloading, installing, and relaunching into the newer feature build through OTA.
- Provide an evidence trail for every stage.

## Delivery Map

- Child `07-25-automatic-background-updates`: ship Sparkle OTA as `v0.4.0` and manually bootstrap that release because `v0.3.1` has no updater.
- Child `07-25-language-region-controls`: ship the language and region feature as `v0.4.1`, without manually replacing the installed `v0.4.0` app.

## Requirements

- The remote baseline must be traceable to a GitHub Release asset by version, build, and SHA-256.
- `v0.4.0` must embed the updater, consume a stable signed appcast, establish a stable non-ad-hoc code identity for both OTA releases, and pre-ship the versioned/capability-based time-zone Helper RPC.
- `v0.4.1` must add no new Helper selector, must be published to the same stable appcast, and must be discovered by the installed `v0.4.0` process without any local v0.4.1 process running first on the proof account.
- The final proof must include old version, scheduled/manual discovery, signed download, install/relaunch, new version, and working new controls.
- The updater signing private key must never enter Git, logs, task artifacts, release notes, or built app resources.
- No release may include unrelated untracked Trellis or agent files.

## Acceptance Criteria

- [x] The previous local installation is removed and remote `v0.3.1 (8)` is installed under `/Applications` with a SHA matching GitHub Release.
- [ ] `v0.4.0` is committed, pushed, released, manually installed once, and reports a functioning Sparkle updater.
- [ ] `v0.4.1` is committed, pushed, and released while installed `v0.4.0` remains untouched.
- [ ] Installed `v0.4.0` discovers `v0.4.1` through the signed appcast, downloads it, and presents the native install action.
- [ ] One user install action replaces and relaunches the app as `v0.4.1`.
- [ ] English/Simplified Chinese switching and system time-zone controls work after the OTA update.
- [ ] The complete evidence trail records release URLs, commit/tag identity, archive/appcast signatures, installed paths, before/after versions, and verification commands.

## Out of Scope

- Pretending `v0.3.1` can self-update; it has no updater engine.
- Undocumented direct mutation of macOS global language preferences.
- Delta updates, beta channels, staged rollout, or mandatory updates.
