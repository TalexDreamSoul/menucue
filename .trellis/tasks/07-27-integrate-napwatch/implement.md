# Implementation plan: NapWatch-inspired Power Diagnostics

## Status

Implementation approved by the user. Activate only after the Trellis context manifests pass the ready gate.

## Phase A: read-only diagnostics

### 1. Freeze contracts and fixtures (RED)

- Add fixture files for `pmset -g stats`, `pmset -g log`, `pmset -g custom`, `pmset -g cap`, battery registry values, command failures, and unsupported hardware.
- Include Apple Silicon/Intel, macOS 14/15/26, AC/Battery/UPS, `powermode` and `lowpowermode`, same-second wake events, malformed/truncated output, and nonzero exit cases.
- Write failing parser/model tests before probe code.
- Prove missing/unsupported/error never collapses to `false` or `0`.
- Prove AC and battery profiles remain distinct.
- Prove same-second events preserve order and identity.

Validation:

```sh
swift test --filter PowerDiagnosticsParserTests
swift test --filter PowerDiagnosticsModelTests
```

### 2. Implement typed probe boundary (GREEN)

- Add typed models and pure parsers.
- Add a fixed-path command runner with environment, status, timeout, cancellation, and output limits.
- Add native battery/source probe and truthful battery-flow calculation.
- Keep all calls off the main thread.

Validation:

```sh
swift test --filter PowerDiagnostics
swift test --filter Battery
```

### 3. Implement refresh service (RED/GREEN)

- Test first-open, explicit-refresh, post-wake delay, duplicate request coalescing, stale-result rejection, last-good-value retention, and service teardown.
- Implement `PowerDiagnosticsService` separately from the fast metrics timer.
- Observe app sleep/wake notifications and reconcile from `pmset` after wake.
- Do not add periodic `pmset -g log` polling.

Validation:

```sh
swift test --filter PowerDiagnosticsServiceTests
```

### 4. Implement 30-day wake history store (RED/GREEN)

- Write failing tests for first write, relaunch restore, same-second event identity, duplicate reconciliation, 30-day pruning, defensive record/size ceiling, corrupt/future schema, atomic replacement, daily summaries, and clear-history confirmation state.
- Store only normalized wake events and aggregate counts under Application Support.
- Reconcile before pruning so a delayed app launch does not discard unseen source events.
- Exclude the store from `AppSettings`, `PortableSettingField`, iCloud, and process diagnostics.
- Keep writes off the main thread and publish one atomic snapshot after merge/prune.

Validation:

```sh
swift test --filter WakeHistoryStoreTests
swift test --filter PowerDiagnosticsServiceTests
```

### 5. Build the Power tab (RED/GREEN)

- Add model/view-state tests for loading, unsupported, stale, error, portable, desktop, AC, and battery states.
- Add the tab and native controls after the state tests fail correctly.
- Verify text fits at the fixed popover dimensions and VoiceOver labels expose values/event kinds.
- Ensure leaving the tab stops live battery sampling but does not unregister app-level wake reconciliation.

Validation:

```sh
swift test --filter PowerTab
swift test
./scripts/build-app.sh
```

### 6. Real-machine read-only smoke test

- Compare displayed counts/profiles against `pmset` outputs without mutating settings.
- Test plugged/unplugged transitions if hardware permits.
- Sleep/wake once and verify one reconciliation, no duplicates, no UI blocking.
- Measure app CPU/energy with popover closed, Status open, and Power open.
- Verify no new permission prompt and no iCloud telemetry key.

## Phase B: controlled power settings

### 7. Extend helper protocol contract (RED)

- Add typed setting/source/value contracts and a new capability bit.
- Increment protocol version.
- Add tests for every allowed mapping and rejection of unsupported/arbitrary values.
- Add parser fixtures for observed read-back.

Validation:

```sh
swift test --filter PowerHelper
```

### 8. Implement helper mutations (GREEN)

- Map typed requests to fixed `pmset` arguments.
- Preserve source distinctions; default UI intent to the currently active source while allowing explicit Battery/AC/All override.
- Resolve the target in the main app and send it explicitly; the root helper never guesses from timing-sensitive power-source state.
- Query capability before mutation and observed profile after mutation.
- Return observed state on success/failure where available.
- Do not add cached sudo or generic shell execution.
- Do not auto-restore user-authored persistent settings when the helper is removed.

Validation:

```sh
swift test --filter PowerHelper
./scripts/build-app.sh
codesign --verify --deep --strict .build/MenuCue.app
```

### 9. Integrate actions/UI

- Add approved settings to Quick Actions and/or Power tab controls.
- Require confirmation when an all-source change would flatten different AC/battery values.
- Publish progress and observed state through the existing service pattern.
- Handle stale helper, approval-required, unsupported, and command-failed states.

Validation:

```sh
swift test
./scripts/build-app.sh
```

### 10. Packaged helper smoke test

Requires explicit user approval because it changes machine power settings:

- Install/refresh helper.
- Change one approved setting on one source.
- Verify read-back and UI.
- Restore the original value explicitly.
- Verify helper removal leaves user-authored persistent power settings unchanged.

## Phase C: process energy diagnostics and actions

### 11. Lock process contracts and privileged policy (RED)

