import AppKit
import Foundation

struct CleaningDisplaySnapshot {
  let id: CGDirectDisplayID
  let frame: NSRect
  let screen: NSScreen?

  init(id: CGDirectDisplayID, frame: NSRect, screen: NSScreen? = nil) {
    self.id = id
    self.frame = frame
    self.screen = screen
  }

  init?(screen: NSScreen) {
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else {
      return nil
    }
    self.init(id: screenNumber.uint32Value, frame: screen.frame, screen: screen)
  }
}

final class CleaningDisplayOverlayCoordinator<Overlay: AnyObject> {
  typealias DisplayProvider = () -> [CleaningDisplaySnapshot]
  typealias OverlayFactory = (CleaningDisplaySnapshot) -> Overlay?
  typealias OverlayUpdater = (Overlay, CleaningDisplaySnapshot) -> Void
  typealias OverlayRemover = (Overlay) -> Void

  private let notificationCenter: NotificationCenter
  private let changeNotification: Notification.Name
  private let displays: DisplayProvider
  private let makeOverlay: OverlayFactory
  private let updateOverlay: OverlayUpdater
  private let removeOverlay: OverlayRemover

  private var changeObserver: NSObjectProtocol?
  private var overlaysByDisplayID: [CGDirectDisplayID: Overlay] = [:]

  var overlayCount: Int {
    overlaysByDisplayID.count
  }

  init(
    notificationCenter: NotificationCenter,
    changeNotification: Notification.Name,
    displays: @escaping DisplayProvider,
    makeOverlay: @escaping OverlayFactory,
    updateOverlay: @escaping OverlayUpdater,
    removeOverlay: @escaping OverlayRemover
  ) {
    self.notificationCenter = notificationCenter
    self.changeNotification = changeNotification
    self.displays = displays
    self.makeOverlay = makeOverlay
    self.updateOverlay = updateOverlay
    self.removeOverlay = removeOverlay
  }

  deinit {
    if let changeObserver {
      notificationCenter.removeObserver(changeObserver)
    }
  }

  func start() {
    stop()
    reconcileDisplays()
    changeObserver = notificationCenter.addObserver(
      forName: changeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reconcileDisplays()
    }
  }

  func stop() {
    if let changeObserver {
      notificationCenter.removeObserver(changeObserver)
      self.changeObserver = nil
    }
    for overlay in overlaysByDisplayID.values {
      removeOverlay(overlay)
    }
    overlaysByDisplayID.removeAll()
  }

  private func reconcileDisplays() {
    var seenDisplayIDs = Set<CGDirectDisplayID>()
    let currentDisplays = displays().filter { display in
      seenDisplayIDs.insert(display.id).inserted
    }
    let currentDisplayIDs = Set(currentDisplays.map(\.id))

    let removedDisplayIDs = overlaysByDisplayID.keys.filter {
      !currentDisplayIDs.contains($0)
    }
    for displayID in removedDisplayIDs {
      guard let overlay = overlaysByDisplayID.removeValue(forKey: displayID) else { continue }
      removeOverlay(overlay)
    }

    for display in currentDisplays {
      if let overlay = overlaysByDisplayID[display.id] {
        updateOverlay(overlay, display)
      } else if let overlay = makeOverlay(display) {
        overlaysByDisplayID[display.id] = overlay
      }
    }
  }
}
