# Integrate NapWatch capabilities

## Goal

Evaluate NapWatch at upstream commit `2557b70c1e3c66943bef2af38135bd624cc8b0be` and define a well-scoped, evidence-backed way to add the appropriate capabilities to MenuCue without starting implementation.

## Background

- Upstream source: <https://github.com/Tuguberk/napwatch>
- MenuCue is a native macOS menu bar application written in Swift/SwiftUI.
- The working tree already contains uncommitted system-metrics work; this planning task must treat it as existing user work and must not modify or revert it.
- The user explicitly requested deep analysis before implementation.

## Confirmed Facts

- NapWatch is a macOS power/battery diagnostics TUI, not a sleep-duration tracker.
- It is a 1,311-line Rust 0.1.0 prototype with six commits, no releases, no upstream tests, and no issue/PR history at the audited revision.
- Its core data sources are macOS command-line output (`pmset`, `ioreg`, `top`, `ps`, `plutil`, and `launchctl`), not a reusable API or library.
- Live verification on macOS 26.5 found important correctness/performance gaps: modern `powermode` is misread, AC/battery profile differences can be overwritten by `pmset -a`, process names truncate, same-second wake events can be dropped, `pmset -g log` took 4.48 seconds, and `top -l 2` took 3.89 seconds.
- MenuCue already has native IOKit/Darwin metrics, demand-driven sampling, expensive on-hover probes, a signed `SMAppService` helper, versioned XPC capabilities, and observed read-back for protected mutations.
- NapWatch is MIT licensed. Substantial source adaptation requires retaining its copyright/license notice; no Rust dependency is needed.

## Requirements

- Inventory NapWatch's user-facing capabilities, architecture, runtime model, dependencies, permissions, persistence, and update behavior.
- Compare those capabilities with MenuCue's current architecture and in-flight system-metrics work.
- Deliver functional parity for battery diagnostics, wake diagnostics, power-setting visibility/mutation, energy-impact process ranking/detail, SIGTERM termination, and renice behavior.
- Recreate the accepted capabilities in native Swift and existing MenuCue architecture; do not treat Rust/TUI/sudo implementation details as parity requirements.
- Assess license compatibility, attribution obligations, privacy/security implications, macOS permissions, App Sandbox/signing constraints, performance, PID-reuse safety, and maintenance risk.
- Define phased module boundaries, data flow, UI placement, tests, and rollback points.
- Distinguish confirmed facts from assumptions and product decisions that require user input.
- Keep all power telemetry and process observations machine-local; do not sync them through iCloud.
- Keep this task in planning until the user explicitly approves implementation.

## Confirmed Product Decision

- Target full NapWatch functional parity, including energy-impact process ranking, process details, SIGTERM, and renice.
- Process actions include root and other users' processes through narrowly typed privileged-helper operations.
- Protected power-setting changes default to the currently active power source, with explicit Battery/AC/All override.
- Full power/process diagnostics live in a dedicated Power popover tab.
- Normalized sleep/wake events and daily counts persist locally for 30 days across reboot; no power/process telemetry is synced.
- Abnormal dark-wake notifications are deferred until the app has collected a representative 30-day baseline; the initial feature requests no notification permission.
- Process energy impact samples immediately when its Power-tab section becomes visible, then at most every 15 seconds while visible; it pauses when hidden and retains manual refresh.
- The energy list provides segmented App and Process views over one shared sample; App aggregates helpers, Process preserves individual identities.
- App rows may SIGTERM the confirmed set of member processes as a batch; renice remains individual-process only.
- No application-level deny list blocks core macOS, MenuCue, or helper targets; root/system targets require stronger typed confirmation and remain subject to macOS enforcement.
- Functional parity does not require embedding Rust, copying the TUI, or reproducing NapWatch's cached-sudo model.

## Recommended Scope

- Phase 1: read-only battery flow, since-boot wake counts, a 30-day local sleep/dark-wake timeline, daily summaries, and per-source power profiles in a dedicated Power tab.
- Phase 2: typed Power Nap, Wake-on-LAN, Standby, and TCP Keepalive mutations through the existing signed helper, with explicit source targeting and observed read-back.
- Phase 3: on-demand energy-impact process ranking, process identity/details, confirmed SIGTERM, and bounded renice operations for current-user, root, and other-user processes through the typed helper, with PID-reuse protection.
- Phase 4: separately evaluate abnormal-dark-wake alerts; notification policy goes beyond upstream parity.
- Reject Rust/TUI embedding, cached sudo, continuous full-log polling, optimistic setting state, and implicit all-source setting changes.

## Out of Scope

- Modifying application or test source code during planning.
- Adding packages, binaries, entitlements, permissions, or build settings during planning.
- Starting the Trellis task or implementing any proposed phase before user approval.
- Copying upstream source mechanically.

## Acceptance Criteria

- [x] Upstream findings cite concrete files and the audited commit.
- [x] Current-project findings cite concrete files and relevant existing/in-flight behavior.
- [x] A capability matrix classifies every NapWatch feature as reuse, adapt, planned phase, or rejected implementation mechanism with rationale.
- [x] The target product scope is full NapWatch functional parity.
- [x] The architecture, risks, validation strategy, and remaining product decisions are documented.
- [x] Complex-task planning artifacts (`design.md` and `implement.md`) are prepared but not activated.
- [x] The user resolves remaining security/UX decisions.
- [ ] The user explicitly approves implementation and Trellis task activation in a future step.

## Open Product Decisions

None. Task activation and implementation remain explicitly unapproved.

## Notes

- Detailed evidence: `research/upstream-audit.md` and `research/integration-analysis.md`.
- Planning-only task created from the user's standing authorization for Trellis-managed development work.
