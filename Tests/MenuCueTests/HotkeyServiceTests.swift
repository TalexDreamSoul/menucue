import Foundation
import XCTest

@testable import MenuCue

/// Stands in for the system hot-key table. A registration is a global claim that outlives
/// this process's memory of it, so what a test asserts here is the pairing: nothing stays
/// claimed that the settings no longer ask for, and nothing is claimed twice.
private final class RecordingHotkeyRegistrar: HotkeyRegistering {
  struct Claim: Equatable {
    let id: UUID
    let keyCode: UInt16
    let carbonModifiers: UInt32
  }

  enum Call: Equatable {
    case register(UUID)
    case unregister(UUID)
    case unregisterAll
  }

  var handler: ((UUID) -> Void)?
  /// Combinations the fake system refuses, as if another application held them.
  var refused: Set<UInt16> = []
  private(set) var calls: [Call] = []
  private(set) var claims: [Claim] = []

  var claimedIDs: Set<UUID> { Set(claims.map(\.id)) }

  func register(
    id: UUID,
    keyCode: UInt16,
    carbonModifiers: UInt32
  ) -> Result<Void, HotkeyRegistrationFailure> {
    calls.append(.register(id))
    guard !refused.contains(keyCode) else { return .failure(.alreadyClaimed) }
    guard !claims.contains(where: { $0.keyCode == keyCode && $0.carbonModifiers == carbonModifiers })
    else {
      return .failure(.alreadyClaimed)
    }
    claims.append(Claim(id: id, keyCode: keyCode, carbonModifiers: carbonModifiers))
    return .success(())
  }

  func unregister(id: UUID) {
    calls.append(.unregister(id))
    claims.removeAll { $0.id == id }
  }

  func unregisterAll() {
    calls.append(.unregisterAll)
    claims.removeAll()
  }
}

final class HotkeyServiceTests: XCTestCase {
  private let registrar = RecordingHotkeyRegistrar()
  private lazy var service = HotkeyService(registrar: registrar)

  func testApplyingBindingsClaimsEachCompleteEnabledCombination() {
    let volume = binding(keyCode: 10, modifiers: [.command, .option])
    let dark = binding(keyCode: 11, modifiers: [.control])

    service.apply(bindings: [volume, dark])

    XCTAssertEqual(registrar.claimedIDs, [volume.id, dark.id])
    XCTAssertEqual(service.unavailableReasons, [:])
  }

  func testABindingThatCouldNeverBeRegisteredIsNeverOffered() {
    let disabled = binding(keyCode: 10, modifiers: [.command], isEnabled: false)
    let bareKey = binding(keyCode: 11, modifiers: [])
    let modifierWithoutCommandControlOrOption = binding(keyCode: 12, modifiers: [.shift])
    let withoutAction = binding(keyCode: 13, modifiers: [.command], actionItemID: "")

    service.apply(bindings: [
      disabled, bareKey, modifierWithoutCommandControlOrOption, withoutAction,
    ])

    XCTAssertEqual(
      registrar.calls, [],
      "asking the system for a combination it cannot answer would report a failure the user "
        + "cannot act on")
  }

  func testAnUnchangedCombinationKeepsItsClaimAcrossASettingsWrite() {
    var volume = binding(keyCode: 10, modifiers: [.command, .option])
    service.apply(bindings: [volume])
    let claimsAfterFirstApply = registrar.calls

    volume.name = "Louder"
    service.apply(bindings: [volume])

    XCTAssertEqual(
      registrar.calls, claimsAfterFirstApply,
      "surrendering and re-taking a combination on every write leaves a window in which "
        + "another app can claim it")
    XCTAssertEqual(registrar.claimedIDs, [volume.id])
  }

  func testTwoBindingsMayTradeCombinationsInOneApply() {
    var first = binding(keyCode: 10, modifiers: [.command])
    var second = binding(keyCode: 11, modifiers: [.command])
    service.apply(bindings: [first, second])

    swap(&first.shortcut, &second.shortcut)
    service.apply(bindings: [first, second])

    XCTAssertEqual(registrar.claimedIDs, [first.id, second.id])
    XCTAssertEqual(
      service.unavailableReasons, [:],
      "each combination has to be handed back before the other binding asks for it")
  }

  func testARemovedBindingSurrendersItsCombination() {
    let volume = binding(keyCode: 10, modifiers: [.command])
    let dark = binding(keyCode: 11, modifiers: [.command])
    service.apply(bindings: [volume, dark])

    service.apply(bindings: [dark])

    XCTAssertEqual(registrar.claimedIDs, [dark.id])
    XCTAssertTrue(registrar.calls.contains(.unregister(volume.id)))
  }

