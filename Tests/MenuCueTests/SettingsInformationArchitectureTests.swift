import XCTest

@testable import MenuCue

final class SettingsInformationArchitectureTests: XCTestCase {
  func testPanesAreGroupedIntoInterfaceInputAndSystem() {
    XCTAssertEqual(
      SettingsPane.allCases,
      [
        .menuBar,
        .panel,
        .calendar,
        .actionCenter,
        .trackpad,
        .hotkeys,
        .alerts,
        .power,
        .general,
        .about,
      ]
    )

    XCTAssertEqual(SettingsPaneGroup.interface.panes, [.menuBar, .panel, .calendar, .actionCenter])
    XCTAssertEqual(SettingsPaneGroup.input.panes, [.trackpad, .hotkeys, .alerts])
    XCTAssertEqual(SettingsPaneGroup.system.panes, [.power, .general, .about])
  }

  /// Every pane belongs to exactly one group, and the sidebar shows every pane: a pane
  /// that no group claims would be unreachable while still answering `allCases`.
  func testEveryPaneAppearsInExactlyOneGroup() {
    let grouped = SettingsPaneGroup.allCases.flatMap(\.panes)
    XCTAssertEqual(grouped.count, SettingsPane.allCases.count)
    XCTAssertEqual(Set(grouped), Set(SettingsPane.allCases))
  }

  func testConsolidatedPanesUseClearLabels() {
    XCTAssertEqual(SettingsPane.menuBar.title, L10n.string("Menu Bar"))
    XCTAssertEqual(SettingsPane.menuBar.systemImage, "menubar.rectangle")
    XCTAssertEqual(SettingsPane.actionCenter.title, L10n.string("Action Center"))
    XCTAssertEqual(SettingsPane.general.title, L10n.string("General"))
  }

  /// Old deep links have to land on whichever pane now owns the setting they pointed
  /// at, or the reorganization silently breaks every saved link and script.
  func testLegacyPaneIdentifiersMigrateToTheirNewOwner() {
    XCTAssertEqual(SettingsPane.migrating(rawValue: "overview"), .panel)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "dateAndTime"), .menuBar)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "quickActions"), .actionCenter)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "notifications"), .alerts)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "appearance"), .general)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "iCloud"), .general)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "language"), .general)

    // Unchanged identifiers keep resolving to themselves.
    XCTAssertEqual(SettingsPane.migrating(rawValue: "trackpad"), .trackpad)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "about"), .about)

    XCTAssertNil(SettingsPane.migrating(rawValue: "nonsense"))
  }
}
