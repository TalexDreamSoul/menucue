import AppKit
import CoreGraphics
import XCTest
@testable import MenuCue

final class StatusItemInteractionViewTests: XCTestCase {
    func testScrollWheelForwardsTheOriginalEventExactlyOnce() throws {
        let view = StatusItemInteractionView(frame: .zero)
        var receivedEvents: [NSEvent] = []
        view.onScroll = { receivedEvents.append($0) }
        let cgEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 12,
                wheel2: 0,
                wheel3: 0
            )
        )
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        view.scrollWheel(with: event)

        XCTAssertEqual(receivedEvents.count, 1)
        XCTAssertTrue(receivedEvents[0] === event)
        XCTAssertEqual(receivedEvents[0].type, .scrollWheel)
    }

    func testMouseUpRoutesPrimaryControlAndRightClicksToTheirExpectedActions() throws {
        let view = StatusItemInteractionView(frame: .zero)
        var primaryClicks = 0
        var secondaryClicks = 0
        view.onPrimaryClick = { primaryClicks += 1 }
        view.onSecondaryClick = { secondaryClicks += 1 }

        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, modifierFlags: []))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, modifierFlags: [.control]))
        view.rightMouseUp(with: try mouseEvent(type: .rightMouseUp, modifierFlags: []))

        XCTAssertEqual(primaryClicks, 1)
        XCTAssertEqual(secondaryClicks, 2)
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
