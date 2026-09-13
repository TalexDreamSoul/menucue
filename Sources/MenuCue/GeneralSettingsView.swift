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
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      startupCard
      updatesCard
      appearanceCard
      LanguageSettingsView(languageService: languageService)

      if syncService.isEntitled {
        PreferenceSyncSettingsView(model: model)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      model.refreshLaunchAtLoginState()
    }
  }

  // MARK: - Startup

  private var startupCard: some View {
    SettingsCard(L10n.string("Startup")) {
      SettingsRows {
        SettingsRowToggle(
          L10n.string("Launch MenuCue at login"),
          isOn: launchAtLoginBinding
        )
        .disabled(model.launchAtLoginState == .unavailable)

        SettingsRow(L10n.string("Status"), desc: launchAtLoginStatusMessage) {
          SettingsChip(
            launchAtLoginChipLabel,
            systemImage: launchAtLoginChipSymbol,
            tint: launchAtLoginChipTint
          )
        }

        if model.launchAtLoginState == .requiresApproval {
          SettingsRowButton(
            L10n.string("Needs Approval"),
            buttonTitle: L10n.string("Open Login Items Settings"),
            kind: .secondary
          ) {
            model.openLoginItemsSettings()
          }
        }
      }

      if let errorMessage = model.launchAtLoginErrorMessage, !errorMessage.isEmpty {
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

  private var launchAtLoginStatusMessage: String {
    switch model.launchAtLoginState {
    case .disabled:
      return L10n.string("MenuCue starts only when you open it.")
    case .enabled:
      return L10n.string("MenuCue will start automatically after you sign in.")
    case .requiresApproval:
      return L10n.string("macOS requires approval before MenuCue can start at login.")
    case .unavailable:
      return L10n.string("Launch at Login is available when MenuCue runs from its app bundle.")
    }
  }

  private var launchAtLoginChipLabel: String {
    switch model.launchAtLoginState {
    case .disabled:
      return L10n.string("Off")
    case .enabled:
      return L10n.string("Enabled")
    case .requiresApproval:
      return L10n.string("Needs Approval")
    case .unavailable:
      return L10n.string("Unavailable")
    }
  }

  private var launchAtLoginChipSymbol: String {
    switch model.launchAtLoginState {
    case .disabled:
      return "circle"
    case .enabled:
      return "checkmark.circle.fill"
    case .requiresApproval:
      return "exclamationmark.triangle.fill"
    case .unavailable:
      return "slash.circle"
    }
  }

  private var launchAtLoginChipTint: Color {
    switch model.launchAtLoginState {
    case .enabled:
      return .green
    case .requiresApproval:
      return .orange
    case .disabled, .unavailable:
      return .secondary
    }
  }

  // MARK: - Updates

  private var updatesCard: some View {
    SettingsCard(L10n.string("Updates")) {
      SettingsRows {
        SettingsRowToggle(
          L10n.string("Automatically check and download updates"),
          isOn: automaticUpdatesBinding
        )

        SettingsRow(L10n.string("Status"), desc: updateStatusMessage) {
          SettingsChip(
            updateStatusChipLabel,
            systemImage: updateStatusChipSymbol,
            tint: updateStatusChipTint
          )
        }

        if let lastCheckText {
          SettingsRowValue(L10n.string("Last Checked"), value: lastCheckText)
        }

        SettingsRowButton(
          L10n.string("Manual Check"),
          buttonTitle: L10n.string("Check for Updates"),
          kind: .primary
        ) {
          updateService.checkForUpdates()
        }
        .disabled(!updateService.canCheckForUpdates)
      }
    }
  }

  private var updateStatusChipLabel: String {
    switch updateService.status {
    case .idle:
      return updateService.automaticUpdatesEnabled
        ? L10n.string("Automatic")
        : L10n.string("Off")
    case .checking:
      return L10n.string("Checking")
    case .available:
      return L10n.string("Update Available")
    case .downloading:
      return L10n.string("Downloading")
    case .downloaded:
      return L10n.string("Ready to Install")
    case .installing:
      return L10n.string("Installing")
    case .current:
      return L10n.string("Up to Date")
    case .failed:
      return L10n.string("Failed")
    }
  }

  private var updateStatusChipSymbol: String {
    switch updateService.status {
    case .idle:
      return updateService.automaticUpdatesEnabled
        ? "arrow.triangle.2.circlepath"
        : "pause.circle"
    case .checking:
      return "arrow.triangle.2.circlepath"
    case .available:
      return "arrow.down.circle"
    case .downloading, .installing:
      return "arrow.down.circle"
    case .downloaded:
      return "checkmark.circle"
    case .current:
      return "checkmark.circle.fill"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  private var updateStatusChipTint: Color {
    switch updateService.status {
    case .current:
      return .green
    case .failed:
      return .red
    case .available, .downloaded:
      return .orange
    case .idle, .checking, .downloading, .installing:
      return .secondary
    }
  }

  // MARK: - Appearance

  private var appearanceCard: some View {
    SettingsCard(L10n.string("Appearance")) {
      SettingsRows {
        SettingsRowSelect(
          L10n.string("Appearance"),
          selection: model.settingsBinding(\.appearanceMode),
          options: AppearanceMode.allCases.map { (value: $0, label: $0.title) }
        )

        if model.settings.appearanceMode == .automaticByTimeZone {
          SettingsRow(
            L10n.string("Auto reference"),
            desc: L10n.string(
              "Auto uses light from 07:00-19:00 in the selected time zone."
            ),
            controlWidth: 240
          ) {
            TimeZonePicker(
              title: "",
              selection: model.settingsBinding(\.appearanceTimeZoneID)
            )
            .labelsHidden()
          }
        }

        SettingsRowToggle(
          L10n.string("Apply to macOS system appearance"),
          desc: L10n.string(
            "When enabled, MenuCue switches the system Light/Dark appearance via macOS Automation permissions. When disabled, only this app previews the selected appearance."
          ),
          isOn: model.settingsBinding(\.appliesSystemAppearance)
        )

        SettingsRowSegmented(
          L10n.string("Animation effects"),
          selection: animationQualityIndex,
          options: AnimationQuality.allCases.map(\.title)
        )

        SettingsRow(
          L10n.string("What Elegant Means"),
          desc: L10n.string("Keeps the main value transitions and lowers the cost of continuous frames; treated as Minimal whenever the system Reduce Motion setting is on.")
        ) {
          SettingsChip(L10n.string("Default"))
        }
      }
    }
  }

  /// `SettingsRowSegmented` works in indices while the setting is an enum, so the bridge
  /// reads the current case and writes the case the index names.
  private var animationQualityIndex: Binding<Int> {
    let quality = model.settingsBinding(\.animationQuality)
    return Binding(
      get: { AnimationQuality.allCases.firstIndex(of: quality.wrappedValue) ?? 1 },
      set: { index in
        guard AnimationQuality.allCases.indices.contains(index) else { return }
        quality.wrappedValue = AnimationQuality.allCases[index]
      }
    )
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
    SettingsCard(L10n.string("iCloud Sync")) {
      SettingsRows {
        SettingsRow(service.status.title, desc: service.status.message) {
          HStack(spacing: 8) {
            Image(systemName: statusSymbol)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(statusColor)
            syncStatusAction
          }
        }

        if showsSyncToggle {
          SettingsRowToggle(
            L10n.string("Sync portable preferences with iCloud"),
            isOn: syncEnabledBinding
          )
        }

        SettingsRow(
          L10n.string("Synced between Macs"),
          desc: L10n.string(
            "Menu-bar format, clock order and labels, rotation interval, overview time zone, week start, and app appearance."
          )
        ) {
          SettingsChip(L10n.string("Portable"))
        }

        SettingsRow(
          L10n.string("Kept on this Mac"),
          desc: L10n.string(
            "Calendar access and selection, system appearance control, Quick Actions, sync choices, and temporary UI state."
          )
        ) {
          SettingsChip(L10n.string("Local Only"))
        }
      }
    }
  }

  /// The action belongs to the status row: setup and source decisions are answers to
  /// the state above them, and a retry only makes sense once a first attempt failed.
  /// Rows keep the same conditions they had before the redesign, so no state shows a
  /// control it did not show already.
  @ViewBuilder
  private var syncStatusAction: some View {
    switch service.status {
    case .needsOnboarding:
      HStack(spacing: 8) {
        Button(L10n.string("Enable iCloud Sync")) {
          model.completePreferenceSyncOnboarding(enable: true)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        Button(L10n.string("Keep Settings on This Mac")) {
          model.completePreferenceSyncOnboarding(enable: false)
        }
        .controlSize(.small)
      }
    case .needsSourceDecision:
      HStack(spacing: 8) {
        Button(L10n.string("Use iCloud Settings")) {
          model.chooseCloudPreferenceSettings()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        Button(L10n.string("Use This Mac's Settings")) {
          model.chooseLocalPreferenceSettings()
        }
        .controlSize(.small)
      }
    default:
      if case .failed = service.status {
        Button(L10n.string("Retry Sync")) { model.retryPreferenceSync() }
          .controlSize(.small)
      } else if service.status == .signedOut {
        Button(L10n.string("Retry After Signing In")) { model.retryPreferenceSync() }
          .controlSize(.small)
      }
    }
  }

  private var showsSyncToggle: Bool {
    switch service.status {
    case .needsOnboarding, .needsSourceDecision:
      return false
    default:
      return true
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
