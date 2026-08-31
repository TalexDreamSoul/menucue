import Foundation
import XCTest

@testable import MenuCue

/// The catalog is now the register both action surfaces read from, so what it hands the
/// popover has to stay exactly what the popover used to build for itself, and what it
/// hands the trackpad has to stay complete.
final class ActionCatalogTests: XCTestCase {
  func testPanelSurfaceOffersTheBuiltInQuickActionsThenTheShortcutsInOrder() {
    let shortcuts = ["Zeta Routine", "Alpha Routine"]
    let expected =
      BuiltInQuickActionID.allCases.map(QuickActionReference.builtIn)
      + shortcuts.map(QuickActionReference.shortcut)

    XCTAssertEqual(
      ActionCatalog.quickActionReferences(surface: .panel, shortcuts: shortcuts),
      expected,
      "the popover grid is generated from the catalog; its contents and order must not shift"
    )
  }

  func testTheServiceCatalogStillMatchesTheCatalogsPanelSurface() {
    let service = QuickActionService(appearanceService: AppearanceService())

    XCTAssertEqual(
      service.catalogItems.map(\.reference),
      ActionCatalog.quickActionReferences(surface: .panel, shortcuts: []),
      "Quick Actions are generated from the catalog, so the two must never disagree"
    )
  }

  func testNoTrackpadOnlyActionLeaksIntoThePanel() {
    let panel = ActionCatalog.items(surface: .panel, shortcuts: ["Routine"])

    XCTAssertTrue(
      panel.allSatisfy { item in
        if case .quickAction = item.route { return true }
        return false
      },
      "this task registers the trackpad's own actions without exposing them in the popover"
    )
  }

  func testEveryTrackpadSystemOperationIsRegisteredExactlyOnce() {
    let trackpad = ActionCatalog.items(surface: .trackpad)
    let actions: [TrackpadGestureAction] = trackpad.compactMap { item in
      guard case .trackpad(let action) = item.route else { return nil }
      return action
    }

    for control in TrackpadSystemControl.allCases {
      XCTAssertEqual(
        actions.filter { $0.kind == .systemControl && $0.systemControl == control }.count,
        1,
        control.rawValue
      )
    }
    for placement in TrackpadWindowAction.allCases {
      XCTAssertEqual(
        actions.filter { $0.kind == .window && $0.windowAction == placement }.count,
        1,
        placement.rawValue
      )
    }
    for click in TrackpadMouseAction.allCases {
      XCTAssertEqual(
        actions.filter { $0.kind == .mouse && $0.mouseAction == click }.count,
        1,
        click.rawValue
      )
    }
    for direction in TrackpadDirection.allCases {
      XCTAssertEqual(
        actions.filter { $0.kind == .scroll && $0.scrollDirection == direction }.count,
        1,
        direction.rawValue
      )
    }
    XCTAssertTrue(
      trackpad.contains { $0.route == .trackpadPointerWindow },
      "activating the window under the pointer is a trackpad capability like the others"
    )

    for surface in ActionSurface.allCases {
      let identifiers = ActionCatalog.items(surface: surface, shortcuts: ["Routine"]).map(\.id)
      XCTAssertEqual(
        identifiers.count,
        Set(identifiers).count,
        "two entries sharing an identity would collide in \(surface.rawValue)"
      )
    }
  }

  func testEveryTrackpadEntryIsFoundAgainFromTheActionARuleStores() {
    for item in ActionCatalog.trackpadNativeActions {
      guard case .trackpad(let action) = item.route else { continue }
      XCTAssertEqual(
        ActionCatalog.itemID(for: action),
        item.id,
        "a rule stores the action, so the way back to \(item.id) has to agree with the way it "
          + "was registered"
      )
    }
  }

