import XCTest

@testable import MenuCue

final class SettingsInformationArchitectureTests: XCTestCase {
  func testRelatedDateAndCalendarPanesAreConsolidated() {
    XCTAssertEqual(
      SettingsPane.allCases,
      [
        .dashboard,
        .overview,
        .dateAndTime,
        .trackpad,
        .quickActions,
        .notifications,
        .appearance,
        .iCloud,
        .language,
        .about,
      ]
    )
  }

  func testConsolidatedPaneUsesClearLabels() {
    XCTAssertEqual(SettingsPane.dateAndTime.title, L10n.string("Date & Time"))
    XCTAssertEqual(SettingsPane.dateAndTime.systemImage, "calendar.badge.clock")
    XCTAssertEqual(SettingsPane.language.title, L10n.string("Language"))
    XCTAssertEqual(SettingsPane.language.systemImage, "globe")
  }

  func testCalendarStatusRoutesToConsolidatedPane() {
    XCTAssertEqual(OverviewSettingsView.calendarStatusDestination, .dateAndTime)
    XCTAssertEqual(OverviewSettingsView.calendarStatusSection, .calendar)
  }
}
