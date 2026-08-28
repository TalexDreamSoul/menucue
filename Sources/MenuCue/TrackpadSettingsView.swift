import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TrackpadSettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @ObservedObject var model: AppModel
  @ObservedObject private var service: TrackpadGestureService

  @State private var expandedRuleID: UUID?
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
      service.retainLivePreview()
    }
    .onDisappear {
      service.releaseLivePreview()
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
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
            TrackpadRuleRow(
              rule: rule,
              index: index,
              ruleCount: settings.rules.count,
              isExpanded: expandedRuleID == rule.id,
              onToggle: { enabled in
                updateRule(rule.id) { $0.isEnabled = enabled }
              },
              onToggleExpanded: {
                withAnimation(motion.stateAnimation) {
                  expandedRuleID = expandedRuleID == rule.id ? nil : rule.id
                }
              },
              onDuplicate: { duplicateRule(rule) },
              onDelete: { deleteRule(rule.id) },
              onMoveUp: { moveRule(at: index, by: -1) },
              onMoveDown: { moveRule(at: index, by: 1) }
            )

            if expandedRuleID == rule.id {
              TrackpadRuleEditor(model: model, rule: rule)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .padding(.leading, 30)
                .transition(motion.revealTransition(edge: .top))
            }

            if index < settings.rules.count - 1 {
              Divider()
            }
          }
        }
        .animation(motion.stateAnimation, value: expandedRuleID)
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

  private func addRule() {
    let rule = TrackpadGestureRule(
      name: L10n.format("Gesture Rule %d", settings.rules.count + 1),
      trigger: TrackpadGestureTrigger(kind: .contact),
      action: TrackpadGestureAction(kind: .none)
    )
    model.updateTrackpadGestureSettings { $0.rules.append(rule) }
    expandedRuleID = rule.id
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
    expandedRuleID = copy.id
  }

  private func deleteRule(_ id: UUID) {
    model.updateTrackpadGestureSettings { settings in
      settings.rules.removeAll { $0.id == id }
    }
    if expandedRuleID == id { expandedRuleID = nil }
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
    expandedRuleID = nil
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
      expandedRuleID = nil
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

private enum TrackpadSettingsLayout {
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

private struct TrackpadRuleRow: View {
  let rule: TrackpadGestureRule
  let index: Int
  let ruleCount: Int
  let isExpanded: Bool
  let onToggle: (Bool) -> Void
  let onToggleExpanded: () -> Void
  let onDuplicate: () -> Void
  let onDelete: () -> Void
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      Toggle(
        "Enabled",
        isOn: Binding(get: { rule.isEnabled }, set: onToggle)
      )
      .labelsHidden()
      .accessibilityLabel(L10n.format("Enable %@", rule.settingsDisplayName))

      Button(action: onToggleExpanded) {
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
          Text(L10n.format("%@ → %@", rule.trigger.settingsSummary, rule.action.settingsSummary))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Text(rule.applicationScope.settingsSummary)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(rule.settingsDisplayName)
      .accessibilityValue(
        L10n.format("%@, %@", rule.trigger.settingsSummary, rule.action.settingsSummary)
      )
      .accessibilityHint(isExpanded ? "Collapse rule editor" : "Edit rule")

      Button(action: onMoveUp) {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0)
      .help("Move up")
      .accessibilityLabel("Move up")

      Button(action: onMoveDown) {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(index == ruleCount - 1)
      .help("Move down")
      .accessibilityLabel("Move down")

      Menu {
        Button(action: onDuplicate) {
          Label("Duplicate Rule", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
          Label("Delete Gesture Rule", systemImage: "trash")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Rule actions")
      .accessibilityLabel(L10n.format("Actions for %@", rule.settingsDisplayName))

      Button(action: onToggleExpanded) {
        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
      }
      .buttonStyle(.borderless)
      .help(isExpanded ? "Collapse rule editor" : "Edit rule")
      .accessibilityLabel(isExpanded ? "Collapse rule editor" : "Edit rule")
    }
    .padding(.vertical, 9)
    .opacity(rule.isEnabled ? 1 : 0.68)
  }
}

private struct TrackpadRuleEditor: View {
  @ObservedObject var model: AppModel
  let fallbackRule: TrackpadGestureRule

  init(model: AppModel, rule: TrackpadGestureRule) {
    self.model = model
    self.fallbackRule = rule
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Rule Details")
          .font(.subheadline.weight(.semibold))

        LabeledContent("Name") {
          TextField("Rule name", text: ruleBinding(\.name))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 330)
        }

        LabeledContent("Required modifiers") {
          TrackpadModifierSelector(selection: ruleBinding(\.requiredModifiers))
        }
      }

      Divider()
      TrackpadTriggerEditor(
        trigger: ruleBinding(\.trigger),
        edgeWidth: settings.edgeWidth,
        sensitivity: settings.sensitivity
      )

      Divider()
      TrackpadActionEditor(
        model: model,
        action: ruleBinding(\.action),
        triggerKind: currentRule.trigger.kind
      )

      Divider()
      TrackpadApplicationScopeEditor(scope: ruleBinding(\.applicationScope))

      LabeledContent("Trackpad devices") {
        Picker("Trackpad devices", selection: ruleBinding(\.deviceScope)) {
          ForEach(TrackpadDeviceScope.allCases) { scope in
            Text(scope.settingsTitle).tag(scope)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

      Toggle("Activate the window under the pointer before the action", isOn: ruleBinding(\.activatesWindowUnderPointer))
        .help("MenuCue fails closed when macOS cannot identify an activatable window.")

      VStack(alignment: .leading, spacing: 5) {
        Text("Note")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        TextEditor(text: ruleBinding(\.note))
          .font(.body)
          .frame(minHeight: 58, maxHeight: 88)
          .padding(4)
          .overlay {
            RoundedRectangle(cornerRadius: TrackpadSettingsLayout.controlCornerRadius)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
          }
          .accessibilityLabel("Rule note")
      }
    }
  }

  private var settings: TrackpadGestureSettings {
    model.settings.trackpadGestureSettings
  }

  private var currentRule: TrackpadGestureRule {
    settings.rules.first(where: { $0.id == fallbackRule.id }) ?? fallbackRule
  }

  private func ruleBinding<Value>(
    _ keyPath: WritableKeyPath<TrackpadGestureRule, Value>
  ) -> Binding<Value> {
    Binding(
      get: { currentRule[keyPath: keyPath] },
      set: { value in
        model.updateTrackpadGestureSettings { settings in
          guard let index = settings.rules.firstIndex(where: { $0.id == fallbackRule.id }) else {
            return
          }
          settings.rules[index][keyPath: keyPath] = value
        }
      }
    )
  }
}

private struct TrackpadTriggerEditor: View {
  @Binding var trigger: TrackpadGestureTrigger
  let edgeWidth: Double
  let sensitivity: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Trigger")
        .font(.subheadline.weight(.semibold))

      LabeledContent("Gesture family") {
        Picker("Gesture family", selection: kindBinding) {
          ForEach(TrackpadGestureKind.allCases) { kind in
            Text(kind.settingsTitle).tag(kind)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

      LabeledContent("Finger count") {
        Stepper(value: binding(\.fingerCount), in: fingerRange) {
          Text(L10n.format("%d fingers", trigger.fingerCount))
            .monospacedDigit()
        }
        .accessibilityLabel("Finger count")
        .accessibilityValue(L10n.format("%d fingers", trigger.fingerCount))
      }

      familyFields
    }
  }

  @ViewBuilder
  private var familyFields: some View {
    switch trigger.kind {
    case .contact:
      LabeledContent("Contact gesture") {
        Picker("Contact gesture", selection: binding(\.contactGesture)) {
          ForEach(TrackpadContactGesture.allCases) { gesture in
            Text(gesture.settingsTitle).tag(gesture)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

      LabeledContent("Region") {
        Picker("Region", selection: binding(\.region)) {
          ForEach(TrackpadGestureRegion.allCases) { region in
            Text(region.settingsTitle).tag(region)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

      durationSlider
      movementToleranceSlider

      if trigger.contactGesture == .click || trigger.contactGesture == .forceClick {
        Label(
          "Click and force-click use contact density and size. They remain inactive on hardware that cannot distinguish the configured gesture.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

    case .swipe:
      directionPicker
      distanceSlider(title: L10n.string("Minimum swipe distance"))
      velocitySlider
      durationSlider
      movementToleranceSlider

    case .edgeEntrySwipe:
      edgePicker
      directionPicker
      distanceSlider(title: L10n.string("Minimum entry distance"))
      velocitySlider
      durationSlider

    case .pinch:
      LabeledContent("Pinch direction") {
        Picker("Pinch direction", selection: binding(\.pinchDirection)) {
          ForEach(TrackpadPinchDirection.allCases) { direction in
            Text(direction.settingsTitle).tag(direction)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }
      distanceSlider(title: L10n.string("Minimum pinch change"))
      durationSlider
      movementToleranceSlider

    case .tipTap:
      selectedFingerStepper
      LabeledContent("Tap spacing") {
        Picker("Tap spacing", selection: binding(\.tapSpacing)) {
          ForEach(TrackpadTapSpacing.allCases) { spacing in
            Text(spacing.settingsTitle).tag(spacing)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }
      TrackpadLabeledSlider(
        title: L10n.string("Anchor hold time"),
        value: binding(\.holdDuration),
        range: 0.08...1.5,
        step: 0.01,
        valueText: TrackpadUIFormat.seconds(trigger.holdDuration)
      )
      durationSlider
      movementToleranceSlider
      Text("Finger positions are assigned left to right when the gesture arms.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("Tip-tap recognizes 2 to 4 fingers. A rule saved with 5 fingers never fires.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    case .fingerSwipe:
      selectedFingerStepper
      directionPicker
      distanceSlider(title: L10n.string("Minimum finger distance"))
      velocitySlider
      durationSlider
      movementToleranceSlider

    case .drawing:
      LabeledContent("Drawing activation") {
        Picker("Drawing activation", selection: binding(\.drawingActivation)) {
          ForEach(TrackpadDrawingActivation.allCases) { activation in
            Text(activation.settingsTitle).tag(activation)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

      if trigger.drawingActivation == .holdTap {
        TrackpadLabeledSlider(
          title: L10n.string("Hold time"),
          value: binding(\.holdDuration),
          range: 0.08...1.5,
          step: 0.01,
          valueText: TrackpadUIFormat.seconds(trigger.holdDuration)
        )
      }

      TrackpadDrawingRecorder(points: binding(\.drawingTemplate))

      TrackpadLabeledSlider(
        title: L10n.string("Minimum drawing match"),
        value: binding(\.minimumDrawingScore),
        range: 0.30...0.98,
        step: 0.01,
        valueText: TrackpadUIFormat.percent(trigger.minimumDrawingScore)
      )
      durationSlider
      movementToleranceSlider

      Text("A drawing trigger runs the selected action directly. It replaces the cross-module normal-mouse drawing bridge with an equivalent editable rule.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    case .edgeContinuous:
      edgePicker
      Toggle("Invert edge direction", isOn: binding(\.isInverted))
      distanceSlider(title: L10n.string("Distance per action step"))
      velocitySlider
      Label(
        L10n.format(
          "Uses the global edge width of %@ and sensitivity of %@.",
          TrackpadUIFormat.percent(edgeWidth),
          TrackpadUIFormat.multiplier(sensitivity)
        ),
        systemImage: "slider.horizontal.3"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var kindBinding: Binding<TrackpadGestureKind> {
    Binding(
      get: { trigger.kind },
      set: { kind in
        var next = trigger
        next.kind = kind
        let supported = TrackpadRecognizerRegistry.supportedFingerCounts(for: kind)
        next.fingerCount = min(supported.upperBound, max(supported.lowerBound, next.fingerCount))
        trigger = next.normalized
      }
    )
  }

  /// The recognizer decides what it can honour; the editor only offers it.
  private var fingerRange: ClosedRange<Int> {
    TrackpadRecognizerRegistry.supportedFingerCounts(for: trigger.kind)
  }

  private var selectedFingerStepper: some View {
    LabeledContent("Selected finger") {
      Stepper(value: binding(\.selectedFingerIndex), in: 0...max(0, trigger.fingerCount - 1)) {
        Text(L10n.format("Finger %d", trigger.selectedFingerIndex + 1))
          .monospacedDigit()
      }
      .accessibilityLabel("Selected finger")
      .accessibilityValue(L10n.format("Finger %d", trigger.selectedFingerIndex + 1))
    }
  }

  private var directionPicker: some View {
    LabeledContent("Direction") {
      Picker("Direction", selection: binding(\.direction)) {
        ForEach(TrackpadDirection.allCases) { direction in
          Text(direction.settingsTitle).tag(direction)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 260)
    }
  }

  private var edgePicker: some View {
    LabeledContent("Edge") {
      Picker("Edge", selection: binding(\.edge)) {
        ForEach(TrackpadEdge.allCases) { edge in
          Text(edge.settingsTitle).tag(edge)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 260)
    }
  }

  private var durationSlider: some View {
    TrackpadLabeledSlider(
      title: L10n.string("Maximum duration"),
      value: binding(\.maximumDuration),
      range: 0.12...3,
      step: 0.01,
      valueText: TrackpadUIFormat.seconds(trigger.maximumDuration)
    )
  }

  private var movementToleranceSlider: some View {
    TrackpadLabeledSlider(
      title: L10n.string("Movement tolerance"),
      value: binding(\.movementTolerance),
      range: 0.005...0.25,
      step: 0.005,
      valueText: TrackpadUIFormat.percent(trigger.movementTolerance)
    )
  }

  private var velocitySlider: some View {
    TrackpadLabeledSlider(
      title: L10n.string("Minimum velocity"),
      value: binding(\.minimumVelocity),
      range: 0...10,
      step: 0.1,
      valueText: TrackpadUIFormat.decimal(trigger.minimumVelocity)
    )
  }

  private func distanceSlider(title: String) -> some View {
    TrackpadLabeledSlider(
      title: title,
      value: binding(\.minimumDistance),
      range: 0.005...0.8,
      step: 0.005,
      valueText: TrackpadUIFormat.percent(trigger.minimumDistance)
    )
  }

  private func binding<Value>(
    _ keyPath: WritableKeyPath<TrackpadGestureTrigger, Value>
  ) -> Binding<Value> {
    Binding(
      get: { trigger[keyPath: keyPath] },
      set: { value in
        var next = trigger
        next[keyPath: keyPath] = value
        trigger = next.normalized
      }
    )
  }
}

private struct TrackpadActionEditor: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var quickActionService: QuickActionService
  @Binding var action: TrackpadGestureAction
  let triggerKind: TrackpadGestureKind

  @State private var runningApplications: [TrackpadApplicationIdentity] = []

  init(
    model: AppModel,
    action: Binding<TrackpadGestureAction>,
    triggerKind: TrackpadGestureKind
  ) {
    self.model = model
    self.quickActionService = model.quickActionService
    self._action = action
    self.triggerKind = triggerKind
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Action")
        .font(.subheadline.weight(.semibold))

      LabeledContent("Action family") {
        Picker("Action family", selection: kindBinding) {
          ForEach(TrackpadGestureActionKind.allCases) { kind in
            Text(kind.settingsTitle).tag(kind)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 280)
      }

      actionFields
      permissionGuidance

      if triggerKind == .drawing {
        Label(
          "The recorded drawing runs this action directly; no simulated normal-mouse drawing bridge is needed.",
          systemImage: "pencil.and.outline"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear(perform: refreshRunningApplications)
  }

  @ViewBuilder
  private var actionFields: some View {
    switch action.kind {
    case .systemControl:
      LabeledContent("System control") {
        Picker("System control", selection: binding(\.systemControl)) {
          ForEach(TrackpadSystemControl.allCases) { control in
            Text(control.settingsTitle).tag(control)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 280)
      }

    case .quickAction:
      if quickActionService.catalogItems.isEmpty {
        Text("No Quick Actions are currently available.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        LabeledContent("Quick Action") {
          Picker("Quick Action", selection: binding(\.quickActionStorageValue)) {
            ForEach(quickActionService.catalogItems) { item in
              Text(item.title).tag(item.reference.storageValue)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 320)
        }

        if let item = selectedQuickActionItem,
          let reason = item.state.availability.reason
        {
          Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

    case .keyboardShortcut:
      LabeledContent("Characters") {
        TextField("Optional display characters", text: binding(\.keyboardShortcut.characters))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 220)
      }
      LabeledContent("Key code") {
        TextField("Key code", text: keyCodeTextBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 100)
          .accessibilityValue(String(action.keyboardShortcut.keyCode))
      }
      LabeledContent("Shortcut modifiers") {
        TrackpadModifierSelector(selection: binding(\.keyboardShortcut.modifiers))
      }

    case .mouse:
      LabeledContent("Mouse action") {
        Picker("Mouse action", selection: binding(\.mouseAction)) {
          ForEach(TrackpadMouseAction.allCases) { mouseAction in
            Text(mouseAction.settingsTitle).tag(mouseAction)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

    case .scroll:
      LabeledContent("Scroll direction") {
        Picker("Scroll direction", selection: binding(\.scrollDirection)) {
          ForEach(TrackpadDirection.allCases) { direction in
            Text(direction.settingsTitle).tag(direction)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }
      Text("Scroll actions use a bounded step and do not add momentum.")
        .font(.caption)
        .foregroundStyle(.secondary)

    case .open:
      LabeledContent("Target type") {
        Picker("Target type", selection: binding(\.openTargetKind)) {
          ForEach(TrackpadOpenTargetKind.allCases) { kind in
            Text(kind.settingsTitle).tag(kind)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

      LabeledContent(openTargetLabel) {
        HStack(spacing: 8) {
          TextField(openTargetPlaceholder, text: binding(\.target))
            .textFieldStyle(.roundedBorder)
          openTargetChooser
        }
        .frame(maxWidth: 380)
      }

    case .appleScript:
      VStack(alignment: .leading, spacing: 5) {
        Text("AppleScript")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        TextEditor(text: binding(\.appleScript))
          .font(.body.monospaced())
          .frame(minHeight: 100, maxHeight: 170)
          .padding(4)
          .overlay {
            RoundedRectangle(cornerRadius: TrackpadSettingsLayout.controlCornerRadius)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
          }
          .accessibilityLabel("AppleScript source")
      }

    case .window:
      LabeledContent("Window placement") {
        Picker("Window placement", selection: binding(\.windowAction)) {
          ForEach(TrackpadWindowAction.allCases) { windowAction in
            Text(windowAction.settingsTitle).tag(windowAction)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 280)
      }

    case .none:
      Text("This rule recognizes the gesture without running an action.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var permissionGuidance: some View {
    switch action.kind {
    case .keyboardShortcut, .mouse, .scroll, .window:
      VStack(alignment: .leading, spacing: 7) {
        Label(
          "This action requires Accessibility when it runs. Touch observation remains independent and pass-through.",
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Button("Open System Settings") {
          model.trackpadGestureService.openAccessibilitySettings()
        }
      }

    case .appleScript:
      Label(
        "macOS may request Automation permission only when this script controls another app.",
        systemImage: "lock.shield"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

    case .systemControl:
      Label(systemControlPermissionText, systemImage: "checkmark.shield")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    case .quickAction:
      if let item = selectedQuickActionItem,
        !item.state.availability.isAvailable,
        let settingsURL = item.state.availability.settingsURL
      {
        Button("Open System Settings") {
          WorkspaceOpener.openSettings(settingsURL)
        }
      }

    case .open:
      Label("Opening an app, URL, file, or folder does not require Accessibility.", systemImage: "checkmark.shield")
        .font(.caption)
        .foregroundStyle(.secondary)

    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var openTargetChooser: some View {
    switch action.openTargetKind {
    case .application:
      Menu {
        if runningApplications.isEmpty {
          Button("No running apps available") {}
            .disabled(true)
        } else {
          ForEach(runningApplications) { application in
            Button(application.name) {
              var next = action
              next.target = application.bundleIdentifier
              action = next
            }
          }
        }
        Divider()
        Button("Refresh Running Apps", action: refreshRunningApplications)
      } label: {
        Image(systemName: "plus.app")
      }
      .menuStyle(.borderlessButton)
      .help("Choose a running app")
      .accessibilityLabel("Choose a running app")

    case .file:
      Button("Choose…") { chooseFileSystemTarget(directory: false) }

    case .folder:
      Button("Choose…") { chooseFileSystemTarget(directory: true) }

    case .url:
      EmptyView()
    }
  }

  private var kindBinding: Binding<TrackpadGestureActionKind> {
    Binding(
      get: { action.kind },
      set: { kind in
        var next = action
        next.kind = kind
        if kind == .quickAction,
          next.quickActionStorageValue.isEmpty,
          let first = quickActionService.catalogItems.first
        {
          next.quickActionStorageValue = first.reference.storageValue
        }
        action = next
      }
    )
  }

  private var keyCodeTextBinding: Binding<String> {
    Binding(
      get: { String(action.keyboardShortcut.keyCode) },
      set: { value in
        guard let code = UInt16(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
          return
        }
        var next = action
        next.keyboardShortcut.keyCode = code
        action = next
      }
    )
  }

  private var selectedQuickActionItem: QuickActionItem? {
    guard let reference = QuickActionReference(storageValue: action.quickActionStorageValue) else {
      return nil
    }
    return quickActionService.item(for: reference)
  }

  private var openTargetLabel: LocalizedStringKey {
    switch action.openTargetKind {
    case .application: return "Bundle identifier"
    case .url: return "URL"
    case .file: return "File path"
    case .folder: return "Folder path"
    }
  }

  private var openTargetPlaceholder: LocalizedStringKey {
    switch action.openTargetKind {
    case .application: return "com.example.app"
    case .url: return "https://example.com"
    case .file: return "/path/to/file"
    case .folder: return "/path/to/folder"
    }
  }

  private var systemControlPermissionText: String {
    switch action.systemControl {
    case .brightnessUp, .brightnessDown, .continuousBrightness:
      return L10n.string("Supported display brightness control does not require Accessibility and fails closed on unsupported displays.")
    default:
      return L10n.string("Volume control does not require Accessibility and publishes only observed system values.")
    }
  }

  private func binding<Value>(
    _ keyPath: WritableKeyPath<TrackpadGestureAction, Value>
  ) -> Binding<Value> {
    Binding(
      get: { action[keyPath: keyPath] },
      set: { value in
        var next = action
        next[keyPath: keyPath] = value
        action = next
      }
    )
  }

  private func chooseFileSystemTarget(directory: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !directory
    panel.canChooseDirectories = directory
    panel.allowsMultipleSelection = false
    panel.title = L10n.string(directory ? "Choose Folder" : "Choose File")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var next = action
    next.target = url.path
    action = next
  }

  private func refreshRunningApplications() {
    runningApplications = TrackpadApplicationCatalog.runningApplications()
  }
}

private struct TrackpadApplicationScopeEditor: View {
  @Binding var scope: TrackpadApplicationScope
  @State private var manualBundleIdentifier = ""
  @State private var runningApplications: [TrackpadApplicationIdentity] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Applications")
        .font(.subheadline.weight(.semibold))

      LabeledContent("Run this rule in") {
        Picker("Run this rule in", selection: modeBinding) {
          ForEach(TrackpadApplicationScopeMode.allCases) { mode in
            Text(mode.settingsTitle).tag(mode)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 300)
      }

      if scope.mode != .allApplications {
        if scope.applications.isEmpty {
          Text(emptyScopeMessage)
            .font(.caption)
            .foregroundStyle(scope.mode == .includedApplications ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(scope.applications) { application in
              HStack(spacing: 8) {
                Image(systemName: "app")
                  .foregroundStyle(.secondary)
                  .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                  Text(application.name)
                    .lineLimit(1)
                  Text(application.bundleIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(role: .destructive) {
                  removeApplication(application.id)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove application")
                .accessibilityLabel(L10n.format("Remove %@", application.name))
              }
            }
          }
        }

        HStack(spacing: 8) {
          TextField("Bundle identifier", text: $manualBundleIdentifier)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addManualApplication)
          Button("Add", action: addManualApplication)
            .disabled(
              manualBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

          Menu {
            if runningApplications.isEmpty {
              Button("No running apps available") {}
                .disabled(true)
            } else {
              ForEach(runningApplications) { application in
                Button(application.name) { addApplication(application) }
              }
            }
            Divider()
            Button("Refresh Running Apps", action: refreshRunningApplications)
          } label: {
            Label("Running Apps", systemImage: "plus.app")
          }
          .menuStyle(.borderlessButton)
        }
      }
    }
    .onAppear(perform: refreshRunningApplications)
  }

  private var modeBinding: Binding<TrackpadApplicationScopeMode> {
    Binding(
      get: { scope.mode },
      set: { mode in
        var next = scope
        next.mode = mode
        if mode == .allApplications { next.applications = [] }
        scope = next.normalized
      }
    )
  }

  private var emptyScopeMessage: String {
    switch scope.mode {
    case .includedApplications:
      return L10n.string("No apps are included, so this rule will not run until one is added.")
    case .excludedApplications:
      return L10n.string("No apps are excluded; this currently behaves like All Applications.")
    case .allApplications:
      return ""
    }
  }

  private func addManualApplication() {
    let identifier = manualBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { return }
    addApplication(
      TrackpadApplicationIdentity(bundleIdentifier: identifier, name: identifier)
    )
    manualBundleIdentifier = ""
  }

  private func addApplication(_ application: TrackpadApplicationIdentity) {
    var next = scope
    guard !next.applications.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) else {
      return
    }
    next.applications.append(application)
    scope = next.normalized
  }

  private func removeApplication(_ id: String) {
    var next = scope
    next.applications.removeAll { $0.id == id }
    scope = next.normalized
  }

  private func refreshRunningApplications() {
    runningApplications = TrackpadApplicationCatalog.runningApplications()
  }
}

private enum TrackpadApplicationCatalog {
  static func runningApplications() -> [TrackpadApplicationIdentity] {
    var applicationsByID: [String: TrackpadApplicationIdentity] = [:]
    for application in NSWorkspace.shared.runningApplications {
      guard let bundleIdentifier = application.bundleIdentifier,
        !bundleIdentifier.isEmpty
      else {
        continue
      }
      let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
      applicationsByID[bundleIdentifier] = TrackpadApplicationIdentity(
        bundleIdentifier: bundleIdentifier,
        name: (name?.isEmpty == false ? name : nil) ?? bundleIdentifier,
        path: application.bundleURL?.path
      )
    }
    return applicationsByID.values.sorted {
      let comparison = $0.name.localizedStandardCompare($1.name)
      return comparison == .orderedSame
        ? $0.bundleIdentifier < $1.bundleIdentifier
        : comparison == .orderedAscending
    }
  }
}

private struct TrackpadModifierSelector: View {
  @Binding var selection: Set<TrackpadModifier>

  var body: some View {
    HStack(spacing: 10) {
      ForEach(TrackpadModifier.allCases) { modifier in
        Toggle(
          modifier.symbol,
          isOn: Binding(
            get: { selection.contains(modifier) },
            set: { selected in
              if selected {
                selection.insert(modifier)
              } else {
                selection.remove(modifier)
              }
            }
          )
        )
        .toggleStyle(.checkbox)
        .help(modifier.settingsTitle)
        .accessibilityLabel(modifier.settingsTitle)
      }
    }
  }
}

private struct TrackpadDrawingRecorder: View {
  @Binding var points: [TrackpadPoint]
  @State private var draft: [TrackpadPoint]
  @State private var isRecording = false

  init(points: Binding<[TrackpadPoint]>) {
    self._points = points
    self._draft = State(initialValue: points.wrappedValue)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Drawing Template")
            .font(.caption.weight(.medium))
          Text("Draw one continuous path inside the trackpad surface.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(L10n.format("%d points", draft.count))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Button("Clear") {
          draft = []
          points = []
        }
        .disabled(draft.isEmpty)
      }

      GeometryReader { geometry in
        Canvas { context, size in
          let background = Path(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerRadius: 12
          )
          context.fill(background, with: .color(Color(nsColor: .controlBackgroundColor)))
          context.stroke(
            background,
            with: .color(Color(nsColor: .separatorColor)),
            lineWidth: 1
          )

          guard let first = draft.first else { return }
          var path = Path()
          path.move(to: canvasPoint(first, size: size))
          for point in draft.dropFirst() {
            path.addLine(to: canvasPoint(point, size: size))
          }
          context.stroke(
            path,
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
          )
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              if !isRecording {
                draft = []
                isRecording = true
              }
              append(location: value.location, size: geometry.size)
            }
            .onEnded { value in
              append(location: value.location, size: geometry.size)
              isRecording = false
              points = Array(draft.prefix(TrackpadSettingsLayout.maximumDrawingPoints))
            }
        )
      }
      .frame(height: TrackpadSettingsLayout.drawingHeight)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Drawing recorder")
      .accessibilityValue(L10n.format("%d points", draft.count))
      .accessibilityHint("Use a pointer to record a normalized single-stroke gesture, or import a rule set.")
    }
    .onChange(of: points) { updatedPoints in
      guard !isRecording, updatedPoints != draft else { return }
      draft = updatedPoints
    }
  }

  private func append(location: CGPoint, size: CGSize) {
    guard size.width > 0, size.height > 0,
      draft.count < TrackpadSettingsLayout.maximumDrawingPoints
    else {
      return
    }
    let point = TrackpadPoint(
      x: Double(location.x / size.width),
      y: Double(1 - location.y / size.height)
    ).clamped
    guard draft.last?.distance(to: point) ?? .infinity
      >= TrackpadSettingsLayout.minimumDrawingPointDistance
    else {
      return
    }
    draft.append(point)
  }

  private func canvasPoint(_ point: TrackpadPoint, size: CGSize) -> CGPoint {
    CGPoint(
      x: CGFloat(point.clamped.x) * size.width,
      y: CGFloat(1 - point.clamped.y) * size.height
    )
  }
}

private struct TrackpadLabeledSlider: View {
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

private enum TrackpadUIFormat {
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

private extension TrackpadGestureRule {
  var settingsDisplayName: String {
    let presetNames = Set(TrackpadGestureSettings.presetRules.map(\.name))
    return presetNames.contains(name) ? L10n.string(name) : name
  }
}

private extension TrackpadGestureTrigger {
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
    }
  }
}

private extension TrackpadGestureAction {
  var settingsSummary: String {
    switch kind {
    case .systemControl:
      return systemControl.settingsTitle
    case .quickAction:
      return QuickActionReference(storageValue: quickActionStorageValue)?.displayTitle
        ?? L10n.string("Quick Action")
    case .keyboardShortcut:
      let key = keyboardShortcut.characters.isEmpty
        ? L10n.format("key code %d", keyboardShortcut.keyCode)
        : keyboardShortcut.characters
      let modifiers = keyboardShortcut.modifiers
        .sorted { $0.settingsSortIndex < $1.settingsSortIndex }
        .map(\.symbol)
        .joined()
      return modifiers + key
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
}

private extension TrackpadApplicationScope {
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

private extension TrackpadModifier {
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

private extension TrackpadApplicationScopeMode {
  var settingsTitle: String {
    switch self {
    case .allApplications: return L10n.string("All Applications")
    case .includedApplications: return L10n.string("Only Selected Applications")
    case .excludedApplications: return L10n.string("All Except Selected Applications")
    }
  }
}

private extension TrackpadDeviceScope {
  var settingsTitle: String {
    switch self {
    case .allSupported: return L10n.string("All Supported Trackpads")
    case .builtInOnly: return L10n.string("Built-in Trackpad Only")
    case .externalOnly: return L10n.string("External Trackpads Only")
    }
  }
}

private extension TrackpadGestureKind {
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
    }
  }
}

private extension TrackpadContactGesture {
  var settingsTitle: String {
    switch self {
    case .tap: return L10n.string("Tap")
    case .doubleTap: return L10n.string("Double Tap")
    case .click: return L10n.string("Click")
    case .forceClick: return L10n.string("Force Click")
    }
  }
}

private extension TrackpadDirection {
  var settingsTitle: String { actionTitle }
}

private extension TrackpadEdge {
  var settingsTitle: String {
    switch self {
    case .left: return L10n.string("Left")
    case .right: return L10n.string("Right")
    case .top: return L10n.string("Top")
    case .bottom: return L10n.string("Bottom")
    }
  }
}

private extension TrackpadGestureRegion {
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

private extension TrackpadPinchDirection {
  var settingsTitle: String {
    switch self {
    case .inward: return L10n.string("Inward")
    case .outward: return L10n.string("Outward")
    }
  }
}

private extension TrackpadTapSpacing {
  var settingsTitle: String {
    switch self {
    case .near: return L10n.string("Near")
    case .normal: return L10n.string("Normal")
    case .far: return L10n.string("Far")
    }
  }
}

private extension TrackpadDrawingActivation {
  var settingsTitle: String {
    switch self {
    case .modifier: return L10n.string("Modifier + Finger")
    case .bottomThumb: return L10n.string("Bottom Thumb + Finger")
    case .holdTap: return L10n.string("Hold-tap Anchor")
    }
  }
}

private extension TrackpadGestureActionKind {
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

private extension TrackpadSystemControl {
  var settingsTitle: String { actionTitle }
}

private extension TrackpadMouseAction {
  var settingsTitle: String { actionTitle }
}

private extension TrackpadOpenTargetKind {
  var settingsTitle: String {
    switch self {
    case .application: return L10n.string("Application")
    case .url: return L10n.string("URL")
    case .file: return L10n.string("File")
    case .folder: return L10n.string("Folder")
    }
  }
}

private extension TrackpadWindowAction {
  var settingsTitle: String { actionTitle }
}
