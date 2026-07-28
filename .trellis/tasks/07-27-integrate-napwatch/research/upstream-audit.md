# NapWatch upstream audit

## Scope

- Repository: <https://github.com/Tuguberk/napwatch>
- Audited commit: `2557b70c1e3c66943bef2af38135bd624cc8b0be` (2026-07-19)
- Audit date environment: macOS 26.5, Apple Silicon, Rust 1.95.0
- Upstream size: 1,311 lines across five Rust source files.

## Product and architecture

NapWatch is not a nap or sleep-duration tracker. It is a terminal dashboard for diagnosing macOS battery drain, dark wakes, per-process energy impact, and selected `pmset` settings.

Its runtime is one background polling thread feeding one in-memory `App` state object:

1. Every cycle it sequentially runs battery, battery-current, wake-statistics, power-setting, and `top` probes.
2. Every eighth cycle it additionally parses the complete `pmset -g log` output.
3. The terminal event loop redraws every 200 ms and handles toggles/process actions.
4. No data survives process exit; only the last 40 wake events remain in memory.

Evidence: [`src/app.rs` lines 8-56](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/app.rs#L8-L56), [`src/app.rs` lines 59-164](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/app.rs#L59-L164).

## Capability inventory

| Capability | Source/mechanism | Important semantics |
|---|---|---|
| Battery percentage, AC/charging, estimate | `pmset -g batt` | Read-only, no privilege |
| Instant battery flow | `ioreg -rn AppleSmartBattery` | Battery current x voltage, not whole-system wall power |
| Sleep/dark-wake/user-wake counts | `pmset -g stats` | Cumulative only since boot |
| Sleep/wake event feed | Full `pmset -g log` parse | Debug log, expensive, no persistence |
| Power settings | `pmset -g` | Only currently active profile, missing values collapse to false/zero |
| Power settings mutation | `sudo pmset -a` | Changes all power-source profiles |
| Process energy ranking | `top -l 2 -o power` | Energy-impact score, not Watts; process names can be truncated |
| Process detail | `ps`, `plutil`, `launchctl` | On-demand inspection |
| Kill/renice | `kill`, `renice`, optionally sudo | Destructive/privileged process management |
| UI | ratatui + crossterm | Terminal-specific; no value to a SwiftUI app |

Primary evidence: [`src/power.rs`](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/power.rs), [`src/actions.rs`](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/actions.rs), [`src/main.rs`](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/main.rs).

## Verified behavior and defects

### 1. Polling cost is unsuitable for a menu bar app

On the audit machine:

- `pmset -g log >/dev/null`: 4.48 seconds wall time.
- `top -l 2 ... >/dev/null`: 3.89 seconds wall time.
- NapWatch runs probes serially and sleeps only after the work completes, so its nominal two-second interval is not a two-second refresh cadence.
- Polling the complete power log every eight cycles would create material CPU/process churn in a product intended to diagnose battery drain.

This confirms the source's own warning at [`src/app.rs` lines 9-20](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/app.rs#L9-L20), but the observed cost is higher than its comment.

### 2. Current power mode is misreported on modern hardware

The machine reports `powermode 2` in `pmset -g custom`; NapWatch only reads `lowpowermode`, so its read-only dump returned `lowpowermode: false`. MenuCue already handles both names and source-specific profiles in `Sources/MenuCueHelper/main.swift:177`.

Evidence: [`src/power.rs` lines 93-121](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/power.rs#L93-L121).

### 3. Toggle semantics destroy AC/battery differences

The audit machine intentionally has `womp 0` on battery and `womp 1` on AC. NapWatch reads only the active profile and toggles with `pmset -a`, overwriting both profiles with one inverted value. The same risk applies to settings whose profiles differ by power source.

Evidence: [`src/actions.rs` lines 30-45](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/actions.rs#L30-L45).

### 4. Mutations are optimistic, not observed

After `pmset` exits successfully, NapWatch flips local state and suppresses incoming settings for three seconds. It does not immediately re-read the authoritative system value. This conflicts with MenuCue's established rule that system mutations must be followed by observation.

Evidence: [`src/app.rs` lines 192-208](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/app.rs#L192-L208).

### 5. Battery “Watts” is easy to label incorrectly

The calculation is mathematically valid battery-terminal current x voltage. On AC it represents battery charge flow; it is not charger input or total Mac power draw. On desktops it is unavailable. The UI must label it “Battery flow” or “Charge/discharge rate,” not “system power consumption.”

Evidence: [`src/power.rs` lines 297-337](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/power.rs#L297-L337).

### 6. Process “POWER” is not Watts and names truncate

A live run returned names such as `Orca Helper (Ren` and `Google Chrome He`; this comes from `top`'s output width. The numeric value is macOS `top`'s energy-impact score, not an SI power reading. NapWatch does not communicate the unit distinction.

Evidence: [`src/power.rs` lines 131-184](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/power.rs#L131-L184).

### 7. Wake-event identity is too weak

Events are deduplicated only by a second-resolution timestamp and later polls retain events strictly newer than the last timestamp. Multiple events can share one timestamp; the audit log contained a DarkWake and Wake at exactly `17:54:08`. A new same-second event can therefore be dropped.

Evidence: [`src/app.rs` lines 142-160](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/app.rs#L142-L160), [`src/power.rs` lines 347-390](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/power.rs#L347-L390).

### 8. Parse failures silently become valid-looking zeroes

Several parsers do not verify subprocess exit status and map missing fields to false/zero. This makes “unsupported,” “command failed,” and “actually off/zero” indistinguishable.

Evidence: [`src/power.rs` lines 60-80](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/power.rs#L60-L80), [`src/power.rs` lines 93-121](https://github.com/Tuguberk/napwatch/blob/2557b70c1e3c66943bef2af38135bd624cc8b0be/src/power.rs#L93-L121).

## Maturity and maintenance

- GitHub API showed one development day, six commits, no tags, no releases, no issues, and no pull requests.
- `cargo test --locked` compiles but runs **0 tests**.
- `cargo clippy --locked --all-targets -- -D warnings` fails with five warnings-as-errors.
- Direct dependencies are `anyhow`, `crossterm`, and `ratatui`; all declare MIT or MIT-compatible licensing, but none are needed for a native Swift implementation.

Conclusion: NapWatch is a useful executable prototype and research reference, not a dependency or production-quality component.

## License

NapWatch is MIT licensed, copyright 2026 Tugberk Akbulut. Copying substantial parser/source code requires preserving its copyright and license notice. A clean Swift implementation based on macOS interfaces and independently specified behavior reduces coupling, but attribution in a third-party notices file is still prudent if source structure or parsing logic is adapted.
