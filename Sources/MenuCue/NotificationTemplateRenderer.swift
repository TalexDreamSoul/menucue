import Foundation

enum NotificationTemplateError: Error, Equatable {
  case malformedTemplate
  case unknownVariable(String)
  case outputTooLong
}

enum NotificationTemplateToken: Equatable, Sendable {
  case text(String)
  case variable(String)
}

enum AlertTemplateContextBuilder {
  static func values(
    rule: AlertRule,
    observation: AlertMetricObservation,
    deviceName: String,
    state: NotificationEventState
  ) -> [String: String] {
    let definition = AlertMetricCatalog.definition(for: rule.metricID)
    var values = observation.context
    values["device.name"] = deviceName
    values["rule.name"] = rule.name
    values["metric.id"] = rule.metricID.rawValue
    values["metric.name"] = L10n.string(rule.metricID.rawValue)
    values["target.name"] = values["target.name"] ?? rule.targetID ?? ""
    values["event.time"] = ISO8601DateFormatter().string(from: observation.sampledAt)
    values["alert.state"] = state.rawValue

    if let metricValue = observation.value {
      values["metric.value"] = AlertMetricFormatter.string(
        for: metricValue,
        definition: definition
      )
      values["metric.unit"] = unitText(definition?.unit)
    }
    switch rule.condition {
    case .numeric(_, let threshold):
      values["metric.threshold"] = AlertMetricFormatter.string(
        for: .number(threshold), definition: definition)
    case .severity(_, let threshold):
      values["metric.threshold"] = String(threshold)
    case .boolean(let expected):
      values["metric.threshold"] = expected ? "true" : "false"
    case .event:
      values["metric.threshold"] = ""
    }
    return values
  }

  static func unitText(_ unit: AlertMetricUnit?) -> String {
    switch unit {
    case .fraction: return "%"
    case .bytes: return "B"
    case .bytesPerSecond: return "B/s"
    case .operationsPerSecond: return "ops/s"
    case .celsius: return "°C"
    case .rpm: return "RPM"
    case .watts: return "W"
    case .percentPerHour: return "%/h"
    case .load, .some(.none), nil: return ""
    }
  }
}

enum NotificationTemplateRenderer {
  static let maximumCharacters = NotificationMessage.maximumRenderedCharacters

  static let allowedVariables: Set<String> = [
    "device.name",
    "rule.name",
    "metric.id",
    "metric.name",
    "metric.value",
    "metric.unit",
    "metric.threshold",
    "target.name",
    "event.kind",
    "event.reason",
    "event.time",
    "alert.state",
  ]

  static let defaultAlertTitleTemplate = "{{rule.name}}"
  static let defaultAlertBodyTemplate = "{{device.name}} alert: {{metric.value}}"
  static let defaultRecoveryTitleTemplate = "{{rule.name}} recovered"
  static let defaultRecoveryBodyTemplate = "{{device.name}} recovered: {{metric.value}}"

  static let defaultAlertBody = try! parse(defaultAlertBodyTemplate)
  static let defaultRecoveryBody = try! parse(defaultRecoveryBodyTemplate)

  static func parse(_ source: String) throws -> [NotificationTemplateToken] {
    var tokens: [NotificationTemplateToken] = []
    var cursor = source.startIndex

    while cursor < source.endIndex {
      guard let opening = source.range(of: "{{", range: cursor..<source.endIndex) else {
        let remainder = String(source[cursor...])
        guard !remainder.contains("}}") else { throw NotificationTemplateError.malformedTemplate }
        appendText(remainder, to: &tokens)
        break
      }

      let prefix = String(source[cursor..<opening.lowerBound])
      guard !prefix.contains("}}") else { throw NotificationTemplateError.malformedTemplate }
      appendText(prefix, to: &tokens)

      guard
        let closing = source.range(of: "}}", range: opening.upperBound..<source.endIndex)
      else {
        throw NotificationTemplateError.malformedTemplate
      }
      let variable = String(source[opening.upperBound..<closing.lowerBound])
      guard isValidVariableName(variable) else {
        throw NotificationTemplateError.malformedTemplate
      }
      guard allowedVariables.contains(variable) else {
        throw NotificationTemplateError.unknownVariable(variable)
      }
      tokens.append(.variable(variable))
      cursor = closing.upperBound
    }

    if source.isEmpty { return [] }
    return tokens
  }

  static func render(
    _ tokens: [NotificationTemplateToken],
    values: [String: String]
  ) throws -> String {
    var rendered = ""
    for token in tokens {
      switch token {
      case .text(let text):
        rendered += text
      case .variable(let name):
        rendered += values[name] ?? ""
      }
      guard rendered.count <= maximumCharacters else {
        throw NotificationTemplateError.outputTooLong
      }
    }
    return rendered
  }

  static func render(_ source: String, values: [String: String]) throws -> String {
    try render(parse(source), values: values)
  }

  private static func appendText(
    _ text: String,
    to tokens: inout [NotificationTemplateToken]
  ) {
    guard !text.isEmpty else { return }
    if case .text(let existing) = tokens.last {
      tokens[tokens.count - 1] = .text(existing + text)
    } else {
      tokens.append(.text(text))
    }
  }

  private static func isValidVariableName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.")
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}
