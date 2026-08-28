import MenuCueHelperProtocol
import SwiftUI

/// Power settings for this Mac: what MenuCue watches in the background, the system
/// power settings it writes through the helper, and the helper itself.
struct PowerSettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService
  @ObservedObject private var powerHelper: PowerHelperManager
  @ObservedObject private var diagnostics: PowerDiagnosticsService
  @State private var helperFeedback: String?
  @State private var selectedSource: ManagedPowerSource = .ac
  @State private var pendingAllSources: PendingPowerSetting?
  @State private var profileFeedback: String?
  @State private var isConfirmingClear = false

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
    self.powerHelper = model.quickActionService.powerHelperManager
    self.diagnostics = model.powerDiagnosticsService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      monitoringSection
      wakeHistorySection
      powerProfilesSection
      powerHelperSection(isProminent: powerHelper.registrationState.needsProminentRemediation)
    }
    .onAppear {
      service.refreshAll()
      if let onAC = diagnostics.battery?.isOnAC {
        selectedSource = onAC ? .ac : .battery
      }
      // Reading the profiles is what `retain` is for here; the pane shows what pmset
      // currently reports rather than whatever was last cached.
      diagnostics.retain()
    }
    .onDisappear {
      diagnostics.release()
    }
    .onChange(of: diagnostics.battery?.isOnAC) { onAC in
      guard let onAC else { return }
      selectedSource = onAC ? .ac : .battery
    }
  }

  // MARK: - Background monitoring

  /// The switch that used to not exist.
  ///
  /// Both power surfaces turned this on from `onAppear`, so looking at power once
  /// silently signed the Mac up for a `pmset -g log` after every wake and a `top` run
  /// every few minutes, with nothing anywhere to turn it back off.
  private var monitoringSection: some View {
    SettingsGroup(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string("Power Monitoring"))
          .font(.headline)
        Text(
          L10n.string(
            "Wake history and \"what keeps running\" are built from samples taken while nothing is on screen."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Toggle(
        "Track wakes and running processes in the background",
        isOn: Binding(
          get: { model.settings.powerMonitoringEnabled },
          set: { model.setPowerMonitoring(enabled: $0) }
        )
      )

      Text(
        L10n.string(
          "Off by default. When on, the system power log is read after each wake and running processes are sampled every few minutes; when off, both surfaces only cover the time they are open."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Wake history

  /// What the wake log costs, and the two ways to act on it.
  ///
  /// Clearing used to live in the popover and undoing it on the Dashboard, so the
  /// button that hid 30 days of records and the button that brought them back were in
  /// different windows. They are one pair, and they belong together.
  private var wakeHistorySection: some View {
    SettingsGroup(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string("Wake History"))
          .font(.headline)
        Text(
          L10n.format(
            "Sleep and wake events from the last 30 days, kept on this Mac · %@",
            SystemMetricsFormatter.capacity(diagnostics.historyFileSizeBytes))
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      if let clearedAt = diagnostics.clearedAt, diagnostics.hiddenEventCount > 0 {
        ClearedHistoryNote(
          clearedAt: clearedAt,
          hiddenCount: diagnostics.hiddenEventCount,
          restore: { diagnostics.restoreHistory() })
      }

      HStack {
        Spacer()
        Button(L10n.string("Clear History"), role: .destructive) {
          isConfirmingClear = true
        }
        .disabled(diagnostics.snapshot.events.isEmpty)
      }
    }
    .alert(isPresented: $isConfirmingClear) {
      Alert(
        title: Text(L10n.string("Clear local history?")),
        message: Text(L10n.string("This removes sleep and wake history stored on this Mac.")),
        primaryButton: .destructive(Text(L10n.string("Clear History"))) {
          diagnostics.clearHistory()
        },
        secondaryButton: .cancel())
    }
  }

  // MARK: - System power profiles

  /// The `pmset` switches, which the popover used to own.
  ///
  /// They are system settings — they outlive the app and apply to every process on the
  /// Mac — so they belong where system settings are, not in a 360pt readout that is
  /// dismissed on the next click outside it.
  private var powerProfilesSection: some View {
    SettingsGroup(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string("Power Profiles"))
          .font(.headline)
        Text(
          L10n.string(
            "These are macOS power settings. MenuCue writes them with pmset through the Power Helper, and they stay in effect for the whole Mac."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Picker(L10n.string("Power source"), selection: $selectedSource) {
        Text(L10n.string("Battery")).tag(ManagedPowerSource.battery)
        Text(L10n.string("AC")).tag(ManagedPowerSource.ac)
        Text(L10n.string("All")).tag(ManagedPowerSource.all)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 260)

      if let profile = displayedProfile {
        profileToggle("Power Nap", setting: .powerNap, value: profile.powerNap)
        profileToggle(
          "Wake for network access", setting: .wakeOnNetwork, value: profile.wakeOnNetwork)
        profileToggle("Standby", setting: .standby, value: profile.standby)
        profileToggle("TCP Keepalive", setting: .tcpKeepalive, value: profile.tcpKeepalive)
        HStack {
          Text(L10n.string("Power mode"))
          Spacer()
          Text(powerModeText(profile.powerMode))
            .foregroundStyle(.secondary)
        }
      } else {
        Text(L10n.string("Power profile unavailable"))
          .font(.callout)
          .foregroundStyle(.tertiary)
      }

      if let profileFeedback {
        Text(profileFeedback)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .alert(item: $pendingAllSources) { pending in
      Alert(
        title: Text(L10n.string("Apply to Battery and AC?")),
        message: Text(L10n.string("Battery and AC currently use different values.")),
        primaryButton: .default(Text(L10n.string(pending.enabled ? "Apply On" : "Apply Off"))) {
          applyPowerSetting(pending.setting, source: .all, enabled: pending.enabled)
        },
        secondaryButton: .cancel())
    }
  }

  @ViewBuilder
  private func profileToggle(
    _ title: String, setting: ManagedPowerSetting, value: Bool?
  ) -> some View {
    HStack {
      Text(L10n.string(title))
      Spacer()
      if let value {
        Toggle(
          "",
          isOn: Binding(
            get: { value },
            set: { setPowerSetting(setting, enabled: $0) })
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(powerHelper.isWorking)
      } else if hasMixedValue(for: setting) {
        Menu {
          Button(L10n.string("Apply On")) { setPowerSetting(setting, enabled: true) }
          Button(L10n.string("Apply Off")) { setPowerSetting(setting, enabled: false) }
        } label: {
          Text(L10n.string("Mixed"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(powerHelper.isWorking)
      } else {
        Text(L10n.string("Mixed or unsupported"))
          .font(.callout)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private var displayedProfile: PowerProfile? {
    switch selectedSource {
    case .battery: return diagnostics.snapshot.profiles.battery
    case .ac: return diagnostics.snapshot.profiles.ac
    case .all:
      let profiles = [diagnostics.snapshot.profiles.battery, diagnostics.snapshot.profiles.ac]
        .compactMap { $0 }
      guard !profiles.isEmpty else { return nil }
      return PowerProfile(
        powerMode: common(profiles.map(\.powerMode)),
        powerNap: common(profiles.map(\.powerNap)),
        wakeOnNetwork: common(profiles.map(\.wakeOnNetwork)),
        standby: common(profiles.map(\.standby)),
        tcpKeepalive: common(profiles.map(\.tcpKeepalive)),
        diskSleepMinutes: common(profiles.map(\.diskSleepMinutes)),
        displaySleepMinutes: common(profiles.map(\.displaySleepMinutes)))
    }
  }

  private func setPowerSetting(_ setting: ManagedPowerSetting, enabled: Bool) {
    if selectedSource == .all, hasMixedValue(for: setting) {
      pendingAllSources = PendingPowerSetting(setting: setting, enabled: enabled)
      return
    }
    applyPowerSetting(setting, source: selectedSource, enabled: enabled)
  }

  private func applyPowerSetting(
    _ setting: ManagedPowerSetting,
    source: ManagedPowerSource,
    enabled: Bool
  ) {
    guard powerHelper.registrationState.isEnabled else {
      powerHelper.requestRegistration()
      profileFeedback = powerHelper.registrationState.detail
      return
    }
    powerHelper.setManagedPowerSetting(setting, source: source, enabled: enabled) { result in
      switch result {
      case .success:
        profileFeedback = L10n.string("Power setting updated.")
        diagnostics.refresh()
      case .failure(let error):
        profileFeedback = error.localizedDescription
      }
    }
  }

  private func hasMixedValue(for setting: ManagedPowerSetting) -> Bool {
    guard selectedSource == .all,
      let battery = settingValue(setting, in: diagnostics.snapshot.profiles.battery),
      let ac = settingValue(setting, in: diagnostics.snapshot.profiles.ac)
    else { return false }
    return battery != ac
  }

  private func settingValue(_ setting: ManagedPowerSetting, in profile: PowerProfile?) -> Bool? {
    switch setting {
    case .powerNap: return profile?.powerNap
    case .wakeOnNetwork: return profile?.wakeOnNetwork
    case .standby: return profile?.standby
    case .tcpKeepalive: return profile?.tcpKeepalive
    }
  }

  private func common<T: Equatable>(_ values: [T?]) -> T? {
    let concrete = values.compactMap { $0 }
    guard concrete.count == values.count, let first = concrete.first,
      concrete.dropFirst().allSatisfy({ $0 == first })
    else { return nil }
    return first
  }

  private func powerModeText(_ mode: PowerMode?) -> String {
    switch mode {
    case .normal: return L10n.string("Normal")
    case .low: return L10n.string("Low Power")
    case .high: return L10n.string("High Power")
    case .other(let value): return L10n.format("Mode %d", value)
    case nil: return L10n.string("Unavailable")
    }
  }

  // MARK: - Power Helper

  private func powerHelperSection(isProminent: Bool) -> some View {
    SettingsGroup(spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: powerHelper.registrationState.isEnabled
            ? "checkmark.shield.fill"
            : isProminent ? "exclamationmark.shield.fill" : "shield.lefthalf.filled"
        )
        .font(.title3)
        .foregroundStyle(powerHelper.registrationState.isEnabled ? Color.green : Color.orange)
        .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text("Power Helper")
              .font(.headline)
            Spacer()
            Text(powerHelper.registrationState.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(powerHelper.registrationState.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            "Low Power Mode applies to battery and adapter power. Don't Sleep When Closed can increase heat and battery use."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let helperFeedback {
        Text(helperFeedback)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .transition(motion.revealTransition(edge: .top))
      }

      HStack {
        Spacer()
        helperActionButton
      }
    }
    .padding(isProminent ? 14 : 0)
    .background(
      isProminent ? Color.orange.opacity(0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isProminent ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1)
    }
    .animation(motion.stateAnimation, value: powerHelper.registrationState)
  }

  @ViewBuilder
  private var helperActionButton: some View {
    switch powerHelper.registrationState {
    case .enabled:
      Button("Remove Helper", role: .destructive, action: removePowerHelper)
        .disabled(powerHelper.isWorking)
    case .requiresApproval:
      Button("Open System Settings") {
        powerHelper.openSystemSettings()
      }
      .buttonStyle(.borderedProminent)
      Button("Cancel Install", role: .destructive, action: removePowerHelper)
        .disabled(powerHelper.isWorking)
    case .refreshRequired:
      Button("Refresh Helper") {
        helperFeedback = nil
        powerHelper.refreshHelperRegistration()
      }
      .buttonStyle(.borderedProminent)
      .disabled(powerHelper.isWorking)
    case .unavailable:
      Button("Install Helper") {}
        .buttonStyle(.borderedProminent)
        .disabled(true)
    case .notRegistered, .failed:
      Button("Install Helper") {
        helperFeedback = nil
        powerHelper.requestRegistration()
      }
      .buttonStyle(.borderedProminent)
      .disabled(powerHelper.isWorking)
    }
  }

  private func removePowerHelper() {
    powerHelper.removeHelper { result in
      switch result {
      case .success:
        helperFeedback = L10n.string("Power Helper removed.")
      case .failure(let error):
        helperFeedback = L10n.format(
          "Could not remove Power Helper: %@",
          error.localizedDescription
        )
      }
      service.refreshAll()
    }
  }
}

/// A write to both power sources, held until it has been confirmed. Battery and AC
/// disagreeing is the only case where one switch changes two settings at once.
private struct PendingPowerSetting: Identifiable {
  let setting: ManagedPowerSetting
  let enabled: Bool

  var id: String { "\(setting.rawValue)-\(enabled)" }
}
