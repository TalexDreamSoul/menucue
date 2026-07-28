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

The shared Objective-C-compatible XPC interface is `PowerHelperProtocol`:

```swift
queryPowerState(reply: (Bool, Bool, Bool, String?) -> Void)
setLowPowerMode(_ enabled: Bool, reply: (Bool, Bool, Bool, String?) -> Void)
setSleepDisabled(_ enabled: Bool, reply: (Bool, Bool, Bool, String?) -> Void)
prepareForRemoval(reply: (Bool, Bool, Bool, String?) -> Void)
```

Reply fields are `(success, lowPowerEnabled, sleepDisabled, errorMessage)`.

### 3. Contracts

- Registration: `SMAppService.daemon(plistName: "com.tagzxia.app.menucue.helper.plist")`.
- Mach service and Helper signing identifier: `com.tagzxia.app.menucue.helper`.
- Main app bundle identifier: `com.tagzxia.app.menucue`.
- Allowed executable: `/usr/bin/pmset` only.
- Allowed mutations: detected `powermode` / `lowpowermode`, plus `disablesleep`.
- The Helper accepts a connection only when the caller satisfies the embedded main executable's designated code requirement.
- Every mutation returns a fresh `pmset` query; UI state never assumes the requested value succeeded.
- Before first changing `SleepDisabled`, persist whether it was already enabled. Removal restores that value only when the Helper owns the setting.

### 4. Validation & Error Matrix

| Condition | Required result |
|---|---|
| Helper is not running as root | Reject operation with `notRoot` |
| `powermode` and `lowpowermode` are absent | Return unsupported-mode error |
| XPC caller fails the designated requirement | Reject the connection before exporting the service |
| `pmset` exits nonzero | Return stderr and re-query the observable state |
| Registration requires approval | Show approval state; never report enabled |
| Helper never owned `SleepDisabled` | Removal leaves the existing value unchanged |

### 5. Good / Base / Bad Cases

- Good: approved Helper sets a fixed `pmset` key, reads state back, and publishes the returned booleans.
- Base: unapproved Helper leaves protected actions visible but unavailable and opens Login Items settings.
- Bad: arbitrary executable paths or argument arrays cross XPC; requested toggle values are written directly into UI state.

### 6. Tests Required

- Build and strictly verify the signed app bundle, embedded Helper entitlement, and LaunchDaemon plist.
- Assert parser behavior for both `powermode` and `lowpowermode` output shapes.
- Assert an unauthorized XPC client is rejected.
- Assert enable / disable returns queried state after command completion.
- Assert removal restores an owned prior `SleepDisabled` value and preserves an unmanaged value.

### 7. Wrong vs Correct

#### Wrong

```swift
func run(path: String, arguments: [String])
state.isOn = requestedValue
```

This creates an arbitrary root-command endpoint and lies when the command fails.

#### Correct

```swift
func setSleepDisabled(_ enabled: Bool, reply: PowerStateReply)
// Helper chooses the fixed pmset path/arguments, then queries pmset and replies.
```
