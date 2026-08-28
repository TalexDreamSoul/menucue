import AppKit
import Foundation

/// The one place that compiles and runs an AppleScript. Both action surfaces route here
/// so a script that fails reports the same reason wherever it was triggered from.
enum AppleScriptRunner {
  enum Failure: Error, Equatable {
    case emptySource
    case compilationFailed
    /// macOS refused the script. The message is the one AppleScript reported, or the
    /// generic automation denial when it reported nothing usable.
    case executionFailed(String)

    var message: String {
      switch self {
      case .emptySource:
        return L10n.string("The AppleScript is empty.")
      case .compilationFailed:
        return L10n.string("macOS could not compile the AppleScript.")
      case .executionFailed(let message):
        return message
      }
    }

    /// Whether the user could plausibly fix this from System Settings; a malformed script
    /// cannot be fixed there.
    var isPermissionRelated: Bool {
      if case .executionFailed = self { return true }
      return false
    }
  }

  static func run(_ source: String) -> Result<Void, Failure> {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(.emptySource)
    }
    guard let script = NSAppleScript(source: source) else {
      return .failure(.compilationFailed)
    }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    guard let error else { return .success(()) }
    let message = error[NSAppleScript.errorMessage] as? String
      ?? L10n.string("macOS denied the requested Automation action.")
    return .failure(.executionFailed(message))
  }
}

/// The one place that hands a URL, an application, or a file to the workspace. It reports
/// what was opened so the caller can name it in feedback.
enum WorkspaceOpener {
  enum Failure: Error, Equatable {
    case invalidURL
    case applicationNotInstalled
    case openFailed(name: String)
    case missingApplication
    case missingItem
    case missingFile
    case missingFolder

    var message: String {
      switch self {
      case .invalidURL:
        return L10n.string("The selected URL is invalid.")
      case .applicationNotInstalled:
        return L10n.string("The selected application is not installed.")
      case .openFailed(let name):
        return L10n.format("macOS could not open %@.", name)
      case .missingApplication:
        return L10n.string("macOS could not open the selected application.")
      case .missingItem:
        return L10n.string("The selected file or folder no longer exists.")
      case .missingFile:
        return L10n.string("The selected file no longer exists.")
      case .missingFolder:
        return L10n.string("The selected folder no longer exists.")
      }
    }
  }

  /// The name to put in "Opened %@." — a file keeps its last path component, a web URL
  /// keeps the whole address because its last component means nothing on its own.
  static func displayName(for url: URL) -> String {
    url.path.isEmpty ? url.absoluteString : url.lastPathComponent
  }

  @discardableResult
  static func open(_ url: URL) -> Result<String, Failure> {
    guard NSWorkspace.shared.open(url) else {
      return .failure(.openFailed(name: url.path.isEmpty ? url.absoluteString : url.path))
    }
    return .success(displayName(for: url))
  }

  static func open(urlString: String) -> Result<String, Failure> {
    guard let url = URL(string: urlString), url.scheme != nil else {
      return .failure(.invalidURL)
    }
    return open(url)
  }

  static func openApplication(bundleIdentifier: String) -> Result<String, Failure> {
    guard let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: bundleIdentifier
    ) else {
      return .failure(.applicationNotInstalled)
    }
    guard NSWorkspace.shared.open(applicationURL) else {
      return .failure(.missingApplication)
    }
    return .success(applicationURL.deletingPathExtension().lastPathComponent)
  }

  /// `requiresDirectory` nil accepts either kind; otherwise a file offered where a folder
  /// was configured is reported as missing rather than silently opened.
  static func openFileSystemItem(
    path: String,
    requiresDirectory: Bool?
  ) -> Result<String, Failure> {
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return .failure(.missingItem)
    }
    if let requiresDirectory, requiresDirectory != isDirectory.boolValue {
      return .failure(requiresDirectory ? .missingFolder : .missingFile)
    }
    return open(url)
  }

  /// A System Settings deep link. Nothing useful can be reported when it fails, and every
  /// caller is already showing the reason the user is being sent there.
  static func openSettings(_ url: URL) {
    _ = NSWorkspace.shared.open(url)
  }

  /// The launch path that needs the workspace's own error, so the caller can report why a
  /// bundle it located on disk still refused to start.
  static func openApplication(at url: URL, completion: @escaping (Error?) -> Void) {
    NSWorkspace.shared.openApplication(
      at: url,
      configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      completion(error)
    }
  }
}
