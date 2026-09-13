import AppKit
import Foundation
import XCTest

@testable import MenuCue

/// What the "Restore defaults" action has to deliver: the missing built-in shortcuts come
/// back into the stored list, reach the system registrar, and running it again neither
/// reports work nor disturbs what is already there.
final class AppModelHotkeyDefaultsTests: XCTestCase {
  func testRestoringAnEmptyListBringsBackAndRegistersEveryDefault() {
    let suite = "MenuCueTests.AppModelHotkeyDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = makeStore(defaults: defaults) { $0.hotkeyBindings = [] }
    let registrar = HotkeyClaimRecorder()
    let model = makeModel(store: store, registrar: registrar)

    let restored = model.restoreBuiltInHotkeyDefaults()

    XCTAssertEqual(restored, HotkeyBuiltInDefaults.bindings.count)
    XCTAssertEqual(model.settings.hotkeyBindings, HotkeyBuiltInDefaults.bindings)
    XCTAssertEqual(
      SettingsStore(defaults: defaults).load().hotkeyBindings,
      HotkeyBuiltInDefaults.bindings,
      "the restore has to reach disk, not just this model instance")
    XCTAssertEqual(
      registrar.claimedIDs,
      Set(HotkeyBuiltInDefaults.bindings.map(\.id)),
      "restored shortcuts must be handed to the system registrar")
  }

  func testASecondRestoreReportsNothingAndLeavesTheListAlone() {
    let suite = "MenuCueTests.AppModelHotkeyDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = makeStore(defaults: defaults) { $0.hotkeyBindings = [] }
    let registrar = HotkeyClaimRecorder()
    let model = makeModel(store: store, registrar: registrar)
    XCTAssertEqual(model.restoreBuiltInHotkeyDefaults(), HotkeyBuiltInDefaults.bindings.count)

    let second = model.restoreBuiltInHotkeyDefaults()

    XCTAssertEqual(second, 0)
    XCTAssertEqual(model.settings.hotkeyBindings, HotkeyBuiltInDefaults.bindings)
  }

  /// A partial removal restores the one missing shortcut, keeps the user's own binding
  /// that claimed another default's key, and does not re-add the default it displaced.
  func testRestoringFillsTheGapWithoutTakingBackAUserClaim() {
    let suite = "MenuCueTests.AppModelHotkeyDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let removed = HotkeyBuiltInDefaults.bindings[3]
    let displaced = HotkeyBuiltInDefaults.bindings[0]
    let userClaim = HotkeyBinding(
      name: "My maximize",
      shortcut: displaced.shortcut,
      actionItemID: "builtin:darkMode")
    let store = makeStore(defaults: defaults) { settings in
      // The user deleted one default and replaced another with their own shortcut.
      settings.hotkeyBindings = HotkeyBuiltInDefaults.bindings.filter {
        $0.id != removed.id && $0.id != displaced.id
      }
      settings.hotkeyBindings.append(userClaim)
    }
    let registrar = HotkeyClaimRecorder()
    let model = makeModel(store: store, registrar: registrar)

    let restored = model.restoreBuiltInHotkeyDefaults()

    XCTAssertEqual(restored, 1)
    XCTAssertTrue(model.settings.hotkeyBindings.contains { $0.id == removed.id })
    XCTAssertFalse(
      model.settings.hotkeyBindings.contains { $0.id == displaced.id },
      "the default whose key the user's shortcut took must not come back")
    let kept = model.settings.hotkeyBindings.first { $0.id == userClaim.id }
    XCTAssertEqual(kept?.shortcut, userClaim.shortcut)
  }

  private func makeStore(
    defaults: UserDefaults,
    seed: (inout AppSettings) -> Void
  ) -> SettingsStore {
    let store = SettingsStore(defaults: defaults)
    var settings = store.load()
    seed(&settings)
    store.save(settings)
    return store
  }

  private func makeModel(store: SettingsStore, registrar: HotkeyClaimRecorder) -> AppModel {
    _ = NSApplication.shared
    return AppModel(
      settingsStore: store,
      calendarService: CalendarService(),
      appearanceService: AppearanceService(),
      hotkeyService: HotkeyService(registrar: registrar)
    )
  }
}

/// Stands in for the system hot-key table: what the model hands the service is what the
/// registrar is asked to claim.
private final class HotkeyClaimRecorder: HotkeyRegistering {
  var handler: ((UUID) -> Void)?
  private(set) var claimedIDs: Set<UUID> = []

  func register(
    id: UUID,
    keyCode: UInt16,
    carbonModifiers: UInt32
  ) -> Result<Void, HotkeyRegistrationFailure> {
    claimedIDs.insert(id)
    return .success(())
  }

  func unregister(id: UUID) {
    claimedIDs.remove(id)
  }

  func unregisterAll() {
    claimedIDs.removeAll()
  }
}
