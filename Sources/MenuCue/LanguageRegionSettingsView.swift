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
    appLanguageCard
  }

  private var appLanguageCard: some View {
    SettingsCard(L10n.string("MenuCue Language")) {
      SettingsRows {
        SettingsRowSegmented(
          L10n.string("MenuCue Language"),
          selection: languageSelection,
          options: AppLanguage.allCases.map(\.displayName)
        )

        SettingsRow(
          L10n.string("Relaunch"),
          desc: L10n.string(
            "Changing the app language relaunches MenuCue. It does not change the macOS language."
          )
        ) {
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
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(
            pendingLanguage == languageService.selectedLanguage || languageService.isRelaunching
          )
        }
      }

      if let errorMessage = languageService.errorMessage {
        SettingsBanner(
          errorMessage,
          systemImage: "exclamationmark.triangle.fill",
          tint: .red
        )
        .padding(.horizontal, SettingsMetrics.rowPaddingH)
        .padding(.top, 10)
        .padding(.bottom, 12)
      }
    }
  }

  /// `SettingsRowSegmented` speaks in indices, while the pending selection is a real
  /// `AppLanguage`. The mapping keeps `pendingLanguage` as the single source of truth.
  private var languageSelection: Binding<Int> {
    Binding(
      get: { AppLanguage.allCases.firstIndex(of: pendingLanguage) ?? 0 },
      set: { index in
        guard AppLanguage.allCases.indices.contains(index) else { return }
        pendingLanguage = AppLanguage.allCases[index]
      }
    )
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

  /// Card body for the Time & Region pane: that pane's card owns the title and the
  /// explanation, so this view starts at the current value.
  private var systemTimeZoneSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRows {
        SettingsRow(L10n.string("Current System Time Zone")) {
          HStack(spacing: 10) {
            SettingsChip(timeZoneSelection.observedIdentifier)
            Button {
              refreshSystemTimeZone()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh system time zone")
            .disabled(powerHelper.isWorking)
          }
        }
      }

      VStack(alignment: .leading, spacing: 10) {
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
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(timeZoneAction == .disabled)

          if powerHelper.isWorking {
            MotionAwareProgressIndicator()
          }
          SettingsChip(helperStatusText, tint: .secondary)
        }

        if let feedbackMessage {
          Text(feedbackMessage)
            .font(.caption)
            .foregroundStyle(feedbackIsError ? Color.red : Color.green)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, SettingsMetrics.rowPaddingH)
      .padding(.vertical, SettingsMetrics.rowPaddingV)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.settingsCardSurface)
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
