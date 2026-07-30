# Implementation Plan

1. Add RED tests for update menu item construction and Dock policy transitions.
2. Implement the two small helper types and wire them into `StatusBarController`.
3. Add the footer gear button with native icon affordance, tooltip, and accessibility label.
4. Run focused tests and offscreen footer rendering.
5. Run full tests and packaged app build.

## Validation

```bash
swift test --filter StatusBarQuickAccessTests
swift test
BUILD_CONFIG=debug scripts/build-app.sh
```
