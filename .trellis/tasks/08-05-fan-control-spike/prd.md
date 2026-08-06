# Fan speed control spike

Parent: `08-05-menubar-ux-system-control`

## Goal

Answer one question with evidence: **does Apple silicon accept SMC fan writes on the machines
MenuCue targets?** Produce a go/no-go recommendation for building user-facing fan control.

This is a spike. It ships no feature and no UI. Its deliverable is a written finding.

## Why this is a gate

`SystemSensorReader.swift` already talks to `AppleSMC`, but read-only. Adding writes means a
new privileged surface in `MenuCueHelper` and a thermal-safety contract. None of that is worth
designing if the writes are rejected by the firmware.

SMC write ACLs are known to differ across Apple silicon generations, and the target machine is
recent: **Mac16,7 / Apple M4 Pro / macOS 26.5**. Whether `F0Md`/`F0Tg` writes take effect there
is an empirical question, not one to settle from prior art on older chips.

## What to determine

1. Does writing `F{n}Md = 1` (forced mode) succeed, and does the SMC report it back?
2. Does writing `F{n}Tg` change the observed `F{n}Ac` within a reasonable settling window?
3. Does writing `F{n}Md = 0` reliably return the fan to Apple's automatic curve?
4. Is root sufficient, or is SIP / a specific entitlement also involved?
5. Do the answers hold on Intel, if an Intel machine is reachable? If not, record it as untested
   rather than assumed.

## Technical starting points

- Existing read client: `SystemSensorReader.swift:89-221`. Selector `2`
  (`kSMCHandleYPCEvent`), commands `9` = read key info, `5` = read bytes.
- Write is command `6`.
- `F{n}Md` is `ui8`: `0` auto, `1` forced.
- `F{n}Tg` is `fpe2`: big-endian `UInt16` of `rpm * 4`. `SystemSensorReader.swift:178-180`
  already decodes this type and can be inverted for encoding.
- Bounds come from the already-read `F{n}Mn` and `F{n}Mx`.

## Requirements

1. The probe runs as a standalone root binary, kept out of the shipping targets. It must not
   be wired into `MenuCue` or `MenuCueHelper` during the spike.
2. It restores `F{n}Md = 0` on every exit path, including signals and errors. A probe that
   leaves fans forced is unacceptable.
3. It never sets a target below `F{n}Mn`. Raising the floor is safe; lowering it is not.
4. It logs each step with the value written, the value read back, and the observed RPM, so the
   finding rests on data rather than recollection.
5. Findings are written to this task's `research/` directory, including the exact machine model
   and macOS build they were produced on.

## Acceptance Criteria

- [ ] A written finding exists in `research/` answering questions 1-4 with logged evidence.
- [ ] The finding states a clear go / no-go for user-facing fan control, with reasoning.
- [ ] If go: the finding records the safety contract a real feature would need — clamping to
      `[F{n}Mn, F{n}Mx]`, restore-to-auto on app quit and on helper `prepareForRemoval`, and a
      helper-side heartbeat watchdog that restores auto if the app stops checking in.
- [ ] If go: it also records which Macs are covered and which are untested.
- [ ] The test machine's fans are confirmed back under automatic control after the spike.
- [ ] No probe code is left in `Sources/MenuCue` or `Sources/MenuCueHelper`.

## Out of scope

- Any UI, setting, or persisted preference.
- The `MenuCueHelper` protocol change, capability flag, and version bump. Those belong to the
  feature task this spike may authorize.
- Fan curve editing, per-app profiles, or temperature-driven targets.

## Risk note

A crash or a killed process that leaves fans forced below the automatic curve is a thermal
hazard for the machine. Restore-to-auto is the single hardest requirement in this task and the
main reason the spike exists before the feature.
