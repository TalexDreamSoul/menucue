# Design: privileged power quick actions

## Boundary

Add one narrowly scoped privileged LaunchDaemon. The main app remains unprivileged and never invokes `sudo` or accepts arbitrary root commands.

Package structure:

```text
TouchMacer.app/
└── Contents/
    ├── MacOS/TouchMacer
    └── Library/
        ├── HelperTools/TouchMacerHelper
        └── LaunchDaemons/com.touchmacer.clock.helper.plist
```

`SMAppService.daemon(plistName: "com.touchmacer.clock.helper.plist")` owns registration and administrator approval. The plist uses `BundleProgram`, `AssociatedBundleIdentifiers`, and a Mach service named `com.touchmacer.clock.helper`.

## Targets and protocol

Add two Swift Package targets:

- `TouchMacerHelperProtocol`: shared Objective-C-compatible XPC protocol and constants.
- `TouchMacerHelper`: root LaunchDaemon executable implementing only the power API.

The XPC protocol exposes primitive-value methods only:

```swift
queryPowerState(reply: (success, lowPowerEnabled, sleepDisabled, error) -> Void)
setLowPowerMode(enabled, reply: ...)
setSleepDisabled(enabled, reply: ...)
prepareForRemoval(reply: ...)
```

There is no generic command, executable path, argument array, script, or file-operation method.

## Client authentication

Before accepting an XPC connection, the helper:

1. derives the current app’s `Contents/MacOS/TouchMacer` path from its own embedded path;
2. creates `SecStaticCode` for that executable;
3. copies its designated requirement;
4. resolves the connecting process from `NSXPCConnection.processIdentifier`;
5. accepts only when `SecCodeCheckValidity` succeeds against that exact requirement.

For ad-hoc local builds, the designated requirement is the main executable’s exact CDHash. A future public helper release must use a Developer ID Application identity and notarization; the current machine has no valid Developer ID identity.

## Helper operations

Every operation runs `/usr/bin/pmset` directly through `Process` with a compile-time argument list.

### State query

- `pmset -g custom` determines whether the platform uses `powermode` or `lowpowermode`.
- `powermode`: value `1` means low power, `0` automatic, `2` high power.
- `lowpowermode`: value `1` means enabled, `0` disabled.
- `pmset -g` exposes `SleepDisabled 1` after `disablesleep` is enabled.

The Helper returns actual state after every mutation.

### Low Power Mode

- enable: `pmset -a <detected-key> 1`
- disable: `pmset -a <detected-key> 0`

This intentionally applies to battery and adapter power and restores Automatic, not a previous High Power setting. The UI copy must state this before registration/use.

### Don’t Sleep When Closed

- enable: `pmset -a disablesleep 1`
- disable: `pmset -a disablesleep 0`

The first enable requires a safety confirmation about heat, ventilation, and battery use. Before its first mutation, the Helper persists the original `SleepDisabled` value. Removal restores that value only when the Helper owns the setting; removing an unused Helper leaves an existing user setting untouched.

## Main-app manager

`PowerHelperManager` owns:

- `SMAppService.Status` mapping: unavailable, not registered, requires approval, enabled, failed;
- registration, System Settings navigation, and safe removal;
- one privileged `NSXPCConnection`;
- observed low-power and sleep-disabled state;
- focused error text.

`QuickActionService` owns one manager, maps helper status into the two quick-action availabilities, and refreshes real state. Clicking either unavailable tile starts registration or opens Login Items settings when approval is pending.

Settings adds a Helper section with status and Install / Open System Settings / Remove controls.

The Helper section is state-positioned: unresolved states render first as an orange attention
surface with a prominent remediation button; the enabled state renders after the action catalog
as routine management. One shared view produces both placements so status copy and actions cannot
drift.

Lock Screen performs an explicit Accessibility trust request on the user click before dispatching
its System Events keystroke. `AXIsProcessTrustedWithOptions` receives the prompt option, which lets
macOS own the authorization UI. A denied request stops before AppleScript execution and publishes a
localized remediation message.

## Compact UI and icons

- Popover size: 304×640 points.
- Compact action icon circle: 34 points.
- Compact tile height: 60 points.
- Grid row spacing: 7 points.
- Header uses subheadline typography.
- Labels retain two lines and 0.72 minimum scale.

Apple Shortcut tiles use `command.square.fill`, which exists on macOS 14. Do not use `apple.shortcuts`, which rendered as empty circles on the supported deployment target.

## Packaging

The packaging script builds both executable products, copies the helper and daemon plist, signs the helper with `com.apple.developer.service-management.managed-by-main-app`, then seals the outer app. Bundle fallback version becomes 0.2.1/build 6 for local verification; this task does not publish a GitHub release.

## Failure and rollback

- Registration failure leaves both actions unavailable and visible.
- Approval-required state never claims installation success.
- XPC interruption invalidates the connection and refreshes Helper status.
- Failed `pmset` mutation returns stderr and re-queries state.
- Removing the Helper restores the pre-existing `SleepDisabled` value only when the Helper previously changed it.
- If ad-hoc SMAppService registration is rejected by macOS, keep the UI and packaging implementation but do not ship the privileged actions until Developer ID signing/notarization is available.
