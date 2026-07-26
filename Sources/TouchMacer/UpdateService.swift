import Combine
import Foundation

@MainActor
protocol UpdateEngine: AnyObject {
  var automaticallyChecksForUpdates: Bool { get set }
  var automaticallyDownloadsUpdates: Bool { get set }
  var canCheckForUpdates: Bool { get }
  var lastUpdateCheckDate: Date? { get }
  var stateDidChange: (() -> Void)? { get set }
  var statusDidChange: ((UpdateStatus) -> Void)? { get set }

  func checkForUpdates()
}

enum UpdateStatus: Equatable {
  case idle
  case checking
  case available(version: String)
  case downloading(version: String)
  case downloaded(version: String)
  case installing(version: String)
  case current
  case failed(message: String)
}

@MainActor
final class UpdateService: ObservableObject {
  @Published private(set) var automaticUpdatesEnabled: Bool
  @Published private(set) var canCheckForUpdates: Bool
  @Published private(set) var lastUpdateCheckDate: Date?
  @Published private(set) var status: UpdateStatus = .idle

  private let engine: UpdateEngine

  init(engine: UpdateEngine) {
    self.engine = engine
    self.automaticUpdatesEnabled = engine.automaticallyChecksForUpdates
      && engine.automaticallyDownloadsUpdates
    self.canCheckForUpdates = engine.canCheckForUpdates
    self.lastUpdateCheckDate = engine.lastUpdateCheckDate

    engine.stateDidChange = { [weak self] in
      self?.refreshState()
    }
    engine.statusDidChange = { [weak self] status in
      self?.status = status
      self?.refreshState()
    }
  }

  func setAutomaticUpdatesEnabled(_ enabled: Bool) {
    engine.automaticallyChecksForUpdates = enabled
    engine.automaticallyDownloadsUpdates = enabled
    refreshState()
  }

  func checkForUpdates() {
    guard engine.canCheckForUpdates else { return }
    status = .checking
    engine.checkForUpdates()
    refreshState()
  }

  private func refreshState() {
    automaticUpdatesEnabled = engine.automaticallyChecksForUpdates
      && engine.automaticallyDownloadsUpdates
    canCheckForUpdates = engine.canCheckForUpdates
    lastUpdateCheckDate = engine.lastUpdateCheckDate
  }
}
