import SwiftUI

/// App-wide settings that belong to no single feature: whether MenuCue runs at all
/// (login, updates), how it looks, what language it speaks, and whether its portable
/// preferences follow you to another Mac.
struct GeneralSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var updateService: UpdateService
  @ObservedObject var languageService: AppLanguageService
  @ObservedObject private var syncService: PreferenceSyncService

  init(
    model: AppModel,
    updateService: UpdateService,
    languageService: AppLanguageService
  ) {
    self.model = model
    self.updateService = updateService
    self.languageService = languageService
    self.syncService = model.preferenceSyncService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      startupSection
      Divider()
      updatesSection
      Divider()
      appearanceSection
      Divider()
      LanguageSettingsView(languageService: languageService)

      if syncService.isEntitled {
        Divider()
        PreferenceSyncSettingsView(model: model)
      }
    }
    .onAppear {
      model.refreshLaunchAtLoginState()
    }
  }

  // MARK: - Startup

  private var startupSection: some View {
    SettingsGroup(spacing: 8) {
      Text("Startup")
        .font(.headline)
      Toggle("Launch MenuCue at login", isOn: launchAtLoginBinding)
        .disabled(model.launchAtLoginState == .unavailable)

      switch model.launchAtLoginState {
      case .disabled:
        Text("MenuCue starts only when you open it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .enabled:
        Text("MenuCue will start automatically after you sign in.")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .requiresApproval:
        Text("macOS requires approval before MenuCue can start at login.")
          .font(.caption)
          .foregroundStyle(.orange)
        Button("Open Login Items Settings") {
          model.openLoginItemsSettings()
        }
      case .unavailable:
        Text("Launch at Login is available when MenuCue runs from its app bundle.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let errorMessage = model.launchAtLoginErrorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  // MARK: - Updates

  private var updatesSection: some View {
    SettingsGroup(spacing: 10) {
      Text("Updates")
        .font(.headline)

      Toggle(
        "Automatically check and download updates",
        isOn: automaticUpdatesBinding
      )

      Text(updateStatusMessage)
        .font(.caption)
        .foregroundStyle(updateStatusIsError ? Color.red : Color.secondary)

      if let lastCheckText {
        Text(lastCheckText)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Button("Check for Updates") {
        updateService.checkForUpdates()
      }
      .disabled(!updateService.canCheckForUpdates)
    }
  }

  // MARK: - Appearance

  private var appearanceSection: some View {
    SettingsGroup(spacing: 14) {
      Text("Appearance")
        .font(.headline)

      Picker("Appearance", selection: model.settingsBinding(\.appearanceMode)) {
        ForEach(AppearanceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .frame(maxWidth: 320)

      if model.settings.appearanceMode == .automaticByTimeZone {
        TimeZonePicker(
          title: L10n.string("Auto reference"),
          selection: model.settingsBinding(\.appearanceTimeZoneID)
        )
        .frame(maxWidth: 460)
        Text("Auto uses light from 07:00-19:00 in the selected time zone.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Toggle(
        "Apply to macOS system appearance",
        isOn: model.settingsBinding(\.appliesSystemAppearance)
      )

      Text(
        "When enabled, MenuCue switches the system Light/Dark appearance via macOS Automation permissions. When disabled, only this app previews the selected appearance."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Bindings and status text

  private var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { model.launchAtLoginState.isRegistered },
      set: { model.setLaunchAtLoginEnabled($0) }
    )
  }

  private var automaticUpdatesBinding: Binding<Bool> {
    Binding(
      get: { updateService.automaticUpdatesEnabled },
      set: { updateService.setAutomaticUpdatesEnabled($0) }
    )
  }

  private var updateStatusMessage: String {
    switch updateService.status {
    case .idle:
      return updateService.automaticUpdatesEnabled
        ? L10n.string("MenuCue checks for updates every 12 hours.")
        : L10n.string("Automatic updates are off. Manual checks remain available.")
    case .checking:
      return L10n.string("Checking for updates...")
    case .available(let version):
      return L10n.format("Version %@ is available.", version)
    case .downloading(let version):
      return L10n.format("Downloading version %@...", version)
    case .downloaded(let version):
      return L10n.format("Version %@ is downloaded and ready to install.", version)
    case .installing(let version):
      return L10n.format("Installing version %@...", version)
    case .current:
      return L10n.string("MenuCue is up to date.")
    case .failed(let message):
      return L10n.format("Update failed: %@", message)
    }
  }

  private var updateStatusIsError: Bool {
    if case .failed = updateService.status { return true }
    return false
  }

  private var lastCheckText: String? {
    updateService.lastUpdateCheckDate.map { date in
      L10n.format(
        "Last checked %@.",
        date.formatted(date: .abbreviated, time: .shortened)
      )
    }
  }
}

private struct PreferenceSyncSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: PreferenceSyncService

  init(model: AppModel) {
    self.model = model
    self._service = ObservedObject(wrappedValue: model.preferenceSyncService)
  }

  var body: some View {
    SettingsGroup(spacing: 16) {
      Text("iCloud Sync")
        .font(.headline)

      HStack(alignment: .top, spacing: 12) {
        Image(systemName: statusSymbol)
          .font(.title2)
          .foregroundStyle(statusColor)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text(service.status.title)
            .font(.headline)
          Text(service.status.message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      syncActions

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("Synced between Macs")
          .font(.subheadline.weight(.medium))
        Text(
          "Menu-bar format, clock order and labels, rotation interval, overview time zone, week start, and app appearance."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Text("Kept on this Mac")
          .font(.subheadline.weight(.medium))
          .padding(.top, 4)
        Text(
          "Calendar access and selection, system appearance control, Quick Actions, sync choices, and temporary UI state."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var syncActions: some View {
    switch service.status {
    case .needsOnboarding:
      HStack {
        Button("Enable iCloud Sync") {
          model.completePreferenceSyncOnboarding(enable: true)
        }
        .buttonStyle(.borderedProminent)
        Button("Keep Settings on This Mac") {
          model.completePreferenceSyncOnboarding(enable: false)
        }
      }
    case .needsSourceDecision:
      HStack {
        Button("Use iCloud Settings") {
          model.chooseCloudPreferenceSettings()
        }
        .buttonStyle(.borderedProminent)
        Button("Use This Mac's Settings") {
          model.chooseLocalPreferenceSettings()
        }
      }
    default:
      Toggle("Sync portable preferences with iCloud", isOn: syncEnabledBinding)
      if case .failed = service.status {
        Button("Retry Sync") { model.retryPreferenceSync() }
      } else if service.status == .signedOut {
        Button("Retry After Signing In") { model.retryPreferenceSync() }
      }
    }
  }

  private var syncEnabledBinding: Binding<Bool> {
    Binding(
      get: { model.settings.preferenceSyncEnabled },
      set: { model.setPreferenceSyncEnabled($0) }
    )
  }

  private var statusSymbol: String {
    switch service.status {
    case .synced: return "checkmark.icloud.fill"
    case .syncing: return "arrow.triangle.2.circlepath.icloud"
    case .failed, .signedOut: return "exclamationmark.icloud.fill"
    case .unavailable: return "icloud.slash"
    default: return "icloud"
    }
  }

  private var statusColor: Color {
    switch service.status {
    case .synced: return .green
    case .failed, .signedOut: return .orange
    default: return .accentColor
    }
  }
}
