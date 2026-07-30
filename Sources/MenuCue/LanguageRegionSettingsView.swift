import AppKit
import Combine
import Foundation
import SwiftUI
import MenuCueHelperProtocol

struct SystemTimeZoneOption: Identifiable, Equatable {
  let id: String
  let displayName: String
}

enum SystemTimeZoneCatalog {
  static func options(
    matching query: String,
    locale: Locale = .current,
    identifiers: [String] = TimeZone.knownTimeZoneIdentifiers
  ) -> [SystemTimeZoneOption] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return identifiers.compactMap { identifier in
      guard let timeZone = TimeZone(identifier: identifier) else { return nil }
      let displayName = timeZone.localizedName(for: .generic, locale: locale)
        ?? identifier.replacingOccurrences(of: "_", with: " ")
      if !normalizedQuery.isEmpty {
        let searchableIdentifier = identifier.replacingOccurrences(of: "_", with: " ")
        guard searchableIdentifier.localizedCaseInsensitiveContains(normalizedQuery)
          || displayName.localizedCaseInsensitiveContains(normalizedQuery)
        else {
          return nil
        }
      }
      return SystemTimeZoneOption(id: identifier, displayName: displayName)
    }
    .sorted {
      let comparison = $0.displayName.localizedStandardCompare($1.displayName)
      return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
  }
}

enum SystemTimeZoneApplyAction: Equatable {
  case disabled
  case installHelper
  case openHelperSettings
  case refreshHelper
  case apply
}

enum SystemTimeZoneApplyPolicy {
  static func action(
    registrationState: PowerHelperRegistrationState,
    supportsSystemTimeZone: Bool,
    targetIdentifier: String,
    currentIdentifier: String,
    isWorking: Bool
  ) -> SystemTimeZoneApplyAction {
    guard !isWorking,
      targetIdentifier != currentIdentifier,
      SystemTimeZoneCommand.arguments(for: targetIdentifier) != nil
    else {
      return .disabled
    }

    switch registrationState {
    case .enabled:
      return supportsSystemTimeZone ? .apply : .refreshHelper
    case .notRegistered, .failed:
      return .installHelper
    case .requiresApproval:
      return .openHelperSettings
    case .refreshRequired:
      return .refreshHelper
    case .unavailable:
      return .disabled
    }
  }
}

struct SystemTimeZoneSelectionState: Equatable {
  private(set) var observedIdentifier: String
  private(set) var targetIdentifier: String
  private(set) var hasUserEditedTarget = false

  init(currentIdentifier: String) {
    observedIdentifier = currentIdentifier
    targetIdentifier = currentIdentifier
  }

  mutating func observe(_ identifier: String) {
    observedIdentifier = identifier
    if !hasUserEditedTarget {
      targetIdentifier = identifier
    }
  }

  mutating func select(_ identifier: String) {
    targetIdentifier = identifier
    hasUserEditedTarget = true
  }

  mutating func completeApply(
    observedIdentifier: String,
    requestedIdentifier: String
  ) {
    self.observedIdentifier = observedIdentifier
    guard targetIdentifier == requestedIdentifier else { return }
    targetIdentifier = observedIdentifier
    hasUserEditedTarget = false
  }
}

enum LanguageRegionLinks {
  static let systemLanguageSettings = URL(
    string: "x-apple.systempreferences:com.apple.Localization-Settings.extension"
  )!
}

struct LanguageSettingsView: View {
  @ObservedObject var languageService: AppLanguageService

  @State private var pendingLanguage: AppLanguage

