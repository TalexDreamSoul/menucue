import Foundation

enum PopoverTab: String, CaseIterable, Codable, Identifiable {
  case status
  case calendar
  case power
  case actions

  var id: String { rawValue }

  static func normalizedOrder(rawValues: [String]) -> [PopoverTab] {
    var seen = Set<PopoverTab>()
    var tabs = rawValues.compactMap(PopoverTab.init(rawValue:)).filter {
      seen.insert($0).inserted
    }
    tabs.append(contentsOf: allCases.filter { seen.insert($0).inserted })
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