- Define `ProcessIdentity` with PID, start time, owner UID, and observed executable/bundle identity.
- Add fixtures/tests for `top` output truncation, duplicate display names, exited processes, inaccessible root processes, PID reuse, malformed energy values, and changing sort order.
- Prove selection follows stable identity rather than row index or bare PID.
- Prove process telemetry is excluded from persistence and iCloud.

Validation:

```sh
swift test --filter ProcessEnergyModelTests
swift test --filter ProcessEnergyParserTests
```

### 12. Implement on-demand energy sampling (GREEN)

- Evaluate native cumulative process energy counters against `top` coverage and semantics.
- If needed, implement a fixed `/usr/bin/top -l 2 -o power` fallback behind the typed runner.
- Resolve full process names/details separately so `top` column truncation cannot become identity.
- Serialize/coalesce scans, run immediately when the process section becomes visible, repeat no more often than every 15 seconds while visible, and stop on hide/close.
- Label values as energy impact, never Watts.

Validation:

```sh
swift test --filter ProcessEnergyProbeTests
swift test --filter ProcessEnergyServiceTests
```

### 13. Implement process details and stale-identity defense (RED/GREEN)

- Write failing tests for process exit and PID reuse between scan, detail, confirmation, and action.
- Reuse native `proc_*` and bundle lookup patterns where possible.
- Revalidate PID + start time immediately before any action.
- Return a typed stale-process result without signaling the replacement process.

Validation:

```sh
swift test --filter ProcessIdentityTests
swift test --filter ProcessDetailTests
```

### 14. Implement SIGTERM and renice (RED/GREEN)

- Add explicit single-process SIGTERM confirmation and a stronger App-batch confirmation that freezes member identities and shows the member count; add no SIGKILL path.
- Batch termination revalidates each frozen identity, never targets children spawned after confirmation, and returns per-process partial-success results.
- Keep renice individual-process only, clamp relative nice changes into `-20...19`, and re-read the resulting value.
- Route current-user, root, and other-user process actions through narrowly typed helper capabilities with identity revalidation inside the helper.
- Apply no application-level target deny list; require stronger typed confirmation for root/system targets and any batch containing them, and surface macOS/kernel refusal as an observed failure.
- Never expose arbitrary signals, absolute nice values, executable paths, or shell arguments over XPC.

Validation:

```sh
swift test --filter ProcessActionTests
swift test --filter PowerHelper
```

### 15. Integrate process UI

- Add energy-impact ranking with segmented App/Process views over one shared sample, stable selection, sample age, and explicit refresh to the Power tab.
- Test aggregation totals, helper-to-app grouping, mode switching without a second scan, and preservation of concrete process identities for actions.
- Use an interactive detail presentation for actions, not the existing non-hit-testable hover overlay.
- Ensure process exit, permission denial, helper refresh, and stale identity have clear recoverable states.
- Verify destructive confirmation keyboard focus and accessibility labels.

Validation:

```sh
swift test --filter PowerTab
swift test
./scripts/build-app.sh
```

### 16. Real-machine process smoke test

Requires explicit user approval for SIGTERM/renice:

- Start a disposable current-user test process with known identity and nice value.
- Verify ranking/detail, individual relative renice/read-back, confirmed single-process SIGTERM, confirmed App-batch SIGTERM/partial results, and stale-selection rejection.
- Test only against a purpose-built disposable current-user or root-owned helper process, never an arbitrary system daemon.
- Measure scan duration, 15-second visible-only cadence, CPU, and closed-popover idle cost.

## Phase D: optional additions beyond upstream parity

Only create/activate after a separate product decision:

- abnormal dark-wake notification policy.

## Full quality gate

```sh
swift test
./scripts/build-app.sh
```

Also inspect:

- signed app/helper entitlements;
- helper protocol compatibility and refresh behavior;
- no unreviewed iCloud portable fields;
- no full-log periodic poll;
- no main-thread process waits;
- no process action can target a reused PID;
- process energy values are labelled as energy impact, not Watts;
- no process inventory, path, or action history is persisted or synced;
- helper process-control capabilities are typed and ownership/identity/confirmation checked;
- no copied MIT source without required notice;
- git diff contains only approved phase files and preserves the pre-existing metrics work.

## Rollback points

- After model/parsers: remove additive files/tests only.
- After Power tab: remove tab/service wiring; no system state changed.
- Before helper mutation smoke test: package can be rolled back without restoring settings.
- After any real mutation test: record and explicitly restore the pre-test value before rollback.

## Validation evidence (2026-07-27)

- `swift test`: 168 XCTest and 2 Swift Testing tests passed, including live read-only `pmset`, IOKit, process identity, and `top` probes.
- `scripts/verify-localizations.swift`: 534 English/Simplified Chinese keys verified.
- `./scripts/build-app.sh` and `codesign --verify --deep --strict`: passed for the local release bundle.
- Two independent post-fix reviews reported no remaining Blocker or Major findings.
- After explicit approval for a write smoke test, `SMAppService.register()` reached macOS's Login Items gate but the ad-hoc build had no Team ID and was marked `disallowed`. The user declined manual approval, so no `pmset` mutation, SIGTERM, or renice was executed.
- Cleanup was verified: the temporary `/Applications/MenuCue-Smoke.app` was removed, the background item was unregistered (`SMAppServiceStatus.notRegistered`), no system launchd service remained, and before/after `pmset -g custom` output matched.