  func testAnActionReportsBeingPinnedAndEveryRuleThatSelectsIt() {
    let item = ActionCatalog.builtInQuickActions.first { $0.id == "builtin:darkMode" }!
    let rules = [
      makeRule(
        name: "Dark",
        action: TrackpadGestureAction(kind: .quickAction, quickActionStorageValue: "builtin:darkMode")
      ),
      makeRule(name: "Louder", action: .system(.volumeUp)),
      makeRule(
        name: "Also dark",
        action: TrackpadGestureAction(kind: .quickAction, quickActionStorageValue: "builtin:darkMode")
      ),
    ]

    XCTAssertEqual(
      ActionCatalog.references(of: item, pinned: [.builtIn(.darkMode)], rules: rules),
      [.pinned, .gestureRule(name: "Dark"), .gestureRule(name: "Also dark")]
    )
    XCTAssertEqual(
      ActionCatalog.references(of: item, pinned: [.builtIn(.lockScreen)], rules: []),
      [],
      "another action being pinned says nothing about this one"
    )
  }

  func testATrackpadEntryReportsTheRulesThatSelectedIt() {
    let volumeUp = ActionCatalog.trackpadNativeActions.first {
      $0.id == "trackpad:systemControl:volumeUp"
    }!
    let leftHalf = ActionCatalog.trackpadNativeActions.first {
      $0.id == "trackpad:window:leftHalf"
    }!
    let rules = [makeRule(name: "Louder", action: .system(.volumeUp))]

    XCTAssertEqual(
      ActionCatalog.references(of: volumeUp, pinned: [], rules: rules),
      [.gestureRule(name: "Louder")]
    )
    XCTAssertEqual(
      ActionCatalog.references(of: leftHalf, pinned: [], rules: rules),
      [],
      "one system control being used must not light up the whole trackpad section"
    )
  }

  func testThePointerWindowEntryIsReferencedByTheRulesThatRunItFirst() {
    let pointerWindow = ActionCatalog.trackpadNativeActions.first {
      $0.route == .trackpadPointerWindow
    }!
    var rule = makeRule(name: "Focus first", action: .system(.volumeUp))
    rule.activatesWindowUnderPointer = true

    XCTAssertEqual(
      ActionCatalog.references(of: pointerWindow, pinned: [], rules: [rule]),
      [.gestureRule(name: "Focus first")]
    )
  }

  func testEveryBuiltInActionIsInExactlyOneCategory() {
    let categorized = BuiltInQuickActionCategory.allCases.flatMap { category in
      BuiltInQuickActionID.allCases.filter { $0.category == category }
    }

    XCTAssertEqual(
      Set(categorized), Set(BuiltInQuickActionID.allCases),
      "the popover lists the built-ins by category, so an uncategorized action would vanish")
    XCTAssertEqual(categorized.count, BuiltInQuickActionID.allCases.count)
  }

  func testEveryRegisteredItemHasATitleAndAnIcon() {
    for item in ActionCatalog.items(surface: .trackpad, shortcuts: ["Routine"])
      + ActionCatalog.items(surface: .panel, shortcuts: ["Routine"])
    {
      XCTAssertFalse(item.title.isEmpty, item.id)
      XCTAssertFalse(item.systemImage.isEmpty, item.id)
    }
  }

  func testOnlyTheActionsThatSynthesizeInputRequireAccessibility() {
    let requiring: Set<TrackpadGestureActionKind> = [.keyboardShortcut, .mouse, .scroll, .window]

    for kind in TrackpadGestureActionKind.allCases {
      let requirement = ActionCatalog.requirement(forActionKind: kind)
      if requiring.contains(kind) {
        guard case .accessibility(let reason) = requirement else {
          return XCTFail("\(kind.rawValue) synthesizes input and must ask for Accessibility")
        }
        XCTAssertFalse(reason.isEmpty, kind.rawValue)
      } else {
        XCTAssertEqual(requirement, ActionRequirement.none, kind.rawValue)
      }
    }
  }

