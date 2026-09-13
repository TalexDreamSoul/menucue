import MenuCueHelperProtocol
import SwiftUI

/// Power settings for this Mac: what MenuCue watches in the background, the system
/// power settings it writes through the helper, and the helper itself.
struct PowerSettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService
  @ObservedObject private var powerHelper: PowerHelperManager
  @ObservedObject private var diagnostics: PowerDiagnosticsService
  /// Polling `pmset` follows the settings window, which stays alive after it closes.
  @StateObject private var diagnosticsGate = VisibilityGate()
  @State private var helperFeedback: String?
  @State private var selectedSource: ManagedPowerSource = .ac
  @State private var pendingAllSources: PendingPowerSetting?
  @State private var profileFeedback: String?
  @State private var isConfirmingClear = false
  @State private var isConfirmingHelperRemoval = false

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
    self.powerHelper = model.quickActionService.powerHelperManager
    self.diagnostics = model.powerDiagnosticsService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      monitoringSection
      powerHelperSection(isProminent: powerHelper.registrationState.needsProminentRemediation)
      powerProfilesSection
      readoutsSection
      wakeHistorySection
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      service.refreshAll()
      if let onAC = diagnostics.battery?.isOnAC {
        selectedSource = onAC ? .ac : .battery
      }
      // Reading the profiles is what `retain` is for here; the pane shows what pmset
      // currently reports rather than whatever was last cached.
      diagnosticsGate.connect(
        to: router.visibility(of: .settings),
        onStart: { diagnostics.retain() },
        onStop: { diagnostics.release() }
      )
    }
    .onDisappear {
      diagnosticsGate.disconnect()
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
    SettingsCard(
      L10n.string("Power Monitoring"),
      desc: L10n.string(
        "Only when this switch is on does MenuCue record wakes and sample processes in the background."
      )
    ) {
      SettingsRows {
        SettingsRowToggle(
          L10n.string("Track wakes and running processes in the background"),
          desc: L10n.string(
            "Off by default. When on, the system power log is read after each wake and running processes are sampled every few minutes; when off, both surfaces only cover the time they are open."
          ),
          isOn: Binding(
            get: { model.settings.powerMonitoringEnabled },
            set: { model.setPowerMonitoring(enabled: $0) }
          )
        )
        SettingsRow(
          L10n.string("Sampling Cadence"),
          desc: L10n.string(
            "Processes are sampled about every 300 seconds; at least 900 seconds in Low Power Mode."
          )
        ) {
          // The two intervals the sampler actually uses: its default and the floor it
          // raises to under Low Power Mode.
          SettingsChip(L10n.format("%ds / %ds", 300, 900))
        }
      }
    }
  }

  // MARK: - System power profiles

  /// The `pmset` switches, which the popover used to own.
  ///
  /// They are system settings — they outlive the app and apply to every process on the
  /// Mac — so they belong where system settings are, not in a 360pt readout that is
  /// dismissed on the next click outside it.
  private var powerProfilesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsCard(
        L10n.string("System Power Settings"),
        desc: L10n.string(
          "MenuCue only writes the four boolean switches the Helper supports; mixed values are confirmed first."
        )
      ) {
        SettingsRows {
          SettingsRow(L10n.string("Power source")) {
            Picker("", selection: $selectedSource) {
              Text(L10n.string("Battery")).tag(ManagedPowerSource.battery)
              Text(L10n.string("AC")).tag(ManagedPowerSource.ac)
              Text(L10n.string("All")).tag(ManagedPowerSource.all)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
          }

          if let profile = displayedProfile {
            profileToggle("Power Nap", setting: .powerNap, value: profile.powerNap)
            profileToggle(
              "Wake for network access", setting: .wakeOnNetwork, value: profile.wakeOnNetwork)
            profileToggle("Standby", setting: .standby, value: profile.standby)
            profileToggle("TCP Keepalive", setting: .tcpKeepalive, value: profile.tcpKeepalive)
            if hasAnyMixedValue {
              SettingsRow(
                L10n.string("Battery and AC differ"),
                desc: L10n.string(
                  "Under All, these change to Apply On / Apply Off and ask for confirmation first."
                )
              ) {
                SettingsChip(
                  L10n.string("Needs confirmation"),
                  systemImage: "exclamationmark.triangle",
                  tint: .orange)
              }
            }
          } else {
            SettingsRow(L10n.string("Power profile unavailable")) { EmptyView() }
          }
        }
      }

      if let profileFeedback {
        Text(profileFeedback)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, SettingsMetrics.rowPaddingH)
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
    SettingsRow(L10n.string(title)) {
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

  /// True while the "All" view is showing switches whose battery and AC values differ.
  private var hasAnyMixedValue: Bool {
    selectedSource == .all && ManagedPowerSetting.allCases.contains { hasMixedValue(for: $0) }
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

  // MARK: - Read-only readouts

  /// Values the parser already produced but nothing rendered: the current power mode and
  /// the two sleep timers. They are read-only here because the Helper writes neither of
  /// the sleep timers and pmset decides the mode.
  private var readoutsSection: some View {
    SettingsCard(
      L10n.string("Read-Only Values"),
      desc: L10n.string("Values pmset reports that MenuCue displays but does not control."),
      tone: .inset
    ) {
      SettingsRows {
        SettingsRow(
          L10n.string("Power mode"),
          desc: L10n.string("The current power mode reported by pmset.")
        ) {
          SettingsChip(
            powerModeText(displayedProfile?.powerMode ?? nil),
            tint: powerModeTint(displayedProfile?.powerMode ?? nil))
        }
        SettingsRow(
          L10n.string("Disk Sleep"),
          desc: L10n.string("Parsed from pmset custom; MenuCue has no control for it.")
        ) {
          SettingsChip(minutesText(displayedProfile?.diskSleepMinutes))
        }
        SettingsRow(
          L10n.string("Display Sleep"),
          desc: L10n.string("Parsed from pmset custom; MenuCue has no control for it.")
        ) {
          SettingsChip(minutesText(displayedProfile?.displaySleepMinutes))
        }
      }
    }
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

  private func powerModeTint(_ mode: PowerMode?) -> Color {
    guard let mode else { return .secondary }
    switch mode {
    case .normal: return .green
    case .low, .high, .other: return .secondary
    }
  }

  private func minutesText(_ minutes: Int?) -> String {
    guard let minutes else { return L10n.string("Unavailable") }
    return L10n.format("%dm", minutes)
  }

  // MARK: - Wake history

  /// What the wake log costs, the events themselves, and the two ways to act on it.
  ///
  /// Clearing used to live in the popover and undoing it on the Dashboard, so the
  /// button that hid 30 days of records and the button that brought them back were in
  /// different windows. They are one pair, and they belong together.
  private var wakeHistorySection: some View {
    SettingsCard(
      L10n.string("Wake History"),
      desc: L10n.string("Sleep and wake events from the last 30 days, kept on this Mac.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRows {
          SettingsRow(
            L10n.string("Stored History"),
            desc: L10n.format(
              "Sleep and wake events from the last 30 days, kept on this Mac · %@",
              SystemMetricsFormatter.capacity(diagnostics.historyFileSizeBytes))
          ) {
            HStack(spacing: 8) {
              SettingsChip(
                L10n.string("Asks for confirmation"),
                systemImage: "exclamationmark.triangle",
                tint: .orange)
              Button(L10n.string("Clear History"), role: .destructive) {
                isConfirmingClear = true
              }
              .disabled(diagnostics.snapshot.events.isEmpty)
            }
          }
        }

        if wakeRows.isEmpty {
          SettingsEmptyState(
            L10n.string("No wake has been recorded yet."),
            desc: L10n.string(
              "Wake events appear here once MenuCue has read the system power log."),
            systemImage: "clock.arrow.circlepath"
          )
        } else {
          SettingsTable(
            columns: [
              .init(L10n.string("Time"), weight: 160),
              .init(L10n.string("Type"), weight: 120),
              .init(L10n.string("Reason"), weight: 308),
            ]
          ) {
            ForEach(wakeRows) { event in
              SettingsTableRow {
                Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                  .font(.system(size: 12))
                  .monospacedDigit()
                  .frame(maxWidth: .infinity, alignment: .leading)
                SettingsChip(wakeKindLabel(event.kind), tint: wakeKindTint(event.kind))
                  .frame(maxWidth: .infinity, alignment: .leading)
                // The same sentence the popover and the Dashboard use, so the three
                // surfaces cannot word one wake three ways.
                Text(
                  PowerAttributionParser.sentence(
                    for: event, scheduled: diagnostics.snapshot.scheduledWakes)
                )
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }

        if let clearedAt = diagnostics.clearedAt, diagnostics.hiddenEventCount > 0 {
          SettingsRows {
            SettingsRow(
              L10n.string("Hidden Records"),
              desc: L10n.format(
                "%d earlier wakes are hidden since you cleared history on %@",
                diagnostics.hiddenEventCount,
                clearedAt.formatted(date: .abbreviated, time: .omitted))
            ) {
              HStack(spacing: 8) {
                SettingsChip(L10n.string("Recoverable"))
                Button(L10n.string("Show them")) { diagnostics.restoreHistory() }
                  .buttonStyle(.link)
              }
            }
          }
        }
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

  /// Newest first, capped: this pane is the summary, the Dashboard owns the deep list.
  private var wakeRows: [WakeEvent] {
    Array(diagnostics.snapshot.events.suffix(8).reversed())
  }

  private func wakeKindLabel(_ kind: WakeEventKind) -> String {
    switch kind {
    case .sleep: return L10n.string("Sleep")
    case .darkWake: return L10n.string("Dark Wake")
    case .wake: return L10n.string("User Wake")
    }
  }

  private func wakeKindTint(_ kind: WakeEventKind) -> Color {
    switch kind {
    case .sleep: return .secondary
    case .darkWake: return .purple
    case .wake: return .green
    }
  }

  // MARK: - Power Helper

  private func powerHelperSection(isProminent: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsCard(
        L10n.string("Power Helper"),
        desc: L10n.string(
          "System power settings and the system time zone are both written through it; it needs administrator approval."
        )
      ) {
        SettingsRows {
          PowerHelperStateRow(
            title: powerHelper.registrationState.title,
            desc: powerHelper.registrationState.detail,
            systemImage: powerHelper.registrationState.isEnabled
              ? "checkmark.shield.fill"
              : isProminent ? "exclamationmark.shield.fill" : "shield.lefthalf.filled",
            tint: powerHelper.registrationState.isEnabled ? .green : .orange
          ) {
            helperActionButton
          }
        }
      }

      if let helperFeedback {
        Text(helperFeedback)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, SettingsMetrics.rowPaddingH)
          .transition(motion.revealTransition(edge: .top))
      }
    }
    .animation(motion.stateAnimation, value: powerHelper.registrationState)
    .confirmationDialog(
      L10n.string("Remove Power Helper?"),
      isPresented: $isConfirmingHelperRemoval,
      titleVisibility: .visible
    ) {
      Button(L10n.string("Remove Helper"), role: .destructive) { removePowerHelper() }
      Button(L10n.string("Cancel"), role: .cancel) {}
    } message: {
      Text(
        L10n.string(
          "System power settings and the system time zone cannot be written again until the Helper is reinstalled; nothing else about MenuCue changes."
        )
      )
    }
  }

  @ViewBuilder
  private var helperActionButton: some View {
    switch powerHelper.registrationState {
    case .enabled:
      Button("Remove Helper", role: .destructive) {
        isConfirmingHelperRemoval = true
      }
      .disabled(powerHelper.isWorking)
    case .requiresApproval:
      Button("Open System Settings") {
        powerHelper.openSystemSettings()
      }
      .buttonStyle(.borderedProminent)
      Button("Cancel Install", role: .destructive) {
        isConfirmingHelperRemoval = true
      }
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

/// The Helper's live state, on the card surface rather than `SettingsListRow`'s recessed
/// fill, because the design document renders it as the card's body: a status icon, the
/// state the manager reports, and the action that can change it.
private struct PowerHelperStateRow<Action: View>: View {
  let title: String
  let desc: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let action: Action

  init(
    title: String,
    desc: String,
    systemImage: String,
    tint: Color,
    @ViewBuilder action: () -> Action
  ) {
    self.title = title
    self.desc = desc
    self.systemImage = systemImage
    self.tint = tint
    self.action = action()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: SettingsMetrics.labelSpacing) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
        Text(desc)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      action
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, SettingsMetrics.rowPaddingV)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.settingsCardSurface)
  }
}

/// A write to both power sources, held until it has been confirmed. Battery and AC
/// disagreeing is the only case where one switch changes two settings at once.
private struct PendingPowerSetting: Identifiable {
  let setting: ManagedPowerSetting
  let enabled: Bool

  var id: String { "\(setting.rawValue)-\(enabled)" }
}
