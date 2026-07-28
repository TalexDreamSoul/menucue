import Foundation
import XCTest
@testable import MenuCue

final class MenuBarClockRendererTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let date = Date(timeIntervalSince1970: 1_768_482_245) // 2026-01-15 13:04:05 UTC
    private let utcClock = ClockTimeZone.custom(identifier: "UTC")!

    func testCompatibilityPresetRendersLegacyDateAndTimeAtFixedLocaleAndTimeZone() {
        let output = render(.compatibilityDefault)

        XCTAssertEqual(output.dateText, "Thu Jan 15")
        XCTAssertEqual(output.timeText, "13:04:05")
        XCTAssertEqual(output.combinedText, "Thu Jan 15 13:04:05")
    }

    func testStructuredClockCyclesRespectSecondsAtFixedLocaleAndTimeZone() {
        let cases: [(name: String, cycle: ClockCycle, seconds: Bool, expected: String)] = [
            ("12-hour with seconds", .twelveHour, true, "1:04:05\u{202F}PM"),
            ("24-hour without seconds", .twentyFourHour, false, "13:04"),
            ("system cycle without seconds", .system, false, "1:04\u{202F}PM")
        ]

        for testCase in cases {
            var format = hiddenDateFormat()
            format.clockCycle = testCase.cycle
            format.showsSeconds = testCase.seconds

            let output = render(format)

            XCTAssertNil(output.dateText, "\(testCase.name) should hide the date segment")
            XCTAssertEqual(output.timeText, testCase.expected, "\(testCase.name) should use the selected cycle and precision")
        }
    }

    func testStructuredDateWeekdayAndOrderCombinationsRenderSemanticSegments() {
        var isoWithFullWeekday = hiddenDateFormat()
        isoWithFullWeekday.dateStyle = .iso
        isoWithFullWeekday.weekdayStyle = .full
        isoWithFullWeekday.segmentOrder = .dateThenTime

        let dateFirst = render(isoWithFullWeekday)
        XCTAssertEqual(dateFirst.dateText, "Thursday 2026-01-15")
        XCTAssertEqual(dateFirst.combinedText, "Thursday 2026-01-15 13:04")

        var timeFirst = isoWithFullWeekday
        timeFirst.segmentOrder = .timeThenDate
        let output = render(timeFirst)
        XCTAssertEqual(output.combinedText, "13:04 Thursday 2026-01-15")

        var abbreviated = hiddenDateFormat()
        abbreviated.dateStyle = .abbreviated
        abbreviated.weekdayStyle = .short
        let abbreviatedDate = try! XCTUnwrap(render(abbreviated).dateText)
        XCTAssertTrue(abbreviatedDate.contains("Thu"))
        XCTAssertTrue(abbreviatedDate.contains("Jan"))
        XCTAssertTrue(abbreviatedDate.contains("15"))

        var systemShort = hiddenDateFormat()
        systemShort.dateStyle = .systemShort
        let systemShortDate = try! XCTUnwrap(render(systemShort).dateText)
        XCTAssertTrue(systemShortDate.contains("1"))
        XCTAssertTrue(systemShortDate.contains("15"))
        XCTAssertTrue(systemShortDate.contains("2026"))
    }

    func testHiddenDateLeavesOnlyTimeSegmentEvenWhenWeekdayStyleIsConfigured() {
        var format = hiddenDateFormat()
        format.weekdayStyle = .hidden

        let output = render(format)

        XCTAssertNil(output.dateText)
        XCTAssertEqual(output.combinedText, "13:04")
    }

    func testAdvancedPatternsRenderAndRejectInvalidActiveOutput() {
        var format = MenuBarFormatSettings.compatibilityDefault
        format.mode = .advanced
        format.advancedDatePattern = "yyyy/MM/dd"
        format.advancedTimePattern = "HH-mm"
        format.segmentOrder = .timeThenDate

        XCTAssertEqual(MenuBarClockRenderer.validation(for: format, date: date, clock: utcClock, locale: locale), .valid)
        XCTAssertEqual(render(format).combinedText, "13-04 2026/01/15")

        var emptyTime = format
        emptyTime.advancedTimePattern = "   "
        XCTAssertEqual(MenuBarClockRenderer.validation(for: emptyTime, date: date, clock: utcClock, locale: locale), .emptyTimePattern)

        var literalOnlyTime = format
        literalOnlyTime.advancedTimePattern = "'clock'"
        XCTAssertEqual(MenuBarClockRenderer.validation(for: literalOnlyTime, date: date, clock: utcClock, locale: locale), .invalidTimePattern)

        var unterminatedDate = format
        unterminatedDate.advancedDatePattern = "'date"
        XCTAssertEqual(MenuBarClockRenderer.validation(for: unterminatedDate, date: date, clock: utcClock, locale: locale), .invalidDatePattern)
    }

    func testResetEquivalentCompatibilityPresetProducesOriginalVisibleClock() {
        var changed = MenuBarFormatSettings.compatibilityDefault
        changed.mode = .advanced
        changed.advancedDatePattern = "yyyy-MM-dd"
        changed.advancedTimePattern = "HH:mm"

        XCTAssertNotEqual(render(changed).combinedText, render(.compatibilityDefault).combinedText)
        XCTAssertEqual(render(.compatibilityDefault).combinedText, "Thu Jan 15 13:04:05")
    }

    func testRecommendedWidthWarningDistinguishesCompatibilityAndExcessiveClockText() {
        let compatibilityText = render(.compatibilityDefault).combinedText
        let excessiveText = String(repeating: "Wednesday, September 30 2026 13:04:05 ", count: 12)

        XCTAssertFalse(MenuBarClockRenderer.exceedsRecommendedWidth(compatibilityText, maximumWidth: 360))
        XCTAssertTrue(MenuBarClockRenderer.exceedsRecommendedWidth(excessiveText, maximumWidth: 360))
        XCTAssertTrue(MenuBarClockRenderer.exceedsRecommendedWidth(excessiveText, maximumWidth: 100))
    }

    private func hiddenDateFormat() -> MenuBarFormatSettings {
        var format = MenuBarFormatSettings.compatibilityDefault
        format.dateStyle = .hidden
        format.weekdayStyle = .hidden
        format.showsSeconds = false
        return format
    }

    private func render(_ format: MenuBarFormatSettings) -> MenuBarClockRendering {
        MenuBarClockRenderer(format: format, locale: locale).render(date: date, clock: utcClock)
    }
}