  func testADeniedRequirementReportsBothTheReasonAndWhereToFixIt() {
    let settingsURL = URL(string: "x-test://accessibility")!
    let requirement = ActionCatalog.requirement(forActionKind: .window)

    let denied = ActionCatalog.availability(
      for: requirement,
      accessibilityStatus: .denied,
      accessibilitySettingsURL: settingsURL
    )
    let granted = ActionCatalog.availability(
      for: requirement,
      accessibilityStatus: .granted,
      accessibilitySettingsURL: settingsURL
    )

    XCTAssertFalse(denied.isAvailable)
    XCTAssertEqual(
      denied.reason,
      L10n.string("Allow Accessibility access to place windows.")
    )
    XCTAssertEqual(
      denied.settingsURL,
      settingsURL,
      "a failure the user can fix has to say where to fix it"
    )
    XCTAssertTrue(granted.isAvailable)
    XCTAssertNil(granted.reason)
  }

  func testTheExecutorReportsTheSameStructuredAvailabilityForADeniedAction() {
    let settingsURL = URL(string: "x-test://accessibility")!
    let executor = TrackpadActionExecutor(
      quickActionService: QuickActionService(appearanceService: AppearanceService()),
      accessibilityPermissionRequester: DeniedAccessibilityPermissionRequester(
        settingsURL: settingsURL
      )
    )

    let placement = executor.availability(
      for: TrackpadGestureAction(kind: .window, windowAction: .leftHalf)
    )
    let volume = executor.availability(for: .system(.volumeUp))

    XCTAssertFalse(placement.isAvailable)
    XCTAssertEqual(placement.settingsURL, settingsURL)
    XCTAssertTrue(volume.isAvailable, "volume goes through CoreAudio and needs no permission")
  }

  func testAnUnresolvableQuickActionReferenceIsReportedAsUnavailable() {
    let executor = TrackpadActionExecutor(
      quickActionService: QuickActionService(appearanceService: AppearanceService()),
      accessibilityPermissionRequester: DeniedAccessibilityPermissionRequester(
        settingsURL: URL(string: "x-test://accessibility")!
      )
    )

    let availability = executor.availability(
      for: TrackpadGestureAction(kind: .quickAction, quickActionStorageValue: "builtin:removed")
    )

    XCTAssertFalse(availability.isAvailable)
    XCTAssertEqual(
      availability.reason,
      L10n.string("The selected Quick Action is no longer available.")
    )
  }
  func testTabNavigationRoutesAreHotkeyOnlyAndResolveFromTheirStableIdentifiers() {
    let expected: [(action: TrackpadTabAction, identifier: String)] = [
      (.previous, "trackpad:tabNavigation:previous"),
      (.next, "trackpad:tabNavigation:next"),
    ]
    let hotkey = ActionCatalog.items(surface: .hotkey)
    let trackpad = ActionCatalog.items(surface: .trackpad)
    let tabRoutes = hotkey.compactMap { item -> TrackpadTabAction? in
      guard case .tabNavigation(let action) = item.route else { return nil }
      return action
    }
    XCTAssertEqual(tabRoutes.count, expected.count)

    for expectedRoute in expected {
      let entry = hotkey.first { $0.id == expectedRoute.identifier }

      XCTAssertEqual(entry?.route, .tabNavigation(expectedRoute.action))
      XCTAssertFalse(
        trackpad.contains { $0.id == expectedRoute.identifier },
        "Tab traversal has no gesture configuration and must not appear in the trackpad action picker"
      )
      XCTAssertEqual(
        ActionCatalog.route(forItemID: expectedRoute.identifier),
        .tabNavigation(expectedRoute.action),
        "a hotkey stores only this stable identifier, so it must resolve to the Tab route"
      )
    }
  }
}

private func makeRule(name: String, action: TrackpadGestureAction) -> TrackpadGestureRule {
  TrackpadGestureRule(
    name: name,
    trigger: TrackpadGestureTrigger(kind: .contact, fingerCount: 2),
    action: action
  )
}

/// A gesture must never trigger the Accessibility prompt, so this stub fails the test if
/// anything asks it to.
private struct DeniedAccessibilityPermissionRequester: AccessibilityPermissionRequesting {
  let settingsURL: URL

  var status: AccessibilityPermissionStatus { .denied }
  var accessibilitySettingsURL: URL { settingsURL }

  func requestAccess() -> Bool {
    XCTFail("running an action must not prompt for Accessibility access")
    return false
  }
}
