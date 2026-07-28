import XCTest
@testable import MenuCue

/// Does every key the code asks for actually exist in the catalogs?
///
/// The two guards that came before this one both compare the catalogs to *each other*:
/// same keys, same format arguments. Neither reads the source. So a `L10n.string("…")`
/// whose key was never added to the catalogs passes every check and then silently falls
/// back to English at runtime — which is exactly how six dead Chinese translations
/// shipped once already. This closes the loop in the other direction: source → catalog.
final class LocalizationCoverageTests: XCTestCase {
  func testEveryLiteralL10nKeyExistsInTheCatalogs() throws {
    let english = try L10n.entries(for: "en")
    var missing: [String] = []

    for file in try Self.swiftSources() {
      let source = try String(contentsOf: file, encoding: .utf8)
      for key in Self.literalKeys(in: source) where english[key] == nil {
        missing.append("\(file.lastPathComponent): \"\(key)\"")
      }
    }

    XCTAssertEqual(
      missing.sorted(), [],
      "These keys are requested in code but absent from the catalogs, so they render in "
        + "English regardless of the chosen language.")
  }

  /// A key built by interpolation is not a key. `L10n.string("Launch \(Brand.name)")`
  /// looks up a string that was never written down, so it always falls through.
  func testNoL10nKeyIsBuiltByInterpolation() throws {
    var interpolated: [String] = []
    for file in try Self.swiftSources() {
      let source = try String(contentsOf: file, encoding: .utf8)
      for key in Self.literalKeys(in: source) where key.contains("\\(") {
        interpolated.append("\(file.lastPathComponent): \"\(key)\"")
      }
    }
    XCTAssertEqual(interpolated.sorted(), [])
  }

  /// The scanner covers literal call sites only. Enough of them have to be literal for
  /// the two tests above to mean anything — if a refactor made most keys dynamic, they
  /// would keep passing while checking nothing.
  func testTheScannerStillSeesMostOfTheCallSites() throws {
    var literal = 0
    var total = 0
    for file in try Self.swiftSources() {
      let source = try String(contentsOf: file, encoding: .utf8)
      literal += Self.literalKeys(in: source).count
      total += source.components(separatedBy: "L10n.string(").count - 1
      total += source.components(separatedBy: "L10n.format(").count - 1
    }
    XCTAssertGreaterThan(total, 100, "sanity: the app localizes a lot of strings")
    XCTAssertGreaterThan(
      Double(literal) / Double(total), 0.85,
      "Only \(literal) of \(total) call sites pass a literal key; the coverage test above "
        + "can no longer vouch for the rest.")
  }

  // MARK: - Scanning

  private static func swiftSources() throws -> [URL] {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/MenuCue")
    return try FileManager.default
      .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
      .sorted { $0.path < $1.path }
  }

  /// Pulls the first argument out of `L10n.string(` / `L10n.format(` when it is a plain
  /// string literal. Call sites that pass a variable or a ternary yield nothing — they
  /// are unverifiable from source and are deliberately skipped rather than guessed at.
  static func literalKeys(in source: String) -> [String] {
    var keys: [String] = []
    let characters = Array(source)

    for callee in ["L10n.string(", "L10n.format("] {
      let needle = Array(callee)
      var index = 0
      while index + needle.count <= characters.count {
        guard Array(characters[index..<(index + needle.count)]) == needle else {
          index += 1
          continue
        }
        var cursor = index + needle.count
        // The argument commonly starts on the next line for long keys.
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        index += needle.count

        guard cursor < characters.count, characters[cursor] == "\"" else { continue }
        // Multi-line literals have their own escaping rules; none are used as keys,
        // and mis-parsing one would be worse than skipping it.
        if cursor + 2 < characters.count,
          characters[cursor + 1] == "\"", characters[cursor + 2] == "\""
        { continue }

        cursor += 1
        var key = ""
        var escaped = false
        var terminated = false
        while cursor < characters.count {
          let character = characters[cursor]
          if escaped {
            // Keep the backslash: an interpolated key must still read as `\(` so the
            // interpolation test can see it.
            key.append("\\")
            key.append(character)
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            terminated = true
            break
          } else {
            key.append(character)
          }
          cursor += 1
        }
        if terminated { keys.append(Self.unescape(key)) }
      }
    }
    return keys
  }

  /// Catalog keys hold the real characters, not the source escapes.
  private static func unescape(_ literal: String) -> String {
    guard literal.contains("\\") else { return literal }
    var result = ""
    var characters = Array(literal)[...]
    while let character = characters.first {
      characters = characters.dropFirst()
      guard character == "\\", let next = characters.first else {
        result.append(character)
        continue
      }
      switch next {
      case "n": result.append("\n")
      case "t": result.append("\t")
      case "\"": result.append("\"")
      case "\\": result.append("\\")
      default:
        // `\(` and anything else stays verbatim so it fails loudly rather than quietly.
        result.append("\\")
        result.append(next)
      }
      characters = characters.dropFirst()
    }
    return result
  }
}
