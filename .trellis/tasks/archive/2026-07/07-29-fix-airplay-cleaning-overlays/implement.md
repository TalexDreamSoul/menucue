# Implementation Plan

1. Add RED tests for local content geometry and real non-primary screen placement.
2. Extract initial cleaning overlay window construction into a testable factory.
3. Update `CleaningModeController` to attach content and present the factory window.
4. Run focused coordinator tests and a live transparent two-display probe.
5. Run full tests, formatting checks, and packaged app build.
6. Record the coordinate-space contract in the frontend state-management spec.

## Validation Commands

```bash
swift test --filter CleaningDisplayOverlayCoordinatorTests
swift test
BUILD_CONFIG=debug scripts/build-app.sh
```

## Guardrails

- Do not present black test windows.
- Do not change countdown or input-monitor lifecycle.
- Do not modify settings persistence or unrelated Quick Actions.
- Keep prior uncommitted Date & Time settings changes intact.
