import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TrackpadSettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @ObservedObject var model: AppModel
  @ObservedObject private var service: TrackpadGestureService

  @State private var tab: TrackpadSettingsTab = .rules
  @State private var editingTarget: TrackpadRuleSheetTarget?
  @State private var feedbackMessage: String?
  @State private var feedbackIsError = false
  @State private var showsResetConfirmation = false

  init(model: AppModel) {
    self.model = model
    self.service = model.trackpadGestureService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      moduleHeader
      TrackpadSettingsTabBar(selection: $tab)
      tabContent
    }
    .frame(maxWidth: TrackpadSettingsLayout.paneWidth, alignment: .leading)
    .onAppear {
      model.quickActionService.refreshAll()
    }
    .sheet(item: $editingTarget) { target in
      TrackpadRuleEditorSheet(
        model: model,
        rule: target.rule,
        isNewRule: target.isNew,
        onSave: saveRule,
        onDelete: deleteRule
      )
    }
    .confirmationDialog(
      "Reset gesture presets?",
      isPresented: $showsResetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset Presets", role: .destructive, action: resetPresets)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This replaces the current rule list with MenuCue's editable presets.")
    }
  }

  private var settings: TrackpadGestureSettings {
    model.settings.trackpadGestureSettings
  }

  /// The one control every tab needs within reach: a rule list nobody can trigger reads the
  /// same as one that works, so the module switch stays above the tabs rather than inside
  /// the diagnostics tab with the status card it belongs to.
  private var moduleHeader: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Trackpad Runtime")
          .font(.headline)
        Text("Raw touch capture starts only while this module is enabled.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Toggle("Enable trackpad gestures", isOn: enabledBinding)
        .toggleStyle(.switch)
    }
  }

  /// Each tab renders on its own, which is what stops the 30 Hz preview: leaving the
  /// diagnostics tab takes `TrackpadLivePreviewCard` out of the hierarchy, and its gate
  /// releases the preview from `onDisappear`.
  @ViewBuilder
  private var tabContent: some View {
    switch tab {
    case .rules:
      VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
        rulesCard
        ruleSetCard
      }
    case .feedback:
      VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
        feedbackCard
        gestureParametersCard
      }
    case .diagnostics:
      VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
        runtimeCard
        clickSuppressionCard
        if settings.isEnabled {
          TrackpadLivePreviewCard(service: service)
        }
      }
    }
  }

  /// Runtime state, input ownership, and click suppression each get their own card: the
  /// design document reads the status banner as a fact, the suppression switch as a
  /// decision, and the ownership pause as a condition on the first.
  private var runtimeCard: some View {
    SettingsCard(
      L10n.string("Runtime"),
      desc: L10n.string(
        "Raw touch observation remains pass-through. MenuCue consumes native input only for an explicitly enabled click rule or while a configured continuous edge gesture is active. Input suppression requires Accessibility; volume and supported display brightness do not."
      ),
      content: {
        SettingsRows {
          runtimeStatusRow

          switch service.inputOwnership {
          case .local:
            EmptyView()
          case .mirroredDisplay:
            ownershipPauseRow(
              desc: L10n.string(
                "AirPlay display mirroring is active. MenuCue pauses local gesture automation so system input remains pass-through."
              )
            )
          case .remoteOrUnknown:
            ownershipPauseRow(
              desc: L10n.string(
                "The pointer is outside this Mac's displays. MenuCue pauses local gesture automation so cross-Mac input is not captured here."
              )
            )
          }
        }
      }
    )
  }

  /// The design document's status row: state icon, state title, its explanation, and the
  /// one action that can change the state. The starting spinner keeps its place beside the
  /// action so a state that resolves on its own still says so.
  private var runtimeStatusRow: some View {
    SettingsBanner(
      runtimeStatusTitle,
      desc: runtimeStatusDetail,
      systemImage: runtimeStatusSymbol,
      tint: runtimeStatusColor
    ) {
      HStack(spacing: 8) {
        if case .starting = service.status {
          MotionAwareProgressIndicator(scale: 0.8)
        }
        Button(L10n.string("Retry")) {
          service.retry()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!settings.isEnabled || isRuntimeStarting)
        .help("Retry trackpad detection and optional capabilities")
        .accessibilityHint("Rechecks trackpad support without changing your rules.")
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(runtimeAccessibilityLabel)
  }

  /// One of the two input-ownership pauses. The sentence is the one the pane already
  /// showed; the pause is stated as a chip, which is how the design document reads the
  /// same fact without a second status icon.
  private func ownershipPauseRow(desc: String) -> some View {
    SettingsRow(L10n.string("Local Gestures Paused"), desc: desc) {
      SettingsChip(L10n.string("Paused"), systemImage: "pause.fill", tint: .orange)
    }
  }

  private var clickSuppressionCard: some View {
    SettingsCard(
      L10n.string("Click Suppression"),
      desc: L10n.string(
        "A recognized multi-finger tap can suppress the left click so it cannot misfire; that suppression needs Accessibility."
      ),
      content: {
        SettingsRows {
          SettingsRowToggle(
            L10n.string("Suppress the left click after a multi-finger tap"),
            desc: L10n.string(
              "Native scrolling is suppressed while an enabled continuous edge rule owns the trackpad. Click suppression remains optional."
            ),
            isOn: clickSuppressionBinding
          )
          .help("Only the matching click immediately after a recognized multi-finger tap is consumed.")

          if settings.suppressesClickAfterMultiFingerTap {
            clickSuppressionStatus
          }
          if suppressesNativeScrolling {
            edgeScrollSuppressionStatus
          }
        }
      }
    )
  }

  /// A suppression state as one design-system row: the state's sentence with its chip, and
  /// any remediation buttons on their own line, because two buttons never fit beside a
  /// label this long in a 560pt pane.
  private func suppressionStatusRow<Actions: View>(
    _ title: String,
    desc: String,
    chip: String,
    systemImage: String,
    tint: Color,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    SettingsStackedRow(title, desc: desc) {
      HStack(spacing: 8) {
        SettingsChip(chip, systemImage: systemImage, tint: tint)
        Spacer(minLength: 8)
        actions()
      }
    }
  }

  /// What an unavailable suppression offers instead: recheck the runtime, or open the
  /// pane that grants the permission.
  private var suppressionRetryButtons: some View {
    HStack(spacing: 8) {
      Button(L10n.string("Retry")) { service.retry() }
        .disabled(!settings.isEnabled)
      Button(L10n.string("Open System Settings")) { service.openAccessibilitySettings() }
    }
  }

  @ViewBuilder
  private var clickSuppressionStatus: some View {
    switch service.clickSuppressionStatus {
    case .disabled:
      suppressionStatusRow(
        L10n.string("Click Suppression"),
        desc: settings.isEnabled
          ? L10n.string("Click suppression is starting")
          : L10n.string("Click suppression starts with the module"),
        chip: settings.isEnabled ? L10n.string("Starting") : L10n.string("Inactive"),
        systemImage: "pause.circle",
        tint: .secondary
      ) { EmptyView() }

    case .active:
      suppressionStatusRow(
        L10n.string("Click Suppression"),
        desc: L10n.string("Click suppression is active"),
        chip: L10n.string("Active"),
        systemImage: "checkmark.circle.fill",
        tint: .green
      ) { EmptyView() }

    case .requiresAccessibility:
      suppressionStatusRow(
        L10n.string("Accessibility Permission"),
        desc: L10n.string("Accessibility permission is required for click suppression."),
        chip: L10n.string("Needs Authorization"),
        systemImage: "exclamationmark.shield.fill",
        tint: .orange
      ) {
        if !suppressesNativeScrolling {
          suppressionPermissionButtons
        }
      }

    case .unavailable(let reason):
      suppressionStatusRow(
        L10n.string("Click Suppression"),
        desc: L10n.string(reason),
        chip: L10n.string("Unavailable"),
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      ) {
        if !suppressesNativeScrolling {
          suppressionRetryButtons
        }
      }
    }
  }

  @ViewBuilder
  private var edgeScrollSuppressionStatus: some View {
    switch service.edgeScrollSuppressionStatus {
    case .disabled:
      suppressionStatusRow(
        L10n.string("Edge Scroll Suppression"),
        desc: settings.isEnabled
          ? L10n.string("Edge scroll suppression is starting")
          : L10n.string("Edge scroll suppression starts with the module"),
        chip: settings.isEnabled ? L10n.string("Starting") : L10n.string("Inactive"),
        systemImage: "pause.circle",
        tint: .secondary
      ) { EmptyView() }

    case .active:
      suppressionStatusRow(
        L10n.string("Edge Scroll Suppression"),
        desc: L10n.string("Native scrolling is suppressed during matching edge gestures"),
        chip: L10n.string("Active"),
        systemImage: "checkmark.circle.fill",
        tint: .green
      ) { EmptyView() }

    case .requiresAccessibility:
      suppressionStatusRow(
        L10n.string("Accessibility Permission"),
        desc: L10n.string(
          "Accessibility permission is required to suppress native scrolling during edge gestures."
        ),
        chip: L10n.string("Needs Authorization"),
        systemImage: "exclamationmark.shield.fill",
        tint: .orange
      ) {
        suppressionPermissionButtons
      }

    case .unavailable(let reason):
      suppressionStatusRow(
        L10n.string("Edge Scroll Suppression"),
        desc: L10n.string(reason),
        chip: L10n.string("Unavailable"),
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      ) {
        suppressionRetryButtons
      }
    }
  }

  private var suppressionPermissionButtons: some View {
    HStack(spacing: 8) {
      Button("Request Access") {
        service.requestInputSuppressionAccessibility()
      }
      .disabled(!settings.isEnabled)

      Button("Open System Settings") {
        service.openAccessibilitySettings()
      }
    }
  }

  private var feedbackCard: some View {
    SettingsCard(
      L10n.string("Feedback and Edge Control"),
      desc: L10n.string("Feedback is local to this Mac. Edge values apply to every edge-based rule."),
      content: {
        SettingsRows {
          SettingsRowToggle(
            L10n.string("Haptic feedback"),
            desc: L10n.string("Gives a light tap after a successful action."),
            isOn: settingBinding(\.hapticFeedbackEnabled)
          )

          SettingsRowToggle(
            L10n.string("Feedback HUD"),
            desc: L10n.string("Shows a brief 236 × 64 hint near the bottom of the screen."),
            isOn: settingBinding(\.feedbackHUDEnabled)
          )

          SettingsRow(
            L10n.string("HUD Preview"),
            desc: L10n.string(
              "Shown near the bottom of the screen for 1.6 seconds, then faded out over 0.18 seconds. Duration and position are not configurable."
            )
          ) {
            SettingsChip(L10n.string("Not Configurable"))
          }
        }
      }
    )
  }

  private var gestureParametersCard: some View {
    SettingsCard(
      L10n.string("Global Gesture Parameters"),
      desc: L10n.string(
        "Continuous actions such as volume and brightness scale as a whole with the sensitivity."
      ),
      content: {
        SettingsRows {
          TrackpadSliderRow(
            title: L10n.string("Edge width"),
            desc: L10n.string("Edge width runs 3%–20%, in steps of 1%. Every edge-entry and continuous rule shares this value."),
            value: settingBinding(\.edgeWidth),
            range: 0.03...0.20,
            step: 0.01,
            valueLabel: TrackpadUIFormat.percent(settings.edgeWidth)
          )

          TrackpadSliderRow(
            title: L10n.string("Sensitivity"),
            desc: L10n.string("0.25×–4.00× in 0.05× steps."),
            value: settingBinding(\.sensitivity),
            range: 0.25...4,
            step: 0.05,
            valueLabel: TrackpadUIFormat.multiplier(settings.sensitivity)
          )
        }
      }
    )
  }

  private var rulesCard: some View {
    SettingsCard(
      L10n.string("Gesture Rules"),
      desc: L10n.string("Rules with a specific app scope run before global rules; ties follow the list order."),
      action: {
        Button(action: addRule) {
          Label(L10n.string("Add Rule"), systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      },
      content: {
        if settings.rules.isEmpty {
          SettingsEmptyState(
            L10n.string("No Gesture Rules"),
            desc: L10n.string("Add a rule to connect a touch gesture to a system or app action."),
            systemImage: "hand.tap"
          ) {
            Button(L10n.string("Add Gesture Rule"), action: addRule)
          }
        } else {
          // Resolved once for the whole list: every rule's answer depends on the same
          // permission state, and this pane redraws with live touch input.
          let availabilities = service.availabilities(for: settings.rules.map(\.action))
          SettingsTable(columns: [
            SettingsTableColumn(L10n.string("Rule"), weight: 200),
            SettingsTableColumn(L10n.string("Action"), weight: 175),
            SettingsTableColumn(L10n.string("Scope"), weight: 100),
            SettingsTableColumn("", weight: 80),
          ]) {
            ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
              TrackpadRuleRow(
                rule: rule,
                availability: availabilities[index],
                index: index,
                ruleCount: settings.rules.count,
                onToggle: { enabled in
                  updateRule(rule.id) { $0.isEnabled = enabled }
                },
                onEdit: { editingTarget = TrackpadRuleSheetTarget(rule: rule, isNew: false) },
                onDuplicate: { duplicateRule(rule) },
                onDelete: { deleteRule(rule.id) },
                onMoveUp: { moveRule(at: index, by: -1) },
                onMoveDown: { moveRule(at: index, by: 1) }
              )
            }
          }
        }
      }
    )
  }

  private var ruleSetCard: some View {
    SettingsCard(
      L10n.string("Rule Set"),
      desc: L10n.string(
        "Import and export use a versioned local JSON file. Invalid neighbors are normalized independently."
      ),
      tone: .inset,
      content: {
        SettingsRows {
          SettingsStackedRow(
            L10n.string("Rule Set File"),
            desc: L10n.string("This replaces the current rule list with MenuCue's editable presets.")
          ) {
            HStack(spacing: 8) {
              Button(action: importRuleSet) {
                Label(L10n.string("Import JSON"), systemImage: "square.and.arrow.down")
              }
              .buttonStyle(.bordered)
              .controlSize(.small)

              Button(action: exportRuleSet) {
                Label(L10n.string("Export JSON"), systemImage: "square.and.arrow.up")
              }
              .buttonStyle(.bordered)
              .controlSize(.small)

              Spacer(minLength: 8)

              Button(L10n.string("Reset Presets"), role: .destructive) {
                showsResetConfirmation = true
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(.red)
            }
          }

          SettingsRow(
            L10n.string("Current Rule Count"),
            desc: L10n.format("%1$d enabled · %2$d disabled", enabledRuleCount, disabledRuleCount)
          ) {
            SettingsChip(String(settings.rules.count))
          }

          if let feedbackMessage {
            SettingsRow(feedbackMessage) {
              Image(
                systemName: feedbackIsError
                  ? "exclamationmark.triangle.fill"
                  : "checkmark.circle.fill"
              )
              .foregroundStyle(feedbackIsError ? Color.red : Color.green)
              .accessibilityHidden(true)
            }
            .transition(motion.revealTransition(edge: .top))
          }
        }
      }
    )
  }

  private var enabledRuleCount: Int {
    settings.rules.filter(\.isEnabled).count
  }

  private var disabledRuleCount: Int {
    settings.rules.count - enabledRuleCount
  }

  private var enabledBinding: Binding<Bool> {
    settingBinding(\.isEnabled)
  }

  private var clickSuppressionBinding: Binding<Bool> {
    settingBinding(\.suppressesClickAfterMultiFingerTap)
  }

  private var suppressesNativeScrolling: Bool {
    TrackpadRecognizerRegistry.suppressionNeeds(for: settings.rules).contains(.scrollWheel)
  }

  private func settingBinding<Value>(
    _ keyPath: WritableKeyPath<TrackpadGestureSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { model.settings.trackpadGestureSettings[keyPath: keyPath] },
      set: { value in
        model.updateTrackpadGestureSettings { settings in
          settings[keyPath: keyPath] = value
        }
      }
    )
  }

  private func updateRule(_ id: UUID, update: (inout TrackpadGestureRule) -> Void) {
    model.updateTrackpadGestureSettings { settings in
      guard let index = settings.rules.firstIndex(where: { $0.id == id }) else { return }
      update(&settings.rules[index])
    }
  }

  /// The new rule exists only as a draft until the sheet is saved, so backing out of
  /// "Add Rule" leaves the list exactly as it was.
  private func addRule() {
    let rule = TrackpadGestureRule(
      name: L10n.format("Gesture Rule %d", settings.rules.count + 1),
      trigger: TrackpadGestureTrigger(kind: .contact),
      action: TrackpadGestureAction(kind: .none)
    )
    editingTarget = TrackpadRuleSheetTarget(rule: rule, isNew: true)
  }

  /// The single write the sheet performs, for both a new rule and an edited one.
  private func saveRule(_ rule: TrackpadGestureRule) {
    model.updateTrackpadGestureSettings { settings in
      settings.rules = TrackpadRuleDraft.upserting(rule, into: settings.rules)
    }
  }

  private func duplicateRule(_ source: TrackpadGestureRule) {
    var copy = source
    copy.id = UUID()
    copy.name = L10n.format("%@ Copy", source.settingsDisplayName)
    model.updateTrackpadGestureSettings { settings in
      guard let index = settings.rules.firstIndex(where: { $0.id == source.id }) else {
        settings.rules.append(copy)
        return
      }
      settings.rules.insert(copy, at: index + 1)
    }
  }

  private func deleteRule(_ id: UUID) {
    model.updateTrackpadGestureSettings { settings in
      settings.rules.removeAll { $0.id == id }
    }
    if editingTarget?.id == id { editingTarget = nil }
  }

  private func moveRule(at index: Int, by offset: Int) {
    let destination = index + offset
    guard settings.rules.indices.contains(index), settings.rules.indices.contains(destination) else {
      return
    }
    model.updateTrackpadGestureSettings { $0.rules.swapAt(index, destination) }
  }

  private func resetPresets() {
    let localizedPresets = TrackpadGestureSettings.presetRules.map { rule -> TrackpadGestureRule in
      var localized = rule
      localized.name = L10n.string(rule.name)
      return localized
    }
    model.updateTrackpadGestureSettings { $0.rules = localizedPresets }
    editingTarget = nil
    showFeedback(L10n.string("Gesture presets were restored."), isError: false)
  }

  private func exportRuleSet() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(ProductBrand.displayName)-Trackpad-Rules.json"
    panel.title = L10n.string("Export Trackpad Rules")
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(TrackpadRuleSetEnvelope(settings: settings))
      try data.write(to: url, options: .atomic)
      showFeedback(L10n.format("Exported rules to %@.", url.lastPathComponent), isError: false)
    } catch {
      showFeedback(
        L10n.format("Rules could not be exported: %@", error.localizedDescription),
        isError: true
      )
    }
  }

  private func importRuleSet() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.title = L10n.string("Import Trackpad Rules")
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }

    do {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard data.count <= TrackpadSettingsLayout.maximumImportBytes else {
        throw TrackpadSettingsImportError.fileTooLarge
      }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let envelope = try decoder.decode(TrackpadRuleSetEnvelope.self, from: data)
      let imported = try envelope.importedSettings()
      model.updateTrackpadGestureSettings { $0 = imported }
      editingTarget = nil
      showFeedback(
        L10n.format("Imported %d gesture rules.", imported.rules.count),
        isError: false
      )
    } catch {
      showFeedback(
        L10n.format("Rules could not be imported: %@", error.localizedDescription),
        isError: true
      )
    }
  }

  private func showFeedback(_ message: String, isError: Bool) {
    feedbackMessage = message
    feedbackIsError = isError
  }

  private var isRuntimeStarting: Bool {
    if case .starting = service.status { return true }
    return false
  }

  private var runtimeStatusSymbol: String {
    switch service.status {
    case .disabled: return "pause.circle"
    case .starting: return "hourglass"
    case .running: return "checkmark.circle.fill"
    case .unsupported: return "exclamationmark.triangle.fill"
    case .failed: return "xmark.octagon.fill"
    }
  }

  private var runtimeStatusColor: Color {
    switch service.status {
    case .running: return .green
    case .starting: return .accentColor
    case .unsupported: return .orange
    case .failed: return .red
    case .disabled: return .secondary
    }
  }

  private var runtimeStatusTitle: String {
    switch service.status {
    case .disabled: return L10n.string("Trackpad runtime is off")
    case .starting: return L10n.string("Starting trackpad runtime")
    case .running(let deviceCount): return L10n.format("%d active devices", deviceCount)
    case .unsupported: return L10n.string("Trackpad input is unsupported")
    case .failed: return L10n.string("Trackpad runtime failed")
    }
  }

  private var runtimeStatusDetail: String {
    switch service.status {
    case .disabled:
      return settings.isEnabled
        ? L10n.string("The runtime is stopped and will retry when requested.")
        : L10n.string("Enable the module to start local raw touch observation.")
    case .starting:
      return L10n.string("MenuCue is resolving the optional provider and connected devices.")
    case .running(let deviceCount):
      return deviceCount == 0
        ? L10n.string("No supported trackpad is currently connected.")
        : L10n.string("Touch callbacks are active only for the connected supported devices.")
    case .unsupported(let reason), .failed(let reason):
      return L10n.string(reason)
    }
  }

  private var runtimeAccessibilityLabel: String {
    L10n.format("Trackpad status: %@", runtimeStatusTitle)
  }
}

