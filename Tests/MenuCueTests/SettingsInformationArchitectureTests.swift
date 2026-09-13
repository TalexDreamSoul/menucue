import XCTest

@testable import MenuCue

final class SettingsInformationArchitectureTests: XCTestCase {
  func testPanesAreGroupedIntoDisplayInteractionNotificationsAndSystem() {
    XCTAssertEqual(
      SettingsPane.allCases,
      [
        .menuBar,
        .panel,
        .calendar,
        .trackpad,
        .hotkeys,
        .actionCenter,
        .alerts,
        .power,
        .timeZone,
        .general,
        .about,
      ]
    )

    XCTAssertEqual(SettingsPaneGroup.display.panes, [.menuBar, .panel, .calendar])
    XCTAssertEqual(SettingsPaneGroup.interaction.panes, [.trackpad, .hotkeys, .actionCenter])
    XCTAssertEqual(SettingsPaneGroup.alerts.panes, [.alerts])
    XCTAssertEqual(SettingsPaneGroup.system.panes, [.power, .timeZone, .general, .about])
  }

  /// The group that holds the alerts pane is named after the *family*, not after the
  /// pane: one key holds one translation, so a group must not reuse a pane's wording.
  func testGroupTitlesAreDistinctFromPaneTitles() {
    let groupTitles = Set(SettingsPaneGroup.allCases.map(\.title))
    let paneTitles = Set(SettingsPane.allCases.map(\.title))
    XCTAssertTrue(groupTitles.isDisjoint(with: paneTitles))
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
    XCTAssertEqual(SettingsPane.actionCenter.title, L10n.string("Action Library"))
    XCTAssertEqual(SettingsPane.alerts.title, L10n.string("Alert Rules"))
    XCTAssertEqual(SettingsPane.timeZone.title, L10n.string("Time & Region"))
    XCTAssertEqual(SettingsPane.timeZone.systemImage, "globe")
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

    // The new pane has to answer to every identifier it has been written as.
    XCTAssertEqual(SettingsPane.migrating(rawValue: "timeZone"), .timeZone)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "timezone"), .timeZone)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "region"), .timeZone)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "timeAndRegion"), .timeZone)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "languageRegion"), .timeZone)

    // Unchanged identifiers keep resolving to themselves.
    XCTAssertEqual(SettingsPane.migrating(rawValue: "trackpad"), .trackpad)
    XCTAssertEqual(SettingsPane.migrating(rawValue: "about"), .about)

    XCTAssertNil(SettingsPane.migrating(rawValue: "nonsense"))
  }
}
