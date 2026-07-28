import AppKit
import Foundation

enum MenuBarFormatValidation: Equatable {
    case valid
    case emptyTimePattern
    case invalidTimePattern
    case invalidDatePattern
    case emptyTimeOutput
    case emptyDateOutput

    var message: String? {
        switch self {
        case .valid:
            return nil
        case .emptyTimePattern:
            return "Time pattern cannot be empty."
        case .invalidTimePattern:
            return "Time pattern must contain a valid time symbol and balanced quotes."
        case .invalidDatePattern:
            return "Date pattern contains unbalanced quotes."
        case .emptyTimeOutput:
            return "Time pattern produced no visible output."
        case .emptyDateOutput:
            return "Date pattern produced no visible output."
        }
    }
}

struct MenuBarClockRendering: Equatable {
    let dateText: String?
    let timeText: String
    let segmentOrder: MenuBarSegmentOrder

    var combinedText: String {
        switch (dateText, segmentOrder) {
        case let (.some(dateText), .dateThenTime):
            return "\(dateText) \(timeText)"
        case let (.some(dateText), .timeThenDate):
            return "\(timeText) \(dateText)"
        case (.none, _):
            return timeText
        }
    }
}

final class MenuBarClockRenderer {
    private var format: MenuBarFormatSettings
    private var locale: Locale
    private let dateFormatter = DateFormatter()
    private let timeFormatter = DateFormatter()

    init(
        format: MenuBarFormatSettings = .compatibilityDefault,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.format = format
        self.locale = locale
        rebuildFormatters()
    }

    func update(
        format: MenuBarFormatSettings,
        locale: Locale = .autoupdatingCurrent
    ) {
        guard self.format != format || self.locale.identifier != locale.identifier else { return }
        self.format = format
        self.locale = locale
        rebuildFormatters()
    }

    func render(date: Date, clock: ClockTimeZone) -> MenuBarClockRendering {
        dateFormatter.timeZone = clock.timeZone
        timeFormatter.timeZone = clock.timeZone

        let timeText = timeFormatter.string(from: date).trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedDate = dateFormatter.dateFormat.isEmpty
            ? nil
            : dateFormatter.string(from: date).trimmingCharacters(in: .whitespacesAndNewlines)

        return MenuBarClockRendering(
            dateText: renderedDate?.isEmpty == false ? renderedDate : nil,
            timeText: timeText,
            segmentOrder: format.segmentOrder
        )
    }

    static func exceedsRecommendedWidth(
        _ text: String,
        maximumWidth: CGFloat = 360,
        font: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    ) -> Bool {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attributes).width > maximumWidth
    }

    static func validation(
        for format: MenuBarFormatSettings,
        date: Date = Date(),
        clock: ClockTimeZone = .system(timeZone: .autoupdatingCurrent),
        locale: Locale = .autoupdatingCurrent
    ) -> MenuBarFormatValidation {
        if format.mode == .advanced {
            let timePattern = format.advancedTimePattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !timePattern.isEmpty else { return .emptyTimePattern }
            guard hasBalancedQuotes(timePattern), containsTimeSymbol(timePattern) else {
                return .invalidTimePattern
            }

            let datePattern = format.advancedDatePattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard datePattern.isEmpty || hasBalancedQuotes(datePattern) else {
                return .invalidDatePattern
            }
        }

        let renderer = MenuBarClockRenderer(format: format, locale: locale)
        let output = renderer.render(date: date, clock: clock)
        guard !output.timeText.isEmpty else { return .emptyTimeOutput }
        if renderer.dateFormatter.dateFormat.isEmpty == false, output.dateText == nil {
            return .emptyDateOutput
        }
        return .valid
    }

    private func rebuildFormatters() {
        dateFormatter.locale = locale
        timeFormatter.locale = locale

        switch format.mode {
        case .structured:
            if format == .compatibilityDefault {
                dateFormatter.dateFormat = "EEE MMM d"
                timeFormatter.dateFormat = "HH:mm:ss"
            } else {
                dateFormatter.dateFormat = Self.structuredDatePattern(for: format, locale: locale)
                timeFormatter.dateFormat = Self.structuredTimePattern(for: format, locale: locale)
            }
        case .advanced:
            dateFormatter.dateFormat = format.advancedDatePattern
            timeFormatter.dateFormat = format.advancedTimePattern
        }
    }

    private static func structuredDatePattern(
        for format: MenuBarFormatSettings,
        locale: Locale
    ) -> String {
        let weekdayTemplate: String
        switch format.weekdayStyle {
        case .hidden: weekdayTemplate = ""
        case .short: weekdayTemplate = "EEE"
        case .full: weekdayTemplate = "EEEE"
        }

        switch format.dateStyle {
        case .hidden:
            return weekdayTemplate
        case .systemShort:
            return DateFormatter.dateFormat(
                fromTemplate: "\(weekdayTemplate)yMd",
                options: 0,
                locale: locale
            ) ?? "\(weekdayTemplate) M/d/y"
        case .abbreviated:
            return DateFormatter.dateFormat(
                fromTemplate: "\(weekdayTemplate)MMMd",
                options: 0,
                locale: locale
            ) ?? "\(weekdayTemplate) MMM d"
        case .iso:
            return weekdayTemplate.isEmpty ? "yyyy-MM-dd" : "\(weekdayTemplate) yyyy-MM-dd"
        }
    }

    private static func structuredTimePattern(
        for format: MenuBarFormatSettings,
        locale: Locale
    ) -> String {
        let template: String
        switch format.clockCycle {
        case .system:
            template = format.showsSeconds ? "jms" : "jm"
        case .twelveHour:
            template = format.showsSeconds ? "hms" : "hm"
        case .twentyFourHour:
            template = format.showsSeconds ? "Hms" : "Hm"
        }
        return DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
            ?? fallbackTimePattern(for: format)
    }

    private static func fallbackTimePattern(for format: MenuBarFormatSettings) -> String {
        switch (format.clockCycle, format.showsSeconds) {
        case (.twelveHour, true): return "h:mm:ss a"
        case (.twelveHour, false): return "h:mm a"
        case (.system, true), (.twentyFourHour, true): return "HH:mm:ss"
        case (.system, false), (.twentyFourHour, false): return "HH:mm"
        }
    }

    private static func hasBalancedQuotes(_ pattern: String) -> Bool {
        var insideQuote = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            guard pattern[index] == "'" else {
                index = pattern.index(after: index)
                continue
            }

            let next = pattern.index(after: index)
            if next < pattern.endIndex, pattern[next] == "'" {
                index = pattern.index(after: next)
                continue
            }

            insideQuote.toggle()
            index = next
        }
        return !insideQuote
    }

    private static func containsTimeSymbol(_ pattern: String) -> Bool {
        let symbols = Set("hHkKjJmsSaAzZvVXx")
        var insideQuote = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "'" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "'" {
                    index = pattern.index(after: next)
                    continue
                }
                insideQuote.toggle()
            } else if !insideQuote, symbols.contains(character) {
                return true
            }
            index = pattern.index(after: index)
        }
        return false
    }
}
