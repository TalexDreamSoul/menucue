#!/usr/bin/env swift

import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(1)
}

func loadStrings(at path: String) -> [String: String] {
  do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard
      let entries = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: String]
    else {
      fail("Invalid strings dictionary: \(path)")
    }
    return entries
  } catch {
    fail("Unable to read \(path): \(error.localizedDescription)")
  }
}

func formatArguments(in value: String) -> [String] {
  // `%%` is matched first and then discarded, so the scanner steps over *both* of its
  // characters. Skipping only the first with a `%(?!%)` lookahead left the second `%`
  // free to start a match against the following text: a space is a valid flag and `o`
  // is a valid conversion, so `"%d%% of the time"` reported a phantom `% o` argument
  // and disagreed with a translation that says the same thing in fewer words.
  let pattern = #"%%|%(?:\d+\$)?[-+# 0']*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j)?[@aAcCdDeEfFgGiIoOsSuUxX]"#
  guard let expression = try? NSRegularExpression(pattern: pattern) else {
    fail("Unable to compile format-argument verifier.")
  }
  let range = NSRange(value.startIndex..<value.endIndex, in: value)
  return expression.matches(in: value, range: range).compactMap { match in
    guard let range = Range(match.range, in: value) else { return nil }
    let argument = String(value[range])
    // An escaped literal percent is not an argument.
    return argument == "%%" ? nil : argument
  }
}

guard CommandLine.arguments.count == 3 else {
  fail("Usage: verify-localizations.swift <en Localizable.strings> <zh-Hans Localizable.strings>")
}

let english = loadStrings(at: CommandLine.arguments[1])
let simplifiedChinese = loadStrings(at: CommandLine.arguments[2])
let englishKeys = Set(english.keys)
let simplifiedChineseKeys = Set(simplifiedChinese.keys)

guard englishKeys == simplifiedChineseKeys else {
  let missingChinese = englishKeys.subtracting(simplifiedChineseKeys).sorted().joined(separator: ", ")
  let missingEnglish = simplifiedChineseKeys.subtracting(englishKeys).sorted().joined(separator: ", ")
  fail("Localization keys differ. Missing zh-Hans: [\(missingChinese)]; missing en: [\(missingEnglish)]")
}

for key in englishKeys.sorted() {
  guard
    formatArguments(in: english[key] ?? "")
      == formatArguments(in: simplifiedChinese[key] ?? "")
  else {
    fail("Localization format arguments differ for key: \(key)")
  }
}

print("Verified \(englishKeys.count) localization keys.")