/// Which group of trackpad settings the pane is showing.
///
/// Deliberately view state rather than a router destination: the pane is one settings page
/// whose tabs are a way of reading it, not places to link to. The choice lives as long as
/// the window does.
private enum TrackpadSettingsTab: String, CaseIterable, Identifiable {
  case rules
  case feedback
  case diagnostics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .rules: return L10n.string("Gesture Rules")
    case .feedback: return L10n.string("Feedback and Parameters")
    case .diagnostics: return L10n.string("Runtime and Diagnostics")
    }
  }

  var systemImage: String {
    switch self {
    case .rules: return "hand.tap"
    case .feedback: return "slider.horizontal.3"
    case .diagnostics: return "waveform.path.ecg"
    }
  }
}

/// The pane's tab bar, drawn the way the Dashboard's is: a macOS segmented control renders
/// either the icon or the label, never both.
private struct TrackpadSettingsTabBar: View {
  @Environment(\.menuCueMotion) private var motion
  @Binding var selection: TrackpadSettingsTab
  @Namespace private var highlight
  @State private var hovered: TrackpadSettingsTab?

  var body: some View {
    HStack(spacing: 2) {
      ForEach(TrackpadSettingsTab.allCases) { tab in
        Button {
          guard selection != tab else { return }
          withAnimation(motion.navigationAnimation) { selection = tab }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: tab.systemImage)
              .menuCueSymbolBounce(value: selection == tab)
            Text(tab.title)
          }
          .font(.callout.weight(.medium))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 7)
          .background {
            if selection == tab {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                .menuCueMatchedGeometryEffect(id: "selected-trackpad-tab", in: highlight)
            } else if hovered == tab {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == tab ? .primary : .secondary)
        .onHover { isHovering in
          withAnimation(motion.hoverAnimation) {
            hovered = isHovering ? tab : (hovered == tab ? nil : hovered)
          }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? [.isSelected, .isButton] : .isButton)
      }
    }
    .padding(3)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}

