import Foundation
import Sparkle

enum SparkleUpdateStatusResolver {
  static func cycleErrorStatus(_ error: NSError) -> UpdateStatus {
    guard error.domain == SUSparkleErrorDomain else {
      return .failed(message: error.localizedDescription)
    }
    switch error.code {
    case Int(SUError.noUpdateError.rawValue):
      return noUpdateStatus(error)
    case Int(SUError.installationCanceledError.rawValue):
      return .idle
    default:
      return .failed(message: error.localizedDescription)
    }
  }

  static func noUpdateStatus(_ error: NSError) -> UpdateStatus {
    let reasonRawValue = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
    switch reasonRawValue {
    case Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue),
      Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue):
      return .current
    default:
      return .failed(message: error.localizedDescription)
    }
  }
}

@MainActor
final class SparkleUpdateEngine: NSObject, UpdateEngine, SPUUpdaterDelegate {
  var stateDidChange: (() -> Void)?
  var statusDidChange: ((UpdateStatus) -> Void)?

  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: self,
    userDriverDelegate: nil
  )
  private var observations: [NSKeyValueObservation] = []
  private var lifecycleStatus: UpdateStatus = .idle

  override init() {
    super.init()
    let updater = controller.updater
    observations = [
      updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.stateDidChange?() }
      },
      updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.stateDidChange?() }
      },
      updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.stateDidChange?() }
      },
      updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.stateDidChange?() }
      },
    ]
  }

  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  var automaticallyDownloadsUpdates: Bool {
    get { controller.updater.automaticallyDownloadsUpdates }
    set { controller.updater.automaticallyDownloadsUpdates = newValue }
  }

  var canCheckForUpdates: Bool {
    controller.updater.canCheckForUpdates
  }

  var lastUpdateCheckDate: Date? {
    controller.updater.lastUpdateCheckDate
  }

  func checkForUpdates() {
    publish(.checking)
    controller.updater.checkForUpdates()
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    publish(.available(version: item.displayVersionString))
  }

  func updater(
    _ updater: SPUUpdater,
    willDownloadUpdate item: SUAppcastItem,
    with request: NSMutableURLRequest
  ) {
    publish(.downloading(version: item.displayVersionString))
  }

  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    publish(.downloaded(version: item.displayVersionString))
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    publish(.installing(version: item.displayVersionString))
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    publishNoUpdateStatus(error as NSError)
  }

  func updater(
    _ updater: SPUUpdater,
    failedToDownloadUpdate item: SUAppcastItem,
    error: Error
  ) {
    publish(.failed(message: error.localizedDescription))
  }

  func userDidCancelDownload(_ updater: SPUUpdater) {
    publish(.idle)
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    publishCycleError(error as NSError)
  }

  func updater(
    _ updater: SPUUpdater,
    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: Error?
  ) {
    if let error {
      publishCycleError(error as NSError)
    } else {
      switch lifecycleStatus {
      case .checking, .available, .downloading:
        publish(.idle)
      case .idle, .downloaded, .installing, .current, .failed:
        break
      }
      stateDidChange?()
    }
  }

  private func publishCycleError(_ error: NSError) {
    publish(SparkleUpdateStatusResolver.cycleErrorStatus(error))
  }

  private func publishNoUpdateStatus(_ error: NSError) {
    publish(SparkleUpdateStatusResolver.noUpdateStatus(error))
  }

  private func publish(_ status: UpdateStatus) {
    lifecycleStatus = status
    statusDidChange?(status)
  }
}
