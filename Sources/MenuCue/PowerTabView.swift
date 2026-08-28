import SwiftUI

struct PowerTabView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var diagnostics: PowerDiagnosticsService
  @ObservedObject var processEnergy: ProcessEnergyService
  @ObservedObject var processHealth: ProcessHealthService
  /// Opens the Settings window on the Power pane, which owns the system power switches.
  let openPowerSettings: () -> Void
  @ObservedObject private var popoverPresentation = PopoverPresentationState.shared

  @State private var selectedProcess: ProcessEnergyEntry?
  @State private var selectedGroup: ProcessEnergyGroup?
  @State private var isSamplingActive = false

  private var helper: PowerHelperManager { model.quickActionService.powerHelperManager }

  var body: some View {
    PopoverHapticScrollView {
      VStack(spacing: PopoverMetrics.cardSpacing) {
        monitoringNotice
        batteryCard
        sleepBlockersCard
        wakeCard
        profilesCard
        processCard
        processHealthCard
      }
    }
    .onAppear {
      helper.refreshStatus()
      updateSampling(isVisible: popoverPresentation.isVisible)
    }
    .onDisappear {
      updateSampling(isVisible: false)
    }
    .onChange(of: popoverPresentation.isVisible) { isVisible in
      updateSampling(isVisible: isVisible)
    }
    .sheet(item: $selectedProcess) { entry in
      ProcessDetailSheet(entry: entry, service: processEnergy, helper: helper) {
        processEnergy.refresh()
      }
    }
    .sheet(item: $selectedGroup) { group in
      ProcessTerminationSheet(name: group.name, members: group.members, helper: helper) {
        processEnergy.refresh()
      }
    }
  }

  /// Says what this tab cannot answer while monitoring is off, and offers the switch.
  ///
  /// Opening the tab used to turn monitoring on by itself. Saying so and waiting for a
  /// click costs one row and leaves the choice with the user.
  @ViewBuilder
  private var monitoringNotice: some View {
    if !model.settings.powerMonitoringEnabled {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: "moon.zzz")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.orange)
        Text(
          L10n.string("Power monitoring is off, so history only covers the time this tab is open.")
        )
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button(L10n.string("Turn On")) {
          model.setPowerMonitoring(enabled: true)
        }
        .buttonStyle(.link)
        .font(.system(size: 10, weight: .semibold))
        .fixedSize()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        Color.orange.opacity(0.10),
        in: RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .continuous)
      )
    }
  }

  private var batteryCard: some View {
    PopoverCard(title: "Battery Flow", systemImage: "battery.100percent", tint: .green) {
      Button {
        diagnostics.refresh()
      } label: {
        Image(systemName: diagnostics.isRefreshing ? "hourglass" : "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help(L10n.string("Refresh power diagnostics"))
      .disabled(diagnostics.isRefreshing)
    } content: {
      if let battery = diagnostics.battery {
        HStack(alignment: .firstTextBaseline) {
          Text("\(battery.percentage)%")
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .monospacedDigit()
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text(powerSourceText(battery.isOnAC))
              .font(.system(size: 11, weight: .semibold))
            Text(chargingText(battery.isCharging))
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(.secondary)
            if let minutes = battery.conservativeRuntimeMinutes {
              Text(L10n.format("Est. %@ left", runtimeText(minutes)))
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .menuCueNumericTransition(value: minutes)
            }
          }
        }
        // The Sankey diagram needs classified telemetry; Intel Macs, desktops, and
        // parse failures keep the flat capacity bar unchanged.
        if let flowState = PowerFlowState.make(battery: battery) {
          PowerFlowView(state: flowState)
        } else {
          MetricBar(fraction: Double(battery.percentage) / 100, tint: .green)
        }
        HStack {
          if let flow = battery.flow {
            MetricReadout(
              label: "Battery flow",
              value: String(format: "%+.1f W", flow.watts),
              valueColor: flow.watts < 0 ? .orange : .green)
            MetricReadout(
              label: "Rate",
              value: String(format: "%+.1f%%/h", flow.percentPerHour),
              valueColor: .secondary,
              alignment: .trailing)
          } else {
            CardPlaceholder(message: "Battery flow unavailable")
          }
        }
      } else {
        CardPlaceholder(message: "No internal battery")
      }
    }
  }

  /// Only shown when something is actually holding the Mac awake. An always-present
  /// card saying "nothing" would cost a fifth of the popover to say nothing.
  @ViewBuilder
  private var sleepBlockersCard: some View {
    let blockers = diagnostics.snapshot.sleepBlockers
    if !blockers.isEmpty {
      PopoverCard(title: "Keeping Awake", systemImage: "eye.fill", tint: .yellow) {
        Text("\(blockers.count)")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      } content: {
        VStack(spacing: 4) {
          ForEach(blockers.prefix(4)) { assertion in
            HStack(spacing: 6) {
              Text(assertion.process)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
              Text(assertion.localized ?? assertion.reason)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 4)
              Text(assertion.heldDescription)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(assertion.heldSeconds >= 14_400 ? .red : .secondary)
            }
          }
          if blockers.count > 4 {
            Text(L10n.format("and %d more", blockers.count - 4))
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  private var wakeCard: some View {
    // Clearing this history lives in Settings > Power, next to the button that brings
    // it back: a destructive act and its undo in one place rather than one in the
    // popover and the other in another window.
    PopoverCard(title: "Sleep & Wake", systemImage: "moon.zzz.fill", tint: .indigo) {
      if let refreshedAt = diagnostics.snapshot.refreshedAt {
        Text(refreshedAt, style: .relative)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.tertiary)
      }
    } content: {
      // The answer first. The counts below are context for it, not the point.
      if let latest = diagnostics.snapshot.latestWake {
        VStack(alignment: .leading, spacing: 2) {
          Text(
            L10n.format(
              "Last woke at %@",
              latest.event.timestamp.formatted(date: .omitted, time: .shortened))
          )
          .font(.system(size: 12, weight: .semibold))
          Text(latest.cause.sentence)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let stats = diagnostics.snapshot.wakeStatistics {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            WakeCount(label: "Sleep", value: stats.sleepCount, color: .blue)
            WakeCount(label: "Dark Wake", value: stats.darkWakeCount, color: .orange)
            WakeCount(label: "User Wake", value: stats.userWakeCount, color: .green)
          }
          // These come from `pmset -g stats`, which counts from boot and resets on
          // restart. Stacking them unlabelled next to a 30-day figure and a today
          // figure was three different windows with nothing to tell them apart.
          Text(L10n.string("since you last restarted"))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
      }

      if !diagnostics.snapshot.dailySummaries.isEmpty {
        HStack {
          Text(L10n.string("30-day local history"))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
          Spacer()
          if let today = diagnostics.snapshot.darkWakeCount(on: Date()) {
            Text(L10n.format("%d dark wakes today", today))
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.orange)
          } else {
            Text(L10n.string("no record for today"))
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
          }
        }
      }

      Divider().opacity(0.4)
      let recent = diagnostics.snapshot.events.suffix(12).reversed()
      if recent.isEmpty {
        CardPlaceholder(message: "No sleep or wake events")
      } else {
        VStack(spacing: 5) {
          ForEach(Array(recent)) { event in
            WakeEventRow(
              event: event,
              sentence: PowerAttributionParser.sentence(
                for: event, scheduled: diagnostics.snapshot.scheduledWakes))
          }
        }
      }

      if let error = diagnostics.snapshot.errorMessage {
        Text(error)
          .font(.system(size: 9))
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
  }

  /// What `pmset` reports for the source this Mac is on, and the way to change it.
  ///
  /// These are system-wide settings, so the switches themselves live in Settings ▸
  /// Power. Reading them here is still worth the space: the tab above explains what
  /// woke the Mac, and Power Nap and Wake for network access are usually the answer.
  private var profilesCard: some View {
    PopoverCard(title: "Power Profiles", systemImage: "slider.horizontal.3", tint: .cyan) {
      if let currentSourceLabel {
        Text(currentSourceLabel)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
    } content: {
      if let profile = currentProfile {
        profileSummaryRow("Power Nap", value: profile.powerNap)
        profileSummaryRow("Wake for network access", value: profile.wakeOnNetwork)
        profileSummaryRow("Standby", value: profile.standby)
        profileSummaryRow("TCP Keepalive", value: profile.tcpKeepalive)
        HStack {
          Text(L10n.string("Power mode"))
          Spacer()
          Text(powerModeText(profile.powerMode))
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 10, weight: .medium))
      } else {
        CardPlaceholder(message: "Power profile unavailable")
      }

      // Whether these can be changed at all depends on the helper, so its state stays
      // visible next to the values it gates.
      if !helper.registrationState.isEnabled {
        Text(helper.registrationState.detail)
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Button(L10n.string("Configure in Settings"), action: openPowerSettings)
        .buttonStyle(.link)
        .font(.system(size: 10, weight: .semibold))
    }
  }

  /// The profile for the source the Mac is actually running on. Picking a different
  /// one is a configuration act, and configuration lives in Settings.
  private var currentProfile: PowerProfile? {
    let profiles = diagnostics.snapshot.profiles
    guard let onAC = diagnostics.battery?.isOnAC else { return profiles.ac ?? profiles.battery }
    return onAC ? profiles.ac : profiles.battery
  }

  private var currentSourceLabel: String? {
    guard let onAC = diagnostics.battery?.isOnAC else { return nil }
    return L10n.string(onAC ? "AC" : "Battery")
  }

  private func profileSummaryRow(_ title: String, value: Bool?) -> some View {
    HStack {
      Text(L10n.string(title))
      Spacer()
      Text(value.map { L10n.string($0 ? "On" : "Off") } ?? L10n.string("Unavailable"))
        .foregroundStyle(.secondary)
    }
    .font(.system(size: 10, weight: .medium))
  }

  private var processCard: some View {
    PopoverCard(title: "Energy Impact", systemImage: "bolt.circle.fill", tint: .orange) {
      HStack(spacing: 5) {
        Picker("Process view", selection: $processEnergy.viewMode) {
          Text(L10n.string("Apps")).tag(ProcessEnergyService.ViewMode.apps)
          Text(L10n.string("Processes")).tag(ProcessEnergyService.ViewMode.processes)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 108)
        .controlSize(.mini)
        Button(action: processEnergy.refresh) {
          Image(systemName: processEnergy.isRefreshing ? "hourglass" : "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help(L10n.string("Refresh energy impact"))
        .disabled(processEnergy.isRefreshing)
      }
    } content: {
      Text(L10n.string("Energy impact is a relative macOS score, not watts."))
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)

      if processEnergy.viewMode == .apps {
        ForEach(processEnergy.groups.prefix(8)) { group in
          Button {
            selectedGroup = group
          } label: {
            ProcessEnergyRow(name: group.name, impact: group.energyImpact, detail: "\(group.members.count)")
          }
          .buttonStyle(.plain)
        }
      } else {
        ForEach(processEnergy.entries.prefix(12)) { entry in
          Button {
            selectedProcess = entry
          } label: {
            ProcessEnergyRow(
              name: entry.name,
              impact: entry.energyImpact,
              detail: "PID \(entry.identity.pid)")
          }
          .buttonStyle(.plain)
        }
      }

      if processEnergy.entries.isEmpty, !processEnergy.isRefreshing {
        CardPlaceholder(message: processEnergy.errorMessage ?? L10n.string("No process energy sample"))
      }
    }
  }
  private var processHealthCard: some View {
    PopoverCard(title: L10n.string("Process Health"), systemImage: "waveform.path.ecg", tint: .purple) {
      HStack(spacing: 8) {
        Button(action: processHealth.analyze) {
          Image(systemName: processHealth.isAnalyzing ? "hourglass" : "stethoscope")
        }
        .buttonStyle(.plain)
        .help(L10n.string("Analyze process health"))
        .disabled(processHealth.isAnalyzing)

        Button(action: processHealth.openActivityMonitor) {
          Image(systemName: "rectangle.on.rectangle")
        }
        .buttonStyle(.plain)
        .help(L10n.string("Open Activity Monitor"))
      }
    } content: {
      Text(L10n.string("Manual scan only; nothing runs in the background."))
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)

      if let snapshot = processHealth.snapshot {
        let zombies = snapshot.zombies
        HStack(spacing: 8) {
          HealthReadout(
            label: "Zombies",
            value: "\(zombies.count)",
            tint: zombies.isEmpty ? .secondary : .red)
          HealthReadout(label: "Threads", value: "\(snapshot.totalThreads)", tint: .secondary)
          HealthReadout(label: "Processes", value: "\(snapshot.processes.count)", tint: .secondary)
        }
        if let busiest = snapshot.busiestProcesses.first {
          Text(L10n.format("CPU: %@ · %@", busiest.command, String(format: "%.1f%%", busiest.cpuPercent)))
            .lineLimit(1)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        if let mostThreaded = snapshot.mostThreadedProcesses.first {
          Text(L10n.format("Threads: %@ · %d", mostThreaded.command, mostThreaded.threadCount))
            .lineLimit(1)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        if let zombie = zombies.first {
          Text(L10n.format("Zombie: %@ · PID %d", zombie.command, zombie.pid))
            .lineLimit(1)
            .font(.system(size: 9))
            .foregroundStyle(.red)
        }
      } else if let error = processHealth.errorMessage {
        Text(error).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
      }
    }
  }

  private func updateSampling(isVisible: Bool) {
    guard isVisible != isSamplingActive else { return }
    isSamplingActive = isVisible
    if isVisible {
      diagnostics.retain()
      processEnergy.retain()
    } else {
      diagnostics.release()
      processEnergy.release()
    }
  }

  private func powerSourceText(_ onAC: Bool?) -> String {
    guard let onAC else { return L10n.string("Power source unavailable") }
    return L10n.string(onAC ? "AC Power" : "Battery Power")
  }

  private func chargingText(_ charging: Bool?) -> String {
    guard let charging else { return L10n.string("Charging status unavailable") }
    return L10n.string(charging ? "Charging" : "Discharging")
  }

  private func runtimeText(_ minutes: Int) -> String {
    String(format: "%d:%02d", minutes / 60, minutes % 60)
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
}

private struct WakeCount: View {
  let label: String
  let value: Int
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(value)")
        .font(.system(size: 18, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(color)
      Text(L10n.string(label))
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct HealthReadout: View {
  let label: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(tint)
      Text(L10n.string(label))
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct WakeEventRow: View {
  let event: WakeEvent
  /// The row's one sentence, from `PowerAttributionParser.sentence(for:scheduled:)`.
  /// Falls back to the interrupt token's plain reading, so this row no longer shows
  /// `smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNo…` clipped at 9pt — and a
  /// sleep is described as a sleep rather than attributed to a scheduled wake.
  let sentence: String

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(event.timestamp, style: .time)
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 58, alignment: .leading)
      Text(sentence)
        .font(.system(size: 10))
        .lineLimit(1)
        .truncationMode(.tail)
        // The raw token stays reachable on hover, since the plain reading is a
        // translation and a translation can be wrong.
        .help(event.reason)
      Spacer(minLength: 0)
    }
  }

  private var color: Color {
    switch event.kind {
    case .sleep: return .blue
    case .darkWake: return .orange
    case .wake: return .green
    }
  }
}

private struct ProcessEnergyRow: View {
  let name: String
  let impact: Double
  let detail: String

  var body: some View {
    HStack(spacing: 7) {
      VStack(alignment: .leading, spacing: 1) {
        Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        Text(detail).font(.system(size: 8)).foregroundStyle(.tertiary)
      }
      Spacer()
      Text(String(format: "%.1f", impact))
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(impact >= 50 ? .red : (impact >= 15 ? .orange : .secondary))
    }
    .contentShape(Rectangle())
  }
}

private struct ProcessDetailSheet: View {
  let entry: ProcessEnergyEntry
  @ObservedObject var service: ProcessEnergyService
  @ObservedObject var helper: PowerHelperManager
  let onChanged: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var detail: ProcessDetail?
  @State private var feedback: String?
  @State private var confirmation = ""
  @State private var isConfirmingTermination = false

  private var requiresStrongConfirmation: Bool {
    ProcessControlPolicy.requiresStrongConfirmation(for: entry.identity)
  }

  private var strongConfirmationSatisfied: Bool {
    !requiresStrongConfirmation || confirmation == entry.name
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading) {
          Text(entry.name).font(.headline)
          Text("PID \(entry.identity.pid) · UID \(entry.identity.ownerUID)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).help(L10n.string("Close"))
      }
      Text(entry.identity.executablePath)
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)

      if let detail {
        Text(L10n.format("CPU %.1f%% · Memory %.1f%% · Nice %d", detail.cpuPercent, detail.memoryPercent, detail.nice))
          .font(.caption)
      }

      if requiresStrongConfirmation {
        TextField(L10n.format("Type %@ to confirm", entry.name), text: $confirmation)
      }

      HStack {
        Button { renice(-1) } label: { Label(L10n.string("Raise priority"), systemImage: "plus") }
          .disabled(!strongConfirmationSatisfied)
        Button { renice(1) } label: { Label(L10n.string("Lower priority"), systemImage: "minus") }
          .disabled(!strongConfirmationSatisfied)
        Spacer()
        Button(role: .destructive) { isConfirmingTermination = true } label: {
          Label(L10n.string("Terminate"), systemImage: "xmark.octagon")
        }
        .disabled(!strongConfirmationSatisfied)
      }
      .controlSize(.small)

      if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
    }
    .padding(20)
    .frame(width: 480)
    .confirmationDialog(
      L10n.format("Terminate %@?", entry.name),
      isPresented: $isConfirmingTermination,
      titleVisibility: .visible
    ) {
      Button(L10n.string("Terminate"), role: .destructive, action: terminate)
      Button(L10n.string("Cancel"), role: .cancel) {}
    } message: {
      Text(L10n.string("SIGTERM will be sent to this confirmed process."))
    }
    .onAppear {
      service.detail(for: entry.identity) { result in
        if case .success(let value) = result { detail = value }
        if case .failure(let error) = result { feedback = error.localizedDescription }
      }
    }
  }

  private func terminate() {
    helper.terminateProcess(entry.identity) { result in
      feedback = result.failureMessage ?? L10n.string("SIGTERM sent.")
      if case .success = result { onChanged() }
    }
  }

  private func renice(_ delta: Int) {
    helper.reniceProcess(entry.identity, delta: delta) { result in
      switch result {
      case .success(let observed): feedback = L10n.format("Nice value is now %d.", observed)
      case .failure(let error): feedback = error.localizedDescription
      }
      onChanged()
    }
  }
}

private struct ProcessTerminationSheet: View {
  let name: String
  let members: [ProcessEnergyEntry]
  @ObservedObject var helper: PowerHelperManager
  let onChanged: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var confirmation = ""
  @State private var feedback: String?
  @State private var isWorking = false

  private var requiresTypedConfirmation: Bool {
    members.count > 1 || members.contains {
      ProcessControlPolicy.requiresStrongConfirmation(for: $0.identity)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(L10n.format("Terminate %@?", name)).font(.headline)
      Text(L10n.format("SIGTERM will be sent to %d confirmed processes.", members.count))
        .font(.caption).foregroundStyle(.secondary)
      if requiresTypedConfirmation {
        TextField(L10n.format("Type %@ to confirm", name), text: $confirmation)
      }
      HStack {
        Button(L10n.string("Cancel")) { dismiss() }
        Spacer()
        Button(L10n.string("Terminate"), role: .destructive, action: terminateAll)
          .disabled(isWorking || (requiresTypedConfirmation && confirmation != name))
      }
      if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
    }
    .padding(20)
    .frame(width: 440)
  }

  private func terminateAll() {
    isWorking = true
    terminateMember(at: 0, failures: 0)
  }

  private func terminateMember(at index: Int, failures: Int) {
    guard index < members.count else {
      isWorking = false
      feedback = failures == 0
        ? L10n.string("SIGTERM sent to all confirmed processes.")
        : L10n.format("%d process actions failed.", failures)
      onChanged()
      return
    }
    helper.terminateProcess(members[index].identity) { result in
      let nextFailures = failures + (result.failureMessage == nil ? 0 : 1)
      terminateMember(at: index + 1, failures: nextFailures)
    }
  }
}

private extension Result {
  var failureMessage: String? {
    if case .failure(let error) = self { return String(describing: error) }
    return nil
  }
}