/// The live preview and the gate that pays for it, in one view.
///
/// The preview publishes touches at 30 Hz, so it has to stop both when this card leaves the
/// hierarchy — switching away from the diagnostics tab — and when the settings window is
/// merely ordered out, which never reaches `onDisappear`.
private struct TrackpadLivePreviewCard: View {
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var service: TrackpadGestureService
  @StateObject private var gate = VisibilityGate()

  var body: some View {
    SettingsCard(
      L10n.string("Live Touch Preview"),
      desc: L10n.string("Contact dots are published at a bounded rate of up to 30 Hz."),
      content: {
        SettingsRows {
          SettingsStackedRow(L10n.string("Contact Preview")) {
            TrackpadLiveContactPreview(contacts: service.liveContacts)
          }

          SettingsRow(
            L10n.string("Current Contacts"),
            desc: L10n.string("Contact positions update without consuming normal pointer input.")
          ) {
            HStack(spacing: 6) {
              SettingsChip(L10n.format("%d contacts", activeContactCount))
              SettingsChip(L10n.format("Last recognized: %@", lastRecognitionTitle))
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
    )
    .onAppear {
      gate.connect(
        to: router.visibility(of: .settings),
        onStart: { service.retainLivePreview() },
        onStop: { service.releaseLivePreview() }
      )
    }
    .onDisappear {
      gate.disconnect()
    }
  }

  private var activeContactCount: Int {
    service.liveContacts.reduce(into: 0) { count, contact in
      if contact.state.isActive { count += 1 }
    }
  }

  private var lastRecognitionTitle: String {
    guard let recognition = service.lastRecognition else {
      return L10n.string("Nothing recognized yet")
    }
    let presetNames = Set(TrackpadGestureSettings.presetRules.map(\.name))
    return presetNames.contains(recognition) ? L10n.string(recognition) : recognition
  }
}

enum TrackpadSettingsLayout {
  /// The width the design system's cards settle on, applied to the pane itself so the
  /// header and the tab bar line up with the cards below them.
  static let paneWidth: CGFloat = 560
  static let previewHeight: CGFloat = 210
  static let drawingHeight: CGFloat = 180
  static let contactDiameter: CGFloat = 18
  static let controlCornerRadius: CGFloat = 6
  static let maximumImportBytes = 2 * 1_024 * 1_024
  static let maximumDrawingPoints = 256
  static let minimumDrawingPointDistance = 0.006
}

private enum TrackpadSettingsImportError: LocalizedError {
  case fileTooLarge

  var errorDescription: String? {
    switch self {
    case .fileTooLarge:
      return L10n.string("The JSON file is larger than 2 MB.")
    }
  }
}

private struct TrackpadLiveContactPreview: View {
  let contacts: [TrackpadContact]

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)

        ForEach(contacts) { contact in
          if contact.state.isActive {
            Circle()
              .fill(Color.accentColor.opacity(0.82))
              .overlay {
                Circle().stroke(Color.primary.opacity(0.24), lineWidth: 1)
              }
              .frame(
                width: TrackpadSettingsLayout.contactDiameter,
                height: TrackpadSettingsLayout.contactDiameter
              )
              .position(position(for: contact.position, in: geometry.size))
          }
        }
      }
    }
    .frame(maxWidth: 420)
    .frame(height: TrackpadSettingsLayout.previewHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Live trackpad contacts")
    .accessibilityValue(L10n.format("%d contacts", activeContactCount))
    .accessibilityHint("Contact positions update without consuming normal pointer input.")
  }

  private var activeContactCount: Int {
    contacts.reduce(into: 0) { count, contact in
      if contact.state.isActive { count += 1 }
    }
  }

  private func position(for point: TrackpadPoint, in size: CGSize) -> CGPoint {
    let inset = TrackpadSettingsLayout.contactDiameter / 2
    let width = max(0, size.width - inset * 2)
    let height = max(0, size.height - inset * 2)
    return CGPoint(
      x: inset + CGFloat(point.clamped.x) * width,
      y: inset + CGFloat(1 - point.clamped.y) * height
    )
  }
}

/// Which rule the editor sheet is open on. A new rule carries its seeded draft here
/// rather than in the rule list, so nothing is stored until the sheet saves.
private struct TrackpadRuleSheetTarget: Identifiable {
  let rule: TrackpadGestureRule
  let isNew: Bool

