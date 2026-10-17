import Foundation

enum PopoverTab: String, CaseIterable, Codable, Identifiable {
  case status
  case calendar
  case overview
  case power
  case actions

  var id: String { rawValue }

  static func normalizedOrder(rawValues: [String]) -> [PopoverTab] {
    var seen = Set<PopoverTab>()
    var tabs = rawValues.compactMap(PopoverTab.init(rawValue:)).filter {
      seen.insert($0).inserted
    }
    if tabs == [.status, .calendar, .power, .actions, .overview] {
      return allCases
    }
    for tab in allCases where !seen.contains(tab) {
      if let index = allCases.firstIndex(of: tab) {
        let insertIndex = min(index, tabs.count)
        tabs.insert(tab, at: insertIndex)
      } else {
        tabs.append(tab)
      }
      seen.insert(tab)
    }
    if tabs == [.status, .calendar, .power, .actions, .overview] {
      return allCases
    }
    return tabs
  }

  func moving(by offset: Int) -> PopoverTab {
    moving(by: offset, in: Self.allCases)
  }

  func moving(by offset: Int, in tabs: [PopoverTab]) -> PopoverTab {
    let normalizedTabs = Self.normalizedOrder(rawValues: tabs.map(\.rawValue))
    guard let index = normalizedTabs.firstIndex(of: self) else {
      return normalizedTabs.first ?? self
    }
    let destination = (index + offset) % normalizedTabs.count
    return normalizedTabs[destination >= 0 ? destination : destination + normalizedTabs.count]
  }
}
