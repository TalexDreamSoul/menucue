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

- Build and strictly verify the signed app, embedded Helper entitlement, LaunchDaemon plist, identifiers, and Team IDs where available.
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
