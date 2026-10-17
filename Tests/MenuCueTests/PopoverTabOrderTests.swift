import Foundation
import XCTest

@testable import MenuCue

final class PopoverTabOrderTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: SettingsStore!

  override func setUp() {
    super.setUp()
    suiteName = "MenuCueTests.PopoverTabOrderTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
    store = SettingsStore(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    store = nil
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  func testMissingPreferenceUsesProductDefaultOrder() {
    XCTAssertEqual(store.load().popoverTabOrder, [.status, .calendar, .overview, .power, .actions])
  }

  func testStoredOrderKeepsKnownTabsOnceAndAppendsMissingTabs() {
    defaults.set(
      ["calendar", "future-tab", "calendar", "status"],
      forKey: "popoverTabOrder.v1"
    )

    XCTAssertEqual(store.load().popoverTabOrder, [.calendar, .status, .overview, .power, .actions])
  }
  func testLegacyOrderWithOverviewAtEndMigratesToCenter() {
    defaults.set(
      ["status", "calendar", "power", "actions", "overview"],
      forKey: "popoverTabOrder.v1"
    )

    XCTAssertEqual(store.load().popoverTabOrder, [.status, .calendar, .overview, .power, .actions])
  }

  func testLegacyFourTabOrderInsertsOverviewInCenter() {
    defaults.set(
      ["status", "calendar", "power", "actions"],
      forKey: "popoverTabOrder.v1"
    )

    XCTAssertEqual(store.load().popoverTabOrder, [.status, .calendar, .overview, .power, .actions])
  }

  func testEmptyStoredOrderCannotHideBuiltInTabs() {
    defaults.set([], forKey: "popoverTabOrder.v1")

    XCTAssertEqual(store.load().popoverTabOrder, PopoverTab.allCases)
  }

  func testReorderedTabsRoundTrip() {
    var settings = store.load()
    settings.movePopoverTabs(fromOffsets: IndexSet(integer: 0), toOffset: 5)

    store.save(settings)

    XCTAssertEqual(
      SettingsStore(defaults: defaults).load().popoverTabOrder,
      [.calendar, .overview, .power, .actions, .status]
    )
  }

  func testNavigationUsesConfiguredOrderAndWraps() {
    let order: [PopoverTab] = [.overview, .calendar, .actions, .status, .power]

    XCTAssertEqual(PopoverTab.calendar.moving(by: 1, in: order), .actions)
    XCTAssertEqual(PopoverTab.power.moving(by: 1, in: order), .overview)
    XCTAssertEqual(PopoverTab.overview.moving(by: -1, in: order), .power)
  }
}
