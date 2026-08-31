import CoreGraphics
import Foundation

/// Which system currently owns the pointer's display surface. A mirrored display is still
/// visible to this Mac, but any locally synthesized automation would be applied here rather
/// than to the AirPlay receiver, so raw gestures must remain pass-through.
enum TrackpadInputOwnership: Equatable {
  case local
  case mirroredDisplay
  /// Universal Control does not expose remote focus publicly. A pointer outside every
  /// local display is therefore treated as handed off rather than risking local capture.
  case remoteOrUnknown

  var acceptsLocalAutomation: Bool { self == .local }
}

enum TrackpadInputOwnershipPolicy {
  static func ownership(
    pointerDisplayID: CGDirectDisplayID?,
    isInMirrorSet: (CGDirectDisplayID) -> Bool
  ) -> TrackpadInputOwnership {
    guard let pointerDisplayID, isInMirrorSet(pointerDisplayID) else { return .local }
    return .mirroredDisplay
  }
}

enum SystemTrackpadInputOwnership {
  static func current() -> TrackpadInputOwnership {
    guard let pointerEvent = CGEvent(source: nil) else { return .local }
    var displayID = CGDirectDisplayID()
    var displayCount: UInt32 = 0
    guard
      CGGetDisplaysWithPoint(pointerEvent.location, 1, &displayID, &displayCount) == .success,
      displayCount == 1
    else {
      // Universal Control does not expose the remote Mac's focus through a public API.
      // When the pointer is outside every local display, fail closed: native input may
      // continue to the remote Mac but MenuCue must not run a local gesture action.
      return .remoteOrUnknown
    }
    return TrackpadInputOwnershipPolicy.ownership(
      pointerDisplayID: displayID,
      isInMirrorSet: { CGDisplayIsInMirrorSet($0) != 0 }
    )
  }
}
