import AppKit
import Foundation

@MainActor
protocol AppRelaunching: AnyObject {
  func relaunch(
    bundleURL: URL,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  )
}

enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: return L10n.string("System Default")
    case .english: return L10n.string("English")
    case .simplifiedChinese: return L10n.string("Simplified Chinese")
    }
  }

  func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
    switch self {
    case .english:
      return "en"
    case .simplifiedChinese:
      return "zh-Hans"
    case .system:
      for identifier in preferredLanguages {
        let normalized = identifier.lowercased()
        if normalized.hasPrefix("zh") { return "zh-Hans" }
        if normalized.hasPrefix("en") { return "en" }
      }
      return "en"
    }
  }
}

@MainActor
final class AppLanguageService: ObservableObject {
  static let selectionKey = "appLanguageSelection"
  private static let appleLanguagesKey = "AppleLanguages"

  @Published private(set) var selectedLanguage: AppLanguage
  @Published private(set) var isRelaunching = false
  @Published private(set) var errorMessage: String?

  private let defaults: UserDefaults
  private let relauncher: AppRelaunching
  private let bundleURL: URL
  private let persistentDomainName: String
  private let terminator: @MainActor () -> Void

  init(
    defaults: UserDefaults = .standard,
    relauncher: AppRelaunching? = nil,
    bundleURL: URL = Bundle.main.bundleURL,
    persistentDomainName: String = Bundle.main.bundleIdentifier ?? "com.touchmacer.clock",
    terminator: @escaping @MainActor () -> Void = {
      NSApplication.shared.terminate(nil)
    }
  ) {
    self.defaults = defaults
    self.relauncher = relauncher ?? WorkspaceAppRelauncher()
    self.bundleURL = bundleURL
    self.persistentDomainName = persistentDomainName
    self.terminator = terminator

    let persistentDomain = defaults.persistentDomain(forName: persistentDomainName) ?? [:]
    if let stored = persistentDomain[Self.selectionKey] as? String,
      let language = AppLanguage(rawValue: stored)
    {
      self.selectedLanguage = language
    } else if let override = Self.language(
      from: persistentDomain[Self.appleLanguagesKey] as? [String]
    ) {
      self.selectedLanguage = override
      defaults.set(override.rawValue, forKey: Self.selectionKey)
    } else {
      self.selectedLanguage = .system
      defaults.set(AppLanguage.system.rawValue, forKey: Self.selectionKey)
    }
  }

  func apply(_ language: AppLanguage) {
    guard language != selectedLanguage, !isRelaunching else { return }

    let previousLanguage = selectedLanguage
    let previousDomain = defaults.persistentDomain(forName: persistentDomainName) ?? [:]
    let previousSelection = previousDomain[Self.selectionKey]
    let previousOverride = previousDomain[Self.appleLanguagesKey]
    errorMessage = nil
    isRelaunching = true
    persist(language)
    selectedLanguage = language

    relauncher.relaunch(bundleURL: bundleURL) { [weak self] result in
      guard let self else { return }
      self.isRelaunching = false
      switch result {
      case .success:
        self.terminator()
      case .failure(let error):
        self.restore(previousSelection, forKey: Self.selectionKey)
        self.restore(previousOverride, forKey: Self.appleLanguagesKey)
        self.selectedLanguage = previousLanguage
        self.errorMessage = L10n.format(
          "TouchMacer could not relaunch: %@",
          error.localizedDescription
        )
      }
    }
  }

  private static func language(from override: [String]?) -> AppLanguage? {
    for identifier in override ?? [] {
      let normalized = identifier.lowercased()
      if normalized.hasPrefix("zh") { return .simplifiedChinese }
      if normalized.hasPrefix("en") { return .english }
    }
    return nil
  }

  private func restore(_ value: Any?, forKey key: String) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  private func persist(_ language: AppLanguage) {
    defaults.set(language.rawValue, forKey: Self.selectionKey)
    switch language {
    case .system:
      defaults.removeObject(forKey: Self.appleLanguagesKey)
    case .english, .simplifiedChinese:
      defaults.set([language.rawValue], forKey: Self.appleLanguagesKey)
    }
  }
}

@MainActor
private final class WorkspaceAppRelauncher: AppRelaunching {
  func relaunch(
    bundleURL: URL,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
      Task { @MainActor in
        if let error {
          completion(.failure(error))
        } else {
          completion(.success(()))
        }
      }
    }
  }
}
