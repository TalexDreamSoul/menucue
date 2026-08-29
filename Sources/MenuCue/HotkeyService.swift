import Carbon.HIToolbox
import Foundation

/// Why the system would not hand over a key combination.
///
/// Worth knowing about what this can and cannot see: macOS reports a conflict only for a
/// combination that is already registered this way. One it keeps for itself — ⌘Space, say —
/// registers successfully and is then never delivered, so a shortcut that loses to the
/// system looks registered here and simply does nothing when pressed.
enum HotkeyRegistrationFailure: Error, Equatable {
  case alreadyClaimed
  case refused(OSStatus)

  var message: String {
    switch self {
    case .alreadyClaimed:
      return L10n.string("This shortcut is already claimed.")
    case .refused(let status):
      return L10n.format("macOS refused this shortcut (error %d).", Int(status))
    }
  }
}

/// The system hot-key table, behind a seam. Claiming a combination is a global side effect
/// that outlives the object that asked for it, so the bookkeeping that decides what is
/// claimed is worth testing without claiming anything.
protocol HotkeyRegistering: AnyObject {
  /// Called on the main thread with the identifier of whichever registration was pressed.
  var handler: ((UUID) -> Void)? { get set }

  func register(
    id: UUID,
    keyCode: UInt16,
    carbonModifiers: UInt32
  ) -> Result<Void, HotkeyRegistrationFailure>
  func unregister(id: UUID)
  func unregisterAll()
}

/// The real table. `RegisterEventHotKey` asks the window server for the combination
/// directly, so a global shortcut needs no Accessibility access and sees no keystroke it
/// was not given.
final class CarbonHotkeyRegistrar: HotkeyRegistering {
  /// Four characters the system stores alongside each registration; ours only has to be
  /// distinct from other applications'.
  private static let signature: OSType = 0x4D43_5545

  var handler: ((UUID) -> Void)?

  private var eventHandler: EventHandlerRef?
  private var references: [UInt32: (binding: UUID, hotkey: EventHotKeyRef)] = [:]
  private var carbonIDs: [UUID: UInt32] = [:]
  private var nextCarbonID: UInt32 = 1

  deinit {
    unregisterAll()
  }

  func register(
    id: UUID,
    keyCode: UInt16,
    carbonModifiers: UInt32
  ) -> Result<Void, HotkeyRegistrationFailure> {
    installEventHandlerIfNeeded()
    unregister(id: id)

    let carbonID = nextCarbonID
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      carbonModifiers,
      EventHotKeyID(signature: Self.signature, id: carbonID),
      GetEventDispatcherTarget(),
      0,
      &reference
    )
    guard status == noErr, let reference else {
      return .failure(
        status == OSStatus(eventHotKeyExistsErr) ? .alreadyClaimed : .refused(status)
      )
    }
    nextCarbonID &+= 1
    references[carbonID] = (binding: id, hotkey: reference)
    carbonIDs[id] = carbonID
    return .success(())
  }

  func unregister(id: UUID) {
    guard let carbonID = carbonIDs.removeValue(forKey: id),
      let registration = references.removeValue(forKey: carbonID)
    else { return }
    UnregisterEventHotKey(registration.hotkey)
  }

  func unregisterAll() {
    for registration in references.values {
      UnregisterEventHotKey(registration.hotkey)
    }
    references.removeAll()
    carbonIDs.removeAll()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandler == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotkeyID
        )
        guard status == noErr else { return status }
        Unmanaged<CarbonHotkeyRegistrar>
          .fromOpaque(userData)
          .takeUnretainedValue()
          .handlePress(carbonID: hotkeyID.id)
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
  }

  private func handlePress(carbonID: UInt32) {
    guard let registration = references[carbonID] else { return }
    handler?(registration.binding)
  }
}

/// Holds the global shortcuts the user configured, and routes a press back to the binding
/// that asked for it.
///
/// A combination the system refuses is not an error the app can resolve — the shortcut
/// belongs to whoever asked first — so a refusal is kept per binding and shown on its row
/// rather than swallowed or raised as an alert.
///
/// `apply` and `stop` touch the system hot-key table and must be called on the main thread.
final class HotkeyService: ObservableObject {
  /// Why a binding is not currently claimed, keyed by binding identifier.
  @Published private(set) var unavailableReasons: [UUID: String] = [:]

  private let registrar: HotkeyRegistering
  private var perform: ((HotkeyBinding) -> Void)?
  /// What is claimed right now, which is not the same as what is stored: a binding that
  /// was refused is stored and not claimed, and only a claimed one can fire.
  private var claimed: [UUID: HotkeyBinding] = [:]

  init(registrar: HotkeyRegistering = CarbonHotkeyRegistrar()) {
    self.registrar = registrar
    registrar.handler = { [weak self] id in
      self?.trigger(id)
    }
  }

  deinit {
    registrar.unregisterAll()
  }

  func configure(perform: @escaping (HotkeyBinding) -> Void) {
    self.perform = perform
  }

  /// Reconciles the whole list against what is already claimed. Unchanged combinations
  /// keep their registration: surrendering and re-taking one on every settings write would
  /// leave a window in which another application could claim it instead.
  ///
  /// Everything that changes is surrendered before anything new is asked for, so two
  /// bindings that swap combinations do not each fail against the other's old claim.
  func apply(bindings: [HotkeyBinding]) {
    let desired = HotkeyBindingPolicy.registrable(bindings)
    let retained = desired.filter { binding in
      claimed[binding.id]?.shortcut.claimsSameKey(as: binding.shortcut) ?? false
    }
    let retainedIDs = Set(retained.map(\.id))

    for id in claimed.keys where !retainedIDs.contains(id) {
      registrar.unregister(id: id)
    }

    var nextClaimed = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
    var reasons: [UUID: String] = [:]
    for binding in desired where !retainedIDs.contains(binding.id) {
      switch registrar.register(
        id: binding.id,
        keyCode: binding.shortcut.keyCode,
        carbonModifiers: binding.shortcut.carbonModifierMask
      ) {
      case .success:
        nextClaimed[binding.id] = binding
      case .failure(let failure):
        reasons[binding.id] = failure.message
      }
    }

    claimed = nextClaimed
    if unavailableReasons != reasons { unavailableReasons = reasons }
  }

  func stop() {
    registrar.unregisterAll()
    claimed.removeAll()
    if !unavailableReasons.isEmpty { unavailableReasons = [:] }
  }

  private func trigger(_ id: UUID) {
    guard let binding = claimed[id], let perform else { return }
    if Thread.isMainThread {
      perform(binding)
    } else {
      DispatchQueue.main.async { perform(binding) }
    }
  }
}
