import XCTest
@testable import MenuCue

final class LocalizationResourceTests: XCTestCase {
  func testEnglishAndSimplifiedChineseHaveMatchingKeysAndFormatArguments() throws {
    let english = try L10n.entries(for: "en")
    let simplifiedChinese = try L10n.entries(for: "zh-Hans")

    XCTAssertFalse(english.isEmpty)
    XCTAssertEqual(Set(english.keys), Set(simplifiedChinese.keys))

    for key in english.keys.sorted() {
      XCTAssertEqual(
        L10n.formatArguments(in: english[key] ?? ""),
        L10n.formatArguments(in: simplifiedChinese[key] ?? ""),
        "Format arguments differ for localization key: \(key)"
      )
    }
  }

  func testSupportedLocalizationTablesAreBundled() throws {
    XCTAssertFalse(try L10n.entries(for: "en").isEmpty)
    XCTAssertFalse(try L10n.entries(for: "zh-Hans").isEmpty)
  }
}
