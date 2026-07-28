# Quality Guidelines

> Code quality standards for frontend development.

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

### Product display name

Use `ProductBrand.displayName` for every user-visible reference to the application name:

```swift
Text(ProductBrand.displayName)
window.title = "\(ProductBrand.displayName) Settings"
```

`MenuCue` is both the product display name and the current technical identity. Keep these values aligned during app, packaging, Helper, or distribution changes:

- Swift package, target, module, executable, app bundle filename, and source/test paths use `MenuCue*`.
- The main bundle identifier is `com.tagzxia.app.menucue`.
- The privileged Helper executable/module is `MenuCueHelper`; its daemon, Mach service, and signing identifier are `com.tagzxia.app.menucue.helper`.
- Persisted preference, cache, queue, Sparkle, repository, release artifact, and Homebrew identities use the `menucue` namespace.
- Window autosave keys and test suite names use the `MenuCue` prefix.

Packaging must set `CFBundleDisplayName`, `CFBundleName`, and `CFBundleExecutable` to `MenuCue`. The identity contract is covered by `ProductBrandTests`; update that test together with any intentional future rename.

## Testing Requirements

<!-- What level of testing is expected -->

(To be filled by the team)

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)
