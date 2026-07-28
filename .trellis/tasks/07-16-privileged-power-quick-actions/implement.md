# Implementation plan: privileged power quick actions

## 1. Add shared protocol and helper target

- Add `TouchMacerHelperProtocol` target with identifiers and the restricted XPC protocol.
- Add `TouchMacerHelper` executable target.
- Implement caller code-signature validation before accepting XPC connections.
- Implement fixed `pmset` execution, output parsing, state query, two setters, and safe removal.

Build both products before changing the UI.

## 2. Package the LaunchDaemon

- Add the LaunchDaemon plist and helper entitlements.
- Update `scripts/build-app.sh` to copy helper/plist into the required bundle paths.
- Sign the helper before sealing the app.
- Bump the local bundle to 0.2.1/build 6.
- Verify helper entitlements, app signing, bundle layout, and designated requirements.

## 3. Add the main-app manager

- Implement `PowerHelperManager` around `SMAppService` and privileged XPC.
- Publish registration status, real power state, and focused errors.
- Implement register, open approval settings, query, set low power, set sleep disabled, and remove.
- Ensure removal restores the pre-existing sleep setting only when the Helper previously changed it.

## 4. Connect Quick Actions

- Replace static unavailable states for Low Power Mode and Don’t Sleep When Closed with Helper-derived availability/state.
- Make unavailable tile clicks start registration or open approval settings.
- Add first-enable safety confirmation for lid-closed operation.
- Re-query actual state after every mutation and XPC error.

## 5. Add Helper settings

- Show status, explanatory copy, and context-appropriate action buttons in Quick Actions settings.
- Place unresolved Helper states at the top as a prominent remediation surface; keep the enabled
  management state below the catalog.
- Keep unavailable actions unpinnable until Helper status is enabled.
- Refresh status when settings and the action catalog appear.

## 5.1 Request lock-screen authorization

- Inject a small Accessibility permission requester into `QuickActionService`.
- Request the native macOS prompt from the Lock Screen click before sending System Events keystrokes.
- Stop and show localized remediation when access is not granted.
- Add tests for permission request invocation and Helper attention-state classification.

## 6. Compact the popover and repair Shortcut icons

- Reduce popover to 304×640.
- Reduce compact icon/tile/spacing metrics without truncating labels.
- Replace unsupported `apple.shortcuts` with `command.square.fill`.

## 7. Verify

Run:

```bash
swift build
swift test
./scripts/build-app.sh
codesign --verify --deep --strict .build/app/TouchMacer.app
```

Then verify:

- packaged helper and LaunchDaemon plist paths;
- helper entitlement and outer app signature;
- popover visual size and Shortcut icon rendering;
- SMAppService not-registered → requires-approval/enabled transitions;
- low-power enable/disable with real `pmset` state;
- sleep-disabled enable/disable with `SleepDisabled` state;
- safety confirmation before first sleep disable;
- helper removal restores the pre-existing `SleepDisabled` value without changing an unmanaged setting;
- an unauthenticated XPC client is rejected;
- existing actions and calendar UI remain functional.

## Review gates

- No root-capable generic execution endpoint exists.
- Every Helper command and argument is compile-time fixed.
- Helper authenticates the calling code before accepting XPC.
- UI state is always queried, never inferred from the requested value.
- The app never bypasses administrator approval.
- No GitHub release is created in this task.
