# Quality Guidelines

> Code quality standards for backend development.

---

## Overview

<!--
Document your project's quality standards here.

Questions to answer:
- What patterns are forbidden?
- What linting rules do you enforce?
- What are your testing requirements?
- What code review standards apply?
-->

(To be filled by the team)

---

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

(To be filled by the team)

---

## Required Patterns

<!-- Patterns that must always be used -->

(To be filled by the team)

---

## Testing Requirements

<!-- What level of testing is expected -->

(To be filled by the team)

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)

---

## Scenario: Public macOS release signing

### 1. Scope / Trigger

- Trigger: any artifact uploaded to a GitHub Release or referenced by the Sparkle appcast.
- Local ad-hoc and Apple Development builds are never public release artifacts.

### 2. Contracts

- Sign every executable component with `Developer ID Application`, hardened runtime, and a trusted timestamp.
- Restricted iCloud entitlements require a Developer ID provisioning profile with `ProvisionsAllDevices=true`, no `ProvisionedDevices`, and `get-task-allow=false`.
- Submit the assembled app to Apple notarization, wait for `Accepted`, staple the ticket, validate it, and require `spctl --assess` to report `Notarized Developer ID`.
- Create the Sparkle ZIP only after stapling so the downloadable app contains the ticket.
- Keep signing keys, provisioning profiles, API keys, and notary credentials outside the repository; use Keychain profiles and environment-provided paths.
- Custom `.app` assembly must copy every SwiftPM runtime resource into `Contents/Resources`. Runtime lookup uses the main app bundle when packaged and `Bundle.module` under SwiftPM tests; a successful package build alone does not prove the installed app can load a resource.

### 3. Tests Required

- Contract tests assert Developer ID/profile/runtime/notarization guardrails in both release scripts.
- Release validation must cover the app extracted from the final ZIP, not only the build directory.
- Every runtime resource added to `Package.swift` must have a packaged-file check; signed data files additionally verify their digest after packaging.
- An invalid release stays draft and is absent from the public appcast until all checks pass.

---

## Scenario: Parsing `ioreg -rn AppleSmartBattery` output

### 1. Scope / Trigger

- Trigger: any new field read from the battery/power registry dump.
- The full contract lives in code:
  `PowerDiagnosticsParser.parseBatteryRegistry` / `parsePowerTelemetry`
  (`Sources/MenuCue/PowerDiagnostics.swift`) and `PowerDiagnosticsTests`.

### 2. Signatures

```swift
static func parseBatteryRegistry(_ text: String) throws -> BatteryFlow   // throws on missing fields
static func parsePowerTelemetry(_ text: String) -> PowerTelemetry?       // nil when nothing useful
```

### 3. Contracts

- Two property shapes need two matchers. Top-level scalars (`"Voltage" = 12336`) sit
  alone on a line with spaces around `=`; values inside inline dicts
  (`"AdapterDetails" = {"Watts"=140,...}`) never do. A whole-text `firstMatch` for a
  bare key name is wrong for both.
- Decoy keys are the norm, not the exception: `AppleRawAdapterDetails` repeats
  `"Watts"=`; `SystemPowerInAccumulatorCount` contains `SystemPowerIn`. Anchor the
  top-level property name at line start, and match `"Key"=` quote-delimited inside a
  captured payload.
- Dict properties print with ` = {`; array properties with ` = (` — use that to
  distinguish `AdapterDetails` from `AppleRawAdapterDetails`.
- Units and signs: telemetry powers (`SystemPowerIn`, `SystemLoad`) are milliwatts;
  battery current/voltage are mA/mV; `InstantAmperage` can arrive as unsigned
  two's-complement and must keep its sign. Unplugged output may print `{}` or omit
  `PowerTelemetryData` entirely (Intel), so every telemetry field stays optional.

### 4. Validation & Error Matrix

| Condition | Required result |
|---|---|
| Top-level scalar missing | `parseBatteryRegistry` throws `missingField` |
| Telemetry dict absent/empty | `parsePowerTelemetry` returns nil, no throw |
| `Watts=0` or absent | `adapterRatedWatts` nil (not 0) |
| Value beyond `Int64` | reinterpret as unsigned two's-complement, keep sign |

### 5. Tests Required

- Fixture with same-name decoy lines proves anchoring (use *different* values in decoy
  vs real, or the assertion proves nothing).
- Unplugged and garbage fixtures prove the nil/throw split.

---

## Scenario: Privileged power Helper

### 1. Scope / Trigger

- Trigger: a menu-bar action needs a root-only macOS system setting.
- Use the embedded `SMAppService.daemon` pattern. The main app remains unprivileged.

### 2. Signatures

`PowerHelperProtocolInfo.currentVersion == 3`. The Objective-C-compatible XPC interface includes:

```swift
queryProtocolInfo(reply: (Int, UInt64) -> Void)
setManagedPowerSetting(_ setting: Int, source: Int, enabled: Bool, reply: (Bool, String?) -> Void)
terminateProcess(_ pid: Int32, startTimeMicroseconds: Int64, ownerUID: UInt32,
                 executablePath: String, reply: (Bool, String?) -> Void)
reniceProcess(_ pid: Int32, startTimeMicroseconds: Int64, ownerUID: UInt32,
              executablePath: String, delta: Int, reply: (Bool, Int, String?) -> Void)
```

