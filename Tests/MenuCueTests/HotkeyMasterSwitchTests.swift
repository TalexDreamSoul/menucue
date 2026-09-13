import AppKit
import Foundation
import XCTest

@testable import MenuCue

/// The hotkeys master switch makes a promise about the system hot-key table, not about the
/// stored list: switching it off keeps every binding on disk and claims none of them. These
/// tests read that promise where a caller does — what a fresh store loads, and what the
/// registrar ends up holding.
final class HotkeyMasterSwitchTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
    suiteName = "MenuCueTests.HotkeyMasterSwitchTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  func testHotkeysMasterSwitchRoundTripsThroughTheSettingsStore() {
    let store = SettingsStore(defaults: defaults)

    var settings = store.load()
    settings.hotkeysGloballyEnabled = false
    store.save(settings)
    XCTAssertFalse(store.load().hotkeysGloballyEnabled)

    settings.hotkeysGloballyEnabled = true
    store.save(settings)
    XCTAssertTrue(store.load().hotkeysGloballyEnabled)
  }

  /// Shortcuts worked before the switch existed, so a store that never saw the key has to
  /// keep registering: reading "never set" as off would silently disable every shortcut an
  /// existing user already had.
  func testAStoreThatNeverSawTheHotkeysSwitchLoadsItEnabled() {
    XCTAssertTrue(SettingsStore(defaults: defaults).load().hotkeysGloballyEnabled)
  }

  func testRegisteredHotkeyBindingsAreEmptyOnlyWhileTheSwitchIsOff() {
    let binding = HotkeyBinding(
      shortcut: TrackpadKeyboardShortcut(
        keyCode: 10, characters: "K", modifiers: [.command]),
      actionItemID: "builtin:darkMode"
    )
    var settings = makeSettings()
    settings.hotkeysGloballyEnabled = false
    settings.hotkeyBindings = [binding]

    XCTAssertEqual(settings.registeredHotkeyBindings, [], "off registers no combination")
    settings.hotkeysGloballyEnabled = true
    XCTAssertEqual(settings.registeredHotkeyBindings, [binding])
  }

  /// Off has to reach the system table, not just the stored struct: the app model hands
  /// exactly `registeredHotkeyBindings` to the service, so off claims nothing and turning it
  /// back on claims the whole list again without a restart.
  func testTurningTheSwitchOffStopsRegistrationAndTurningItBackOnRestoresIt() {
    let store = SettingsStore(defaults: defaults)
    var stored = store.load()
    stored.hotkeysGloballyEnabled = false
    store.save(stored)

    let registrar = MasterSwitchRegistrar()
    let model = AppModel(
      settingsStore: store,
      calendarService: CalendarService(),
      appearanceService: AppearanceService(),
      hotkeyService: HotkeyService(registrar: registrar)
    )

    XCTAssertFalse(model.settings.hotkeyBindings.isEmpty)
    XCTAssertTrue(
      registrar.claimed.isEmpty,
      "a stored binding is not registered while the master switch is off")

    model.updateSettings { $0.hotkeysGloballyEnabled = true }

    XCTAssertEqual(
      registrar.claimed, Set(model.settings.hotkeyBindings.map(\.id)),
      "turning the switch back on registers every stored binding")
  }

  private func makeSettings() -> AppSettings {
    AppSettings(
      statusBarSwitchIntervalSeconds: 5,
      appearanceMode: .system,
      appearanceTimeZoneID: "UTC",
      appliesSystemAppearance: false,
      overviewTimeZoneID: "UTC",
      calendarWeekStartDay: .monday,
      calendarSelectionMode: .all,
      selectedCalendarIDs: [],
      pinnedQuickActions: []
    )
  }
}

/// Stands in for the system hot-key table so a test can see what the switch let through.
private final class MasterSwitchRegistrar: HotkeyRegistering {
  var handler: ((UUID) -> Void)?
  private(set) var claimed: Set<UUID> = []

  func register(
    id: UUID,
    keyCode: UInt16,
    carbonModifiers: UInt32
  ) -> Result<Void, HotkeyRegistrationFailure> {
    claimed.insert(id)
    return .success(())
  }

  func unregister(id: UUID) {
    claimed.remove(id)
  }

  func unregisterAll() {
    claimed.removeAll()
  }
}
