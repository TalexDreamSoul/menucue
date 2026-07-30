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

## macOS deployment compatibility

### Contract

- MenuCue supports macOS 13 Ventura and newer. Keep `Package.swift`, `LSMinimumSystemVersion`, the main executable, the Helper, Sparkle appcast metadata, and Homebrew Cask requirements aligned.
- macOS 13 is the architectural floor while the app depends on `SMAppService`, `NavigationSplitView`, and SwiftUI `Layout`.
- Put optional newer presentation behavior behind small shared availability-gated View modifiers. Do not duplicate complete macOS-version-specific screens.
- Use the pre-macOS-14 single-parameter `onChange` overload when the old value and initial delivery are not required.
- System APIs with changed authorization contracts, such as EventKit in macOS 14, must keep a version-appropriate fallback that publishes the same app-level state.
- A compatibility release must be compiled with the actual lower deployment target. Source-level availability checks alone are insufficient.

### Validation

- Contract tests assert both SwiftPM and app-bundle minimum versions.
- A clean build at the declared minimum must report no unavailable-API errors.
- Inspect Mach-O `LC_BUILD_VERSION` for both MenuCue and MenuCueHelper.
- Verify the app extracted from the final notarized ZIP and check the Sparkle item's `minimumSystemVersion`.

## Settings navigation and section deep links

### Convention: Route status actions to the owning section

**What**: When a settings pane contains multiple scrollable feature groups, model each deep-linkable group with a stable `Hashable` section identifier. A status or remediation action must select the owning pane and request its section in the same state transition. The detail view uses `ScrollViewReader` and scrolls after the destination content is installed.

**Why**: Selecting only the parent pane can leave the requested control below the fold, preserving the same findability problem that consolidation was intended to solve.

**Example**:

```swift
enum DateTimeSettingsSection: Hashable {
  case menuBar
  case calendar
  case systemTimeZone
}

requestedDateTimeSection = .calendar
selectedPane = .dateAndTime

ScrollViewReader { proxy in
  content
    .task(id: activeDateTimeSection) {
      guard let section = activeDateTimeSection else { return }
      await Task.yield()
      proxy.scrollTo(section, anchor: .top)
    }
}
```

Direct sidebar navigation must clear any pending section request so an old deep link does not unexpectedly reposition a later visit. Tests must assert both the destination pane and destination section.

## Testing Requirements

<!-- What level of testing is expected -->

(To be filled by the team)

### Pattern: Headless visual verification of popover views

**Problem**: Popover UI can't be screenshotted through the live app when the session is
headless — with the screen locked, `screencapture` returns black, synthetic clicks fail
(`CGEvent` posts no-op; System Events `click at` errors with `-25200`), and
`NSPopover.show` doesn't even materialize a window.

**Two extra traps specific to this app**:
- The status item routes clicks through a custom `mouseDown` override
  (`StatusItemInteractionView`), so AX `click menu bar item 1 of menu bar 1` never
  opens the popover even with the screen unlocked — only a real mouse event does.
- For scripted *interactive* runs, launch with `MENUCUE_SWIPE_LOG=1`: the app calls
  `StatusBarController.debugShowPopover()` 1.5 s after launch and logs the popover
  window frame to stderr.

**Solution**: Render the SwiftUI view offscreen from a scratch XCTest — works locked,
headless, and in ~0.1 s:

```swift
@MainActor
final class ScratchRenderTests: XCTestCase {   // delete before commit
  func testRender() throws {
    let view = SomePopoverView(state: fixture)
      .frame(width: 312)                       // popover card content width
      .padding(10)
      .background(Color(red: 0.11, green: 0.11, blue: 0.12))
      .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/render.png"))
  }
}
```

Run with `swift test --filter ScratchRenderTests`, inspect the PNGs, delete the file.
312 pt is the usable card width (360 popover − 2×14 content − 2×10 card padding).

**Why**: `@testable import MenuCue` gives tests direct access to executable-target
views, and `ImageRenderer` draws via CoreGraphics without a window server session.

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)