Legacy power-state, time-zone, and removal selectors remain part of the same versioned protocol. Capabilities are queried before a selector is used; an older installed Helper must surface `refreshRequired`.

### 3. Contracts

- Registration: `SMAppService.daemon(plistName: "com.tagzxia.app.menucue.helper.plist")`.
- Bundle layout: both `MenuCue` and `MenuCueHelper` live under `Contents/MacOS`; the LaunchDaemon stays under `Contents/Library/LaunchDaemons`, and its `BundleProgram` must resolve exactly to `Contents/MacOS/MenuCueHelper`.
- Association: the LaunchDaemon `AssociatedBundleIdentifiers` contains `com.tagzxia.app.menucue`. A raw nested Helper must not carry a restricted entitlement such as `managed-by-main-app` unless a matching Helper provisioning profile is actually embedded and verified; otherwise AMFI can reject launch after codesign and notarization succeed.
- Executable discovery: the Helper uses `_NSGetExecutablePath`, not `argv[0]`, because launchd may supply a relative `Contents/MacOS/MenuCueHelper` argument.
- Mach service and Helper signing identifier: `com.tagzxia.app.menucue.helper`.
- Main app bundle identifier: `com.tagzxia.app.menucue`.
- Fixed executables only: `/usr/bin/pmset` and `/usr/sbin/systemsetup`; no executable or arguments cross XPC.
- Managed profile mutations are limited to `powernap`, `womp`, `standby`, and `tcpkeepalive`, with source `-b`, `-c`, or `-a` chosen by the unprivileged app.
- Process termination is always `SIGTERM`; there is no caller-supplied signal or SIGKILL endpoint. Renice accepts only relative `-1` or `+1` and rejects a boundary no-op.
- Process actions carry PID, start time in microseconds, owner UID, and executable path. The Helper re-reads and matches all four immediately before acting.
- Current-user targets get an explicit SIGTERM confirmation. Cross-UID and Apple system-path targets require exact-name typed confirmation for SIGTERM and renice. App batches freeze their sampled members and run serially.
- The Helper validates the caller's dynamic designated requirement, expected bundle identifier, and Team ID when present. Ad-hoc builds have no Team ID and may require manual Login Items approval; release validation requires stable signing.
- Every mutation queries observed state. `pmset -a` succeeds only when every present profile contains and matches the requested key; renice succeeds only when the observed nice value equals the target.
- Before first changing `SleepDisabled`, persist whether it was already enabled. Removal restores that value only when the Helper owns the setting.

### 4. Validation & Error Matrix

| Condition | Required result |
|---|---|
| Helper is not running as root | Reject operation with `notRoot` |
| Protocol version/capability is stale | Require explicit Helper refresh before RPC |
| XPC caller fails requirement, bundle ID, or Team ID | Reject before exporting the service |
| Managed setting/source raw value is unknown | Reject without running `pmset` |
| Any present All-source profile omits or mismatches the key | Report write failure |
| PID/start-time-microseconds/UID/path differs | Return stale-process failure; do not signal or renice |
| Delta is not `-1/+1`, crosses `-20...19`, or read-back differs | Return failure, never a clamped success |
| Registration requires approval | Show approval state; never report enabled |
| Helper never owned `SleepDisabled` | Removal leaves the existing value unchanged |

### 5. Good / Base / Bad Cases

- Good: a typed request maps to fixed arguments, the Helper revalidates identity/state, and the UI publishes only observed results.
- Base: an unapproved or stale Helper leaves controls visible but unavailable and opens Login Items settings.
- Bad: arbitrary executable/signal/absolute nice values cross XPC; a bare PID is acted on; missing read-back fields are compacted away; requested values are written directly into UI state.

### 6. Tests Required

- Parse the packaged LaunchDaemon plist and require its `BundleProgram` to resolve to the exact Helper binary that is signed and verified.
- Build and strictly verify the signed app, Helper, LaunchDaemon identifiers, and Team IDs where available; reject unprovisioned restricted Helper entitlements.
- Before release, register the installed App's daemon, require launchd to report the Helper running as root, and complete `queryProtocolInfo`; `SMAppService.status != .notFound` alone is insufficient.
- Assert every managed setting/source mapping and reject unknown raw values.
- Assert All-source read-back fails when any present profile omits or differs on the key.
- Assert microsecond start-time encoding, each stable-identity mismatch, stale PID behavior, allowed deltas, nice boundaries, and observed-value mismatch.
- Assert current-user explicit confirmation and typed confirmation for cross-UID/system targets and batches.
- Assert unauthorized XPC clients are rejected and stale protocol capabilities require refresh.
- Real `pmset`, SIGTERM, and renice smoke tests require separate approval, disposable targets, captured original state, and explicit restoration.

### 7. Wrong vs Correct

#### Wrong

```swift
func run(path: String, arguments: [String])
func kill(pid: Int32, signal: Int32)
state.isOn = requestedValue
```

This creates generic root endpoints, allows PID reuse to retarget an action, and lies when a write is not retained.

#### Correct

```swift
func terminateProcess(_ identity: StableProcessIdentity) // protocol serializes typed fields
// Helper re-reads PID + start microseconds + UID + path, sends SIGTERM, and returns observed result.
```
