import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TrackpadSettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  @ObservedObject private var service: TrackpadGestureService
  /// The live preview publishes touches at 30 Hz, so it must stop when the settings
  /// window closes. Closing that window only orders it out, and `onDisappear` covers
  /// leaving the pane but not that.
  @StateObject private var livePreviewGate = VisibilityGate()

  @State private var editingTarget: TrackpadRuleSheetTarget?
  @State private var feedbackMessage: String?
  @State private var feedbackIsError = false
  @State private var showsResetConfirmation = false

  init(model: AppModel) {
    self.model = model
    self.service = model.trackpadGestureService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      runtimeSection

      if settings.isEnabled {
        Divider()
        livePreviewSection
      }

      Divider()
      feedbackAndEdgeSection
      Divider()
      rulesSection
      Divider()
      managementSection
    }
    .onAppear {
      model.quickActionService.refreshAll()
      livePreviewGate.connect(
        to: router.visibility(of: .settings),
        onStart: { service.retainLivePreview() },
        onStop: { service.releaseLivePreview() }
      )
    }
    .onDisappear {
      livePreviewGate.disconnect()
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

  private var runtimeSection: some View {
    SettingsGroup(spacing: 12) {
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

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: runtimeStatusSymbol)
          .font(.title3)
          .foregroundStyle(runtimeStatusColor)
          .frame(width: 24)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(runtimeStatusTitle)
              .font(.subheadline.weight(.semibold))
            if case .starting = service.status {
              MotionAwareProgressIndicator(scale: 0.8)
            }
          }
          Text(runtimeStatusDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 10)
        Button("Retry") {
          service.retry()
        }
        .disabled(!settings.isEnabled || isRuntimeStarting)
        .help("Retry trackpad detection and optional capabilities")
        .accessibilityHint("Rechecks trackpad support without changing your rules.")
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(runtimeAccessibilityLabel)

      Label(
        "Raw touch observation remains pass-through. MenuCue consumes native input only for an explicitly enabled click rule or while a configured continuous edge gesture is active. Input suppression requires Accessibility; volume and supported display brightness do not.",
        systemImage: "hand.raised"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Toggle(
          "Suppress the left click after a multi-finger tap",
          isOn: clickSuppressionBinding
        )
        .help("Only the matching click immediately after a recognized multi-finger tap is consumed.")

        Text(
          "Native scrolling is suppressed while an enabled continuous edge rule owns the trackpad. Click suppression remains optional."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if settings.suppressesClickAfterMultiFingerTap {
          clickSuppressionStatus
        }
        if suppressesNativeScrolling {
          edgeScrollSuppressionStatus
        }
      }
    }
  }

  @ViewBuilder
  private var clickSuppressionStatus: some View {
    switch service.clickSuppressionStatus {
    case .disabled:
      Label(
        settings.isEnabled ? "Click suppression is starting" : "Click suppression starts with the module",
        systemImage: "pause.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

    case .active:
      Label("Click suppression is active", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)

    case .requiresAccessibility:
      VStack(alignment: .leading, spacing: 8) {
        Label(
          "Accessibility permission is required for click suppression.",
          systemImage: "exclamationmark.shield.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        if !suppressesNativeScrolling {
          suppressionPermissionButtons
        }
      }

    case .unavailable(let reason):
      VStack(alignment: .leading, spacing: 8) {
        Label(L10n.string(reason), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        if !suppressesNativeScrolling {
          HStack(spacing: 8) {
            Button("Retry") { service.retry() }
              .disabled(!settings.isEnabled)
            Button("Open System Settings") { service.openAccessibilitySettings() }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var edgeScrollSuppressionStatus: some View {
    switch service.edgeScrollSuppressionStatus {
    case .disabled:
      Label(
        settings.isEnabled
          ? "Edge scroll suppression is starting"
          : "Edge scroll suppression starts with the module",
        systemImage: "pause.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

    case .active:
      Label(
        "Native scrolling is suppressed during matching edge gestures",
        systemImage: "checkmark.circle.fill"
      )
      .font(.caption)
      .foregroundStyle(.green)

    case .requiresAccessibility:
      VStack(alignment: .leading, spacing: 8) {
        Label(
          "Accessibility permission is required to suppress native scrolling during edge gestures.",
          systemImage: "exclamationmark.shield.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        suppressionPermissionButtons
      }

    case .unavailable(let reason):
      VStack(alignment: .leading, spacing: 8) {
        Label(L10n.string(reason), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button("Retry") { service.retry() }
            .disabled(!settings.isEnabled)
          Button("Open System Settings") { service.openAccessibilitySettings() }
        }
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

  private var livePreviewSection: some View {
    SettingsGroup(spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Live Touch Preview")
            .font(.headline)
          Text("Contact dots are published at a bounded rate of up to 30 Hz.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(L10n.format("%d contacts", activeContactCount))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      TrackpadLiveContactPreview(contacts: service.liveContacts)

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Last recognized")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(lastRecognitionTitle)
          .font(.caption.weight(.medium))
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var feedbackAndEdgeSection: some View {
    SettingsGroup(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Feedback and Edge Control")
          .font(.headline)
        Text("Feedback is local to this Mac. Edge values apply to every edge-based rule.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Toggle("Haptic feedback", isOn: settingBinding(\.hapticFeedbackEnabled))
      Toggle("Feedback HUD", isOn: settingBinding(\.feedbackHUDEnabled))

      TrackpadLabeledSlider(
        title: L10n.string("Edge width"),
        value: settingBinding(\.edgeWidth),
        range: 0.03...0.20,
        step: 0.01,
        valueText: TrackpadUIFormat.percent(settings.edgeWidth)
      )

      TrackpadLabeledSlider(
        title: L10n.string("Sensitivity"),
        value: settingBinding(\.sensitivity),
        range: 0.25...4,
        step: 0.05,
        valueText: TrackpadUIFormat.multiplier(settings.sensitivity)
      )
    }
  }

  private var rulesSection: some View {
    SettingsGroup(spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Gesture Rules")
            .font(.headline)
          Text("Rules with a specific app scope run before global rules; ties follow the list order.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button(action: addRule) {
          Label("Add Rule", systemImage: "plus")
        }
      }

      if settings.rules.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "hand.tap")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("No Gesture Rules")
            .font(.headline)
          Text("Add a rule to connect a touch gesture to a system or app action.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          Button("Add Gesture Rule", action: addRule)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        // Resolved once for the whole list: every rule's answer depends on the same
        // permission state, and this pane redraws with live touch input.
        let availabilities = service.availabilities(for: settings.rules.map(\.action))
        VStack(alignment: .leading, spacing: 0) {
          TrackpadRuleTableHeader()

          ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
            Divider()

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
  }

  private var managementSection: some View {
    SettingsGroup(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Rule Set")
          .font(.headline)
        Text("Import and export use a versioned local JSON file. Invalid neighbors are normalized independently.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Button(action: importRuleSet) {
          Label("Import JSON", systemImage: "square.and.arrow.down")
        }
        Button(action: exportRuleSet) {
          Label("Export JSON", systemImage: "square.and.arrow.up")
        }
        Spacer()
        Button("Reset Presets", role: .destructive) {
          showsResetConfirmation = true
        }
      }

      if let feedbackMessage {
        Label(
          feedbackMessage,
          systemImage: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(feedbackIsError ? Color.red : Color.green)
        .fixedSize(horizontal: false, vertical: true)
        .transition(motion.revealTransition(edge: .top))
      }
    }
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

enum TrackpadSettingsLayout {
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

/// What each rule row's columns mean. The rows carry no labels of their own, so a table
/// this wide needs the header to stay readable.
private struct TrackpadRuleTableHeader: View {
  var body: some View {
    HStack(spacing: TrackpadRuleTableLayout.columnSpacing) {
      Text("Rule")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Action")
        .frame(width: TrackpadRuleTableLayout.actionWidth, alignment: .leading)
      Text("Scope")
        .frame(width: TrackpadRuleTableLayout.scopeWidth, alignment: .leading)
      Color.clear
        .frame(width: TrackpadRuleTableLayout.controlsWidth, height: 1)
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.leading, TrackpadRuleTableLayout.toggleWidth + TrackpadRuleTableLayout.columnSpacing)
    .padding(.bottom, 6)
    .accessibilityHidden(true)
  }
}

/// The rule column stays elastic and everything else is fixed, because the pane is only
/// 560pt wide: a name that truncates is a worse row than a scope that does.
private enum TrackpadRuleTableLayout {
  static let toggleWidth: CGFloat = 32
  static let actionWidth: CGFloat = 132
  static let scopeWidth: CGFloat = 84
  static let controlsWidth: CGFloat = 58
  static let columnSpacing: CGFloat = 9
}

/// One row of the rule table. Everything but the enable switch and the row menu opens the
/// editor sheet: the row states what the rule does, and the sheet is where it is changed.
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
    HStack(alignment: .center, spacing: TrackpadRuleTableLayout.columnSpacing) {
      Toggle(
        "Enabled",
        isOn: Binding(get: { rule.isEnabled }, set: onToggle)
      )
      .labelsHidden()
      .frame(width: TrackpadRuleTableLayout.toggleWidth, alignment: .leading)
      .accessibilityLabel(L10n.format("Enable %@", rule.settingsDisplayName))

      Button(action: onEdit) {
        HStack(spacing: TrackpadRuleTableLayout.columnSpacing) {
          ruleColumn
          actionColumn
          scopeColumn
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(rule.settingsDisplayName)
      .accessibilityValue(
        L10n.format("%@, %@", rule.trigger.settingsSummary, rule.action.settingsSummary)
      )
      .accessibilityHint("Edit rule")

      trailingControls
    }
    .padding(.vertical, 8)
    .opacity(rule.isEnabled ? 1 : 0.68)
    .contextMenu {
      rowCommands
    }
  }

  /// Name above, trigger badges below: what the rule is called and what sets it off are
  /// the two things a row is scanned for.
  private var ruleColumn: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(rule.settingsDisplayName)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        if rule.activatesWindowUnderPointer {
          Image(systemName: "cursorarrow.motionlines")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Activates the window under the pointer")
            .accessibilityLabel("Activates the window under the pointer")
        }
      }

      HStack(spacing: 4) {
        ForEach(TrackpadRuleSummary.triggerBadges(for: rule.trigger), id: \.self) { badge in
          Text(badge)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
      }
      .help(rule.trigger.settingsSummary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var scopeColumn: some View {
    Text(rule.applicationScope.settingsSummary)
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(2)
      .frame(width: TrackpadRuleTableLayout.scopeWidth, alignment: .leading)
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
    .frame(width: TrackpadRuleTableLayout.actionWidth, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var trailingControls: some View {
    HStack(spacing: 6) {
      // A rule whose action cannot run today looks identical to one that works, right
      // up until the gesture silently does nothing.
      if !availability.isAvailable {
        ActionUnavailableBadge(reason: availability.reason, settingsURL: availability.settingsURL)
      }

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
    .frame(width: TrackpadRuleTableLayout.controlsWidth, alignment: .trailing)
  }

  /// Reordering, duplication, and deletion stay reachable from both the row menu and a
  /// right-click, now that the row itself is the way into the editor.
  @ViewBuilder
  private var rowCommands: some View {
    Button(action: onEdit) {
      Label("Edit Rule", systemImage: "slider.horizontal.3")
    }
    Divider()
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
    Divider()
    Button(role: .destructive, action: onDelete) {
      Label("Delete Gesture Rule", systemImage: "trash")
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
    case .normal: return L10n.string("Normal")
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