  init(languageService: AppLanguageService) {
    self.languageService = languageService
    self._pendingLanguage = State(initialValue: languageService.selectedLanguage)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      appLanguageSection
      Divider()
      globalLanguageSection
    }
  }

  private var appLanguageSection: some View {
    SettingsGroup(spacing: 12) {
      Text("MenuCue Language")
        .font(.headline)

      Picker("MenuCue Language", selection: $pendingLanguage) {
        ForEach(AppLanguage.allCases) { language in
          Text(language.displayName).tag(language)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(maxWidth: 460)

      Text("Changing the app language relaunches MenuCue. It does not change the macOS language.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button {
        languageService.apply(pendingLanguage)
      } label: {
        Label(
          L10n.string(
            languageService.isRelaunching ? "Relaunching..." : "Apply and Relaunch"
          ),
          systemImage: "arrow.clockwise"
        )
      }
      .disabled(
        pendingLanguage == languageService.selectedLanguage || languageService.isRelaunching
      )

      if let errorMessage = languageService.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var globalLanguageSection: some View {
    SettingsGroup(spacing: 10) {
      Text("macOS Language")
        .font(.headline)
      Text("Global language changes are managed by macOS and may require signing out.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button {
        NSWorkspace.shared.open(LanguageRegionLinks.systemLanguageSettings)
      } label: {
        Label("Open Language & Region Settings", systemImage: "gearshape")
      }
    }
  }
}

struct SystemTimeZoneSettingsView: View {
  @ObservedObject var powerHelper: PowerHelperManager

  @State private var timeZoneSearch = ""
  @State private var timeZoneSelection = SystemTimeZoneSelectionState(
    currentIdentifier: TimeZone.autoupdatingCurrent.identifier
  )
  @State private var feedbackMessage: String?
  @State private var feedbackIsError = false

  var body: some View {
    systemTimeZoneSection
      .onAppear(perform: refreshSystemTimeZone)
      .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
        refreshSystemTimeZone()
      }
      .onChange(of: powerHelper.systemTimeZoneIdentifier) { identifier in
        guard let identifier else { return }
        timeZoneSelection.observe(identifier)
      }
  }

  private var systemTimeZoneSection: some View {
    SettingsGroup(spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("macOS System Time Zone")
            .font(.headline)
          Text("Changes the time zone for all apps and system services on this Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(timeZoneSelection.observedIdentifier)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          refreshSystemTimeZone()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh system time zone")
        .disabled(powerHelper.isWorking)
      }

      TextField("Search time zones", text: $timeZoneSearch)
        .textFieldStyle(.roundedBorder)

      List(filteredTimeZones, selection: timeZoneSelectionBinding) { option in
        VStack(alignment: .leading, spacing: 2) {
          Text(option.displayName)
          Text(option.id)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .tag(option.id)
      }
      .frame(height: 210)
      .disabled(powerHelper.isWorking)

      HStack(spacing: 10) {
        Button(timeZoneActionTitle, action: performTimeZoneAction)
          .disabled(timeZoneAction == .disabled)

        if powerHelper.isWorking {
          ProgressView()
            .controlSize(.small)
        }
      }

      Text(helperStatusText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let feedbackMessage {
        Text(feedbackMessage)
          .font(.caption)
          .foregroundStyle(feedbackIsError ? Color.red : Color.green)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var filteredTimeZones: [SystemTimeZoneOption] {
    SystemTimeZoneCatalog.options(matching: timeZoneSearch)
  }

  private var timeZoneAction: SystemTimeZoneApplyAction {
    SystemTimeZoneApplyPolicy.action(
      registrationState: powerHelper.registrationState,
      supportsSystemTimeZone: powerHelper.supportsSystemTimeZone,
      targetIdentifier: timeZoneSelection.targetIdentifier,
      currentIdentifier: timeZoneSelection.observedIdentifier,
      isWorking: powerHelper.isWorking
    )
  }

  private var timeZoneActionTitle: String {
    switch timeZoneAction {
    case .disabled, .apply: return L10n.string("Apply Time Zone")
    case .installHelper: return L10n.string("Install Helper")
    case .openHelperSettings: return L10n.string("Open System Settings")
    case .refreshHelper: return L10n.string("Refresh Helper")
    }
  }

  private var helperStatusText: String {
    powerHelper.registrationState.detail
  }

  private func performTimeZoneAction() {
    feedbackMessage = nil
    switch timeZoneAction {
    case .disabled:
      return
    case .installHelper:
      powerHelper.requestRegistration()
    case .openHelperSettings:
      powerHelper.openSystemSettings()
    case .refreshHelper:
      powerHelper.refreshHelperRegistration()
    case .apply:
      let requestedIdentifier = timeZoneSelection.targetIdentifier
      powerHelper.setSystemTimeZone(requestedIdentifier) { result in
        switch result {
        case .success(let observedIdentifier):
          timeZoneSelection.completeApply(
            observedIdentifier: observedIdentifier,
            requestedIdentifier: requestedIdentifier
          )
          feedbackIsError = false
          feedbackMessage = L10n.format(
            "System time zone changed to %@.",
            observedIdentifier
          )
        case .failure(let error):
          feedbackIsError = true
          feedbackMessage = L10n.format(
            "Could not change the system time zone: %@",
            error.localizedDescription
          )
        }
      }
    }
  }

  private var timeZoneSelectionBinding: Binding<String?> {
    Binding(
      get: { timeZoneSelection.targetIdentifier },
      set: { identifier in
        guard let identifier else { return }
        timeZoneSelection.select(identifier)
      }
    )
  }

  private func refreshSystemTimeZone() {
    timeZoneSelection.observe(TimeZone.autoupdatingCurrent.identifier)
    powerHelper.refreshStatus()
    if powerHelper.registrationState.isEnabled, powerHelper.supportsSystemTimeZone {
      powerHelper.querySystemTimeZone { result in
        if case .success(let identifier) = result {
          timeZoneSelection.observe(identifier)
        }
      }
    }
  }
}