  var id: UUID { rule.id }
}

/// One row of the rule table. Everything but the enable switch and the row menu opens the
/// editor sheet: the row states what the rule does, and the sheet is where it is changed.
///
/// The three labelled cells share the row with the trailing controls, so they stay on the
/// header's columns; the rule's own accessibility lives on the first cell, which keeps the
/// row one element for assistive technology rather than three.
private struct TrackpadRuleRow: View {
  let rule: TrackpadGestureRule
  let availability: ActionAvailability
  let index: Int
  let ruleCount: Int
  let onToggle: (Bool) -> Void
  let onEdit: () -> Void
  let onDuplicate: () -> Void
  let onDelete: () -> Void
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void

  var body: some View {
    SettingsTableRow {
      editCell(ruleColumn, isPrimary: true)
      editCell(actionColumn, isPrimary: false)
      editCell(scopeColumn, isPrimary: false)
      trailingControls
    }
    .opacity(rule.isEnabled ? 1 : 0.68)
    .contextMenu {
      rowCommands
    }
  }

  /// Clicking anywhere in the rule's three columns opens the editor, exactly as it did
  /// before the redesign. The cells other than the first are hidden from assistive
  /// technology so the row is read once, with the same label and value it always had.
  private func editCell<Content: View>(_ content: Content, isPrimary: Bool) -> some View {
    Button(action: onEdit) {
      content.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel(rule.settingsDisplayName)
    .accessibilityValue(
      L10n.format("%@, %@", rule.trigger.settingsSummary, rule.action.settingsSummary)
    )
    .accessibilityHint("Edit rule")
    .accessibilityHidden(!isPrimary)
  }

  /// Name above, trigger badges below: what the rule is called and what sets it off are
  /// the two things a row is scanned for. The summary's two badges read as one chip,
  /// because four equal columns leave the name cell too narrow for two pills side by side.
  private var ruleColumn: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(rule.settingsDisplayName)
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
        if rule.activatesWindowUnderPointer {
          Image(systemName: "cursorarrow.motionlines")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Activates the window under the pointer")
            .accessibilityLabel("Activates the window under the pointer")
        }
      }