  func testACombinationTheSystemRefusesIsReportedAgainstItsOwnBinding() {
    let taken = binding(keyCode: 10, modifiers: [.command])
    let free = binding(keyCode: 11, modifiers: [.command])
    registrar.refused = [10]

    service.apply(bindings: [taken, free])

    XCTAssertEqual(registrar.claimedIDs, [free.id])
    XCTAssertEqual(
      service.unavailableReasons[taken.id],
      HotkeyRegistrationFailure.alreadyClaimed.message
    )
    XCTAssertNil(service.unavailableReasons[free.id])
  }

  func testARefusalClearsOnceTheBindingMovesToAFreeCombination() {
    var taken = binding(keyCode: 10, modifiers: [.command])
    registrar.refused = [10]
    service.apply(bindings: [taken])
    XCTAssertNotNil(service.unavailableReasons[taken.id])

    taken.shortcut = shortcut(keyCode: 11, modifiers: [.command])
    service.apply(bindings: [taken])

    XCTAssertEqual(service.unavailableReasons, [:])
    XCTAssertEqual(registrar.claimedIDs, [taken.id])
  }

  /// The half-registered state this must never reach: the old combination surrendered and
  /// the new one refused would otherwise leave the binding still answering to the shortcut
  /// the user just moved it off.
  func testMovingABindingOntoARefusedCombinationSurrendersTheOldOneAnyway() {
    var volume = binding(keyCode: 10, modifiers: [.command])
    service.apply(bindings: [volume])
    XCTAssertEqual(registrar.claimedIDs, [volume.id])

    registrar.refused = [11]
    volume.shortcut = shortcut(keyCode: 11, modifiers: [.command])
    service.apply(bindings: [volume])

    XCTAssertTrue(
      registrar.claims.isEmpty,
      "the combination the binding moved off has to be handed back even when the new one fails")
    XCTAssertEqual(
      service.unavailableReasons[volume.id],
      HotkeyRegistrationFailure.alreadyClaimed.message
    )
  }

  /// Stopping tears the registrar's whole table down, so the service has to ask for
  /// everything again rather than believe it still holds what it held before.
  func testApplyingAfterStoppingClaimsEverythingAgain() {
    let volume = binding(keyCode: 10, modifiers: [.command])
    service.apply(bindings: [volume])
    service.stop()

    service.apply(bindings: [volume])

    XCTAssertEqual(registrar.claimedIDs, [volume.id])

    var performed: [UUID] = []
    service.configure { performed.append($0.id) }
    registrar.handler?(volume.id)
    XCTAssertEqual(performed, [volume.id], "a re-claimed combination has to fire again")
  }

  func testStoppingHandsBackEveryCombination() {
    let volume = binding(keyCode: 10, modifiers: [.command])
    registrar.refused = [11]
    let refused = binding(keyCode: 11, modifiers: [.command])
    service.apply(bindings: [volume, refused])

    service.stop()

    XCTAssertTrue(registrar.claims.isEmpty)
    XCTAssertEqual(registrar.calls.last, .unregisterAll)
    XCTAssertEqual(service.unavailableReasons, [:])
  }

  func testAPressRunsTheBindingThatClaimedTheCombination() {
    let volume = binding(keyCode: 10, modifiers: [.command])
    var performed: [UUID] = []
    service.configure { performed.append($0.id) }
    service.apply(bindings: [volume])

    registrar.handler?(volume.id)

    XCTAssertEqual(performed, [volume.id])
  }

  func testAPressForABindingThatNoLongerHoldsItsCombinationRunsNothing() {
    let volume = binding(keyCode: 10, modifiers: [.command])
    var performed: [UUID] = []
    service.configure { performed.append($0.id) }
    service.apply(bindings: [volume])
    service.apply(bindings: [])

    registrar.handler?(volume.id)

    XCTAssertEqual(performed, [])
  }

  // MARK: - Fixtures

  private func shortcut(
    keyCode: UInt16,
    modifiers: Set<TrackpadModifier>
  ) -> TrackpadKeyboardShortcut {
    TrackpadKeyboardShortcut(keyCode: keyCode, characters: "K", modifiers: modifiers)
  }

  private func binding(
    keyCode: UInt16,
    modifiers: Set<TrackpadModifier>,
    actionItemID: String = "builtin:darkMode",
    isEnabled: Bool = true
  ) -> HotkeyBinding {
    HotkeyBinding(
      shortcut: shortcut(keyCode: keyCode, modifiers: modifiers),
      actionItemID: actionItemID,
      isEnabled: isEnabled
    )
  }
}
