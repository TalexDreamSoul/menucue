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

  func testBrandBearingSwiftUIKeysResolveInSimplifiedChinese() throws {
    let simplifiedChinese = try L10n.entries(for: "zh-Hans")
    let keys = [
      "When enabled, MenuCue switches the system Light/Dark appearance via macOS Automation permissions. When disabled, only this app previews the selected appearance.",
      "Launch MenuCue at login",
      "MenuCue starts only when you open it.",
      "MenuCue will start automatically after you sign in.",
      "macOS requires approval before MenuCue can start at login.",
      "Launch at Login is available when MenuCue runs from its app bundle.",
    ]

    for key in keys {
      let translation = try XCTUnwrap(simplifiedChinese[key], "Missing localization key: \(key)")
      XCTAssertNotEqual(translation, key, "Simplified Chinese falls back to English: \(key)")
    }
  }

  func testLocalizedSwiftUIStringsDoNotInterpolateTheBrandConstant() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MenuCue/StatusPopoverView.swift"
      ),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("\\(ProductBrand.displayName)"))
  }
}