      SettingsChip(
        TrackpadRuleSummary.triggerBadges(for: rule.trigger).joined(separator: " · ")
      )
      .help(rule.trigger.settingsSummary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var scopeColumn: some View {
    Text(rule.applicationScope.settingsSummary)
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(rule.applicationScope.settingsSummary)
  }

  private var actionColumn: some View {
    HStack(spacing: 5) {
      Image(systemName: rule.action.settingsSymbol)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 14)
      Text(rule.action.settingsSummary)
        .font(.caption)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var trailingControls: some View {
    HStack(spacing: 6) {
      // A rule whose action cannot run today looks identical to one that works, right
      // up until the gesture silently does nothing.
      if !availability.isAvailable {
        ActionUnavailableBadge(reason: availability.reason, settingsURL: availability.settingsURL)
      }

      Toggle(
        "Enabled",
        isOn: Binding(get: { rule.isEnabled }, set: onToggle)
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .accessibilityLabel(L10n.format("Enable %@", rule.settingsDisplayName))

      Menu {
        rowCommands
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Rule actions")
      .accessibilityLabel(L10n.format("Actions for %@", rule.settingsDisplayName))

      Button(action: onEdit) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.borderless)
      .help("Edit rule")
      .accessibilityLabel("Edit rule")
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  /// Reordering, duplication, and deletion stay reachable from both the row menu and a
  /// right-click, now that the row itself is the way into the editor. The menu's own
  /// groups supply the separators, so the pane never threads a divider by hand.
  @ViewBuilder
  private var rowCommands: some View {
    Section {
      Button(action: onEdit) {
        Label("Edit Rule", systemImage: "slider.horizontal.3")
      }
    }
    Section {
      Button(action: onMoveUp) {
        Label("Move up", systemImage: "chevron.up")
      }
      .disabled(index == 0)
      Button(action: onMoveDown) {
        Label("Move down", systemImage: "chevron.down")
      }
      .disabled(index == ruleCount - 1)
      Button(action: onDuplicate) {
        Label("Duplicate Rule", systemImage: "plus.square.on.square")
      }
    }
    Section {
      Button(role: .destructive, action: onDelete) {
        Label("Delete Gesture Rule", systemImage: "trash")
      }
    }
  }
}

/// The row-sized reading of a trigger: the family it belongs to and the one parameter that
/// distinguishes it from its siblings. The full sentence stays in `settingsSummary`.
enum TrackpadRuleSummary {
  static func triggerBadges(for trigger: TrackpadGestureTrigger) -> [String] {
    [trigger.kind.settingsTitle, keyParameter(for: trigger)]
  }

  private static func keyParameter(for trigger: TrackpadGestureTrigger) -> String {
    switch trigger.kind {
    case .contact:
      return L10n.format(
        "%d fingers · %@", trigger.fingerCount, trigger.contactGesture.settingsTitle)
    case .swipe:
      return L10n.format("%d fingers · %@", trigger.fingerCount, trigger.direction.settingsTitle)
    case .edgeEntrySwipe, .edgeContinuous:
      return L10n.format("%d fingers · %@", trigger.fingerCount, trigger.edge.badgeTitle)
    case .pinch:
      return L10n.format(
        "%d fingers · %@", trigger.fingerCount, trigger.pinchDirection.settingsTitle)
    case .tipTap:
      // Spacing is a tolerance, not part of what the user does, so a badge only spends a
      // word on it once the user has moved it off the default.
      guard trigger.tapSpacing != .normal else {
        return L10n.format("Finger %d taps", trigger.selectedFingerIndex + 1)
      }
      return L10n.format(
        "Finger %d taps · %@", trigger.selectedFingerIndex + 1, trigger.tapSpacing.settingsTitle)
    case .fingerSwipe:
      return L10n.format(
        "Finger %d · %@", trigger.selectedFingerIndex + 1, trigger.direction.settingsTitle)
    case .drawing:
      return trigger.drawingActivation.settingsTitle
    case .anchoredSlide:
      return L10n.format(
        "%1$d fingers · Finger %2$d %3$@",
        trigger.fingerCount,
        trigger.selectedFingerIndex + 1,
        trigger.slideAxis.badgeTitle
      )
    }
  }
}

struct TrackpadLabeledSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let valueText: String

  var body: some View {
    LabeledContent {
      HStack(spacing: 8) {
        Slider(value: $value, in: range, step: step)
          .frame(maxWidth: 260)
          .accessibilityLabel(title)
          .accessibilityValue(valueText)
        Text(valueText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(minWidth: 48, alignment: .trailing)
      }
    } label: {
      Text(title)
    }
  }
}

/// The design system's slider row, plus the `step` the pane's two sliders need: edge width
/// is stored in 1% steps and sensitivity in 0.05× steps, and both values are written
/// straight back to the recognizer, so a continuous slider would let a value persist that
/// the editor sheet and the recognizer never produce. `SettingsRowSlider` has no step
/// parameter, so the row is rebuilt here with its layout and its label/value readout.
private struct TrackpadSliderRow: View {
  let title: String
  let desc: String?
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let valueLabel: String
  var sliderWidth: CGFloat = 200

  var body: some View {
    SettingsRow(title, desc: desc) {
      HStack(spacing: 10) {
        Text(valueLabel)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(minWidth: 46, alignment: .trailing)
        Slider(value: $value, in: range, step: step)
          .frame(width: sliderWidth)
          .accessibilityLabel(title)
          .accessibilityValue(valueLabel)
      }
    }
  }
}

enum TrackpadUIFormat {
  static func percent(_ value: Double) -> String {
    String(format: "%.0f%%", locale: L10n.appLocale, value * 100)
  }

  static func multiplier(_ value: Double) -> String {
    String(format: "%.2f×", locale: L10n.appLocale, value)
  }

  static func seconds(_ value: Double) -> String {
    L10n.format("%.2f s", value)
  }

  static func decimal(_ value: Double) -> String {
    String(format: "%.1f", locale: L10n.appLocale, value)
  }
}

extension TrackpadGestureTrigger {
  var settingsSummary: String {
    switch kind {
    case .contact:
      let base = L10n.format("%d-finger %@", fingerCount, contactGesture.settingsTitle)
      return region == .anywhere
        ? base
        : L10n.format("%@ in %@", base, region.settingsTitle)
    case .swipe:
      return L10n.format("%d-finger %@ swipe", fingerCount, direction.settingsTitle)
    case .edgeEntrySwipe:
      return L10n.format("%d-finger %@ edge entry", fingerCount, edge.settingsTitle)
    case .pinch:
      return L10n.format("%d-finger pinch %@", fingerCount, pinchDirection.settingsTitle)
    case .tipTap:
      return L10n.format("Finger %d tip-tap", selectedFingerIndex + 1)
    case .fingerSwipe:
      return L10n.format("Finger %d swipe %@", selectedFingerIndex + 1, direction.settingsTitle)
    case .drawing:
      return L10n.format("Drawing · %@", drawingActivation.settingsTitle)
    case .edgeContinuous:
      return L10n.format("%d-finger continuous %@ edge", fingerCount, edge.settingsTitle)
    case .anchoredSlide:
      return L10n.format(
        "%1$d-finger anchored slide · Finger %2$d",
        fingerCount,
        selectedFingerIndex + 1
      )
    }
  }
}

extension TrackpadGestureAction {
  var settingsSummary: String {
    switch kind {
    case .systemControl:
      return systemControl.settingsTitle
    case .quickAction:
      return QuickActionReference(storageValue: quickActionStorageValue)?.displayTitle
        ?? L10n.string("Quick Action")
    case .keyboardShortcut:
      return keyboardShortcut.displayText
    case .mouse:
      return mouseAction.settingsTitle
    case .scroll:
      return L10n.format("Scroll %@", scrollDirection.settingsTitle)
    case .open:
      return target.isEmpty ? openTargetKind.settingsTitle : target
    case .appleScript:
      return L10n.string("AppleScript")
    case .window:
      return windowAction.settingsTitle
    case .none:
      return L10n.string("No action")
    }
  }

  /// The same symbols the action catalog uses, so a rule row and the Action Center never
  /// picture the same action differently.
  var settingsSymbol: String {
    switch kind {
    case .systemControl:
      return systemControl.actionSystemImage
    case .quickAction:
      switch QuickActionReference(storageValue: quickActionStorageValue) {
      case .builtIn(let actionID): return actionID.systemImage
      case .shortcut: return "command.square.fill"
      case nil: return "bolt.horizontal"
      }
    case .keyboardShortcut:
      return "keyboard"
    case .mouse:
      return "cursorarrow.click"
    case .scroll:
      return "arrow.up.and.down"
    case .open:
      return "arrow.up.forward.app"
    case .appleScript:
      return "applescript"
    case .window:
      return "macwindow"
    case .none:
      return "circle.dashed"
    }
  }
}

extension TrackpadApplicationScope {
  var settingsSummary: String {
    switch mode {
    case .allApplications:
      return L10n.string("All Applications")
    case .includedApplications:
      return applications.isEmpty
        ? L10n.string("No included applications")
        : L10n.format("Only %d applications", applications.count)
    case .excludedApplications:
      return applications.isEmpty
        ? L10n.string("All Applications")
        : L10n.format("All except %d applications", applications.count)
    }
  }
}

extension TrackpadModifier {
  var settingsTitle: String {
    switch self {
    case .function: return L10n.string("Function")
    case .shift: return L10n.string("Shift")
    case .control: return L10n.string("Control")
    case .option: return L10n.string("Option")
    case .command: return L10n.string("Command")
    }
  }

  var settingsSortIndex: Int {
    switch self {
    case .function: return 0
    case .control: return 1
    case .option: return 2
    case .shift: return 3
    case .command: return 4
    }
  }
}

extension TrackpadApplicationScopeMode {
  var settingsTitle: String {
    switch self {
    case .allApplications: return L10n.string("All Applications")
    case .includedApplications: return L10n.string("Only Selected Applications")
    case .excludedApplications: return L10n.string("All Except Selected Applications")
    }
  }
}

extension TrackpadDeviceScope {
  var settingsTitle: String {
    switch self {
    case .allSupported: return L10n.string("All Supported Trackpads")
    case .builtInOnly: return L10n.string("Built-in Trackpad Only")
    case .externalOnly: return L10n.string("External Trackpads Only")
    }
  }
}

extension TrackpadGestureKind {
  var settingsTitle: String {
    switch self {
    case .contact: return L10n.string("Contact")
    case .swipe: return L10n.string("Swipe")
    case .edgeEntrySwipe: return L10n.string("Edge-entry Swipe")
    case .pinch: return L10n.string("Pinch")
    case .tipTap: return L10n.string("Tip-tap")
    case .fingerSwipe: return L10n.string("Selected-finger Swipe")
    case .drawing: return L10n.string("Drawing")
    case .edgeContinuous: return L10n.string("Continuous Edge")
    case .anchoredSlide: return L10n.string("Anchored Slide")
    }
  }
}

extension TrackpadSlideAxis {
  var settingsTitle: String {
    switch self {
    case .vertical: return L10n.string("Vertical")
    case .horizontal: return L10n.string("Horizontal")
    }
  }

  /// A badge stands alone, where "Vertical" describes the axis rather than what the finger
  /// does along it.
  var badgeTitle: String {
    switch self {
    case .vertical: return L10n.string("up and down")
    case .horizontal: return L10n.string("left and right")
    }
  }
}

extension TrackpadContactGesture {
  var settingsTitle: String {
    switch self {
    case .tap: return L10n.string("Tap")
    case .doubleTap: return L10n.string("Double Tap")
    case .click: return L10n.string("Click")
    case .forceClick: return L10n.string("Force Click")
    }
  }
}

extension TrackpadDirection {
  var settingsTitle: String { actionTitle }
}

extension TrackpadEdge {
  var settingsTitle: String {
    switch self {
    case .left: return L10n.string("Left")
    case .right: return L10n.string("Right")
    case .top: return L10n.string("Top")
    case .bottom: return L10n.string("Bottom")
    }
  }

  /// Names the corridor the rule watches. `settingsTitle` sits beside an "Edge" label in
  /// the editor and can be read as a bare side, but a badge stands alone, where "Left"
  /// reads as the direction the fingers travel.
  var badgeTitle: String {
    switch self {
    case .left: return L10n.string("Left edge")
    case .right: return L10n.string("Right edge")
    case .top: return L10n.string("Top edge")
    case .bottom: return L10n.string("Bottom edge")
    }
  }
}

extension TrackpadGestureRegion {
  var settingsTitle: String {
    switch self {
    case .anywhere: return L10n.string("Anywhere")
    case .center: return L10n.string("Center")
    case .left: return L10n.string("Left Side")
    case .right: return L10n.string("Right Side")
    case .topLeft: return L10n.string("Top Left")
    case .topMiddle: return L10n.string("Top Middle")
    case .topRight: return L10n.string("Top Right")
    case .leftMiddle: return L10n.string("Left Middle")
    case .rightMiddle: return L10n.string("Right Middle")
    case .bottomLeft: return L10n.string("Bottom Left")
    case .bottomMiddle: return L10n.string("Bottom Middle")
    case .bottomRight: return L10n.string("Bottom Right")
    }
  }
}

extension TrackpadPinchDirection {
  var settingsTitle: String {
    switch self {
    case .inward: return L10n.string("Inward")
    case .outward: return L10n.string("Outward")
    }
  }
}

extension TrackpadTapSpacing {
  var settingsTitle: String {
    switch self {
    case .near: return L10n.string("Near")
    case .normal: return L10n.string("Any spacing")
    case .far: return L10n.string("Far")
    }
  }
}

extension TrackpadDrawingActivation {
  var settingsTitle: String {
    switch self {
    case .modifier: return L10n.string("Modifier + Finger")
    case .bottomThumb: return L10n.string("Bottom Thumb + Finger")
    case .holdTap: return L10n.string("Hold-tap Anchor")
    }
  }
}

extension TrackpadGestureActionKind {
  var settingsTitle: String {
    switch self {
    case .systemControl: return L10n.string("System Control")
    case .quickAction: return L10n.string("Quick Action")
    case .keyboardShortcut: return L10n.string("Keyboard Shortcut")
    case .mouse: return L10n.string("Mouse Click")
    case .scroll: return L10n.string("Scroll")
    case .open: return L10n.string("Open Target")
    case .appleScript: return L10n.string("AppleScript")
    case .window: return L10n.string("Window Placement")
    case .none: return L10n.string("No Action")
    }
  }
}

extension TrackpadSystemControl {
  var settingsTitle: String { actionTitle }
}

extension TrackpadMouseAction {
  var settingsTitle: String { actionTitle }
}

extension TrackpadOpenTargetKind {
  var settingsTitle: String {
    switch self {
    case .application: return L10n.string("Application")
    case .url: return L10n.string("URL")
    case .file: return L10n.string("File")
    case .folder: return L10n.string("Folder")
    }
  }
}

extension TrackpadWindowAction {
  var settingsTitle: String { actionTitle }
}
