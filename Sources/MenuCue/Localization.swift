import Foundation

enum L10n {
  static let bundle: Bundle = {
    if Bundle.main.bundleURL.pathExtension == "app" {
      return Bundle.main
    }
    return Bundle.module
  }()

  static func string(_ key: String) -> String {
    bundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: string(key), locale: Locale.current, arguments: arguments)
  }

  static func entries(for localization: String) throws -> [String: String] {
    guard
      let url = bundle.url(
        forResource: "Localizable",
        withExtension: "strings",
        subdirectory: nil,
        localization: localization
      ),
      let data = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: String]
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return data
  }

  static func formatArguments(in value: String) -> [String] {
    let pattern = #"%(?!%)(?:\d+\$)?[-+# 0']*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j)?[@aAcCdDeEfFgGiIoOsSuUxX]"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard let range = Range(match.range, in: value) else { return nil }
      return String(value[range])
    }
  }
}
