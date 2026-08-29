import AppKit
import Foundation
import SwiftUI

/// Placing an edited rule back into the list. Editing works on a draft copy, so this is
/// the only step that turns one into the other: the rule replaces its predecessor when the
/// list still holds its id, and joins the end when it does not.
enum TrackpadRuleDraft {
  static func upserting(
    _ rule: TrackpadGestureRule,
    into rules: [TrackpadGestureRule]
  ) -> [TrackpadGestureRule] {
    var result = rules
    if let index = result.firstIndex(where: { $0.id == rule.id }) {
      result[index] = rule
    } else {
      result.append(rule)
    }
    return result
  }
}

/// Which advanced groups the editor opens the moment it appears.
///
/// Every folded field has a working default, which is what makes folding it safe. A rule
/// that already moved one off its default is a different matter: hiding a value the user
/// chose would make a tuned rule read exactly like an untouched one, so its section opens.
enum TrackpadRuleAdvancedDisclosure {
  static func expandsTrigger(for rule: TrackpadGestureRule) -> Bool {
    guard rule.requiredModifiers.isEmpty else { return true }
    let defaults = TrackpadGestureTrigger(kind: rule.trigger.kind)
    return foldedTuning(for: rule.trigger.kind).contains { field in
      field.differs(rule.trigger, from: defaults)
    }
  }

  static func expandsScope(for rule: TrackpadGestureRule) -> Bool {
    rule.deviceScope != .allSupported
      || rule.activatesWindowUnderPointer
      || !rule.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// What each family folds away, mirroring `TrackpadTriggerEditor.familyTuningFields`.
  /// A family is only asked about the fields it actually shows: a swipe distance stored on
  /// a contact rule is not a setting that rule has, so it is not one worth opening for.
  static func foldedTuning(for kind: TrackpadGestureKind) -> [TuningField] {
    switch kind {
    case .contact:
      return [.maximumDuration, .movementTolerance]
    case .swipe, .fingerSwipe:
      return [.minimumDistance, .minimumVelocity, .maximumDuration, .movementTolerance]
    case .edgeEntrySwipe:
      return [.minimumDistance, .minimumVelocity, .maximumDuration]
    case .pinch:
      return [.minimumDistance, .maximumDuration, .movementTolerance]
    case .tipTap:
      return [.tapSpacing, .holdDuration, .maximumDuration, .movementTolerance]
    case .drawing:
      return [
        .drawingActivation, .holdDuration, .minimumDrawingScore, .maximumDuration,
        .movementTolerance,
      ]
    case .edgeContinuous:
      return [.minimumDistance, .minimumVelocity]
    case .anchoredSlide:
      return [.minimumDistance, .movementTolerance]
    }
  }

  enum TuningField {
    case holdDuration
    case maximumDuration
    case movementTolerance
    case minimumDistance
    case minimumVelocity
    case minimumDrawingScore
    case tapSpacing
    case drawingActivation

    func differs(
      _ trigger: TrackpadGestureTrigger,
      from defaults: TrackpadGestureTrigger
    ) -> Bool {
      switch self {
      case .holdDuration: return trigger.holdDuration != defaults.holdDuration
      case .maximumDuration: return trigger.maximumDuration != defaults.maximumDuration
      case .movementTolerance: return trigger.movementTolerance != defaults.movementTolerance
      case .minimumDistance: return trigger.minimumDistance != defaults.minimumDistance
      case .minimumVelocity: return trigger.minimumVelocity != defaults.minimumVelocity
      case .minimumDrawingScore: return trigger.minimumDrawingScore != defaults.minimumDrawingScore
      case .tapSpacing: return trigger.tapSpacing != defaults.tapSpacing
      case .drawingActivation: return trigger.drawingActivation != defaults.drawingActivation
      }
    }
  }
}

/// The whole of one rule, edited apart from the rule list. Every field writes to `draft`
/// and nothing reaches settings until Save, so Cancel is genuinely free — which the
/// previous inline editor could not offer, because each keystroke was already stored.
struct TrackpadRuleEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: AppModel
  let isNewRule: Bool
  let onSave: (TrackpadGestureRule) -> Void
  let onDelete: (UUID) -> Void

  @State private var draft: TrackpadGestureRule
  /// Decided once, from the rule as it arrived: a slider dragged back to its default while
  /// the sheet is open must not fold itself away under the hand doing the dragging.
  @State private var showsTriggerAdvanced: Bool
  @State private var showsScopeAdvanced: Bool

  init(
    model: AppModel,
    rule: TrackpadGestureRule,
    isNewRule: Bool,
    onSave: @escaping (TrackpadGestureRule) -> Void,
    onDelete: @escaping (UUID) -> Void
  ) {
    self.model = model
    self.isNewRule = isNewRule
    self.onSave = onSave
    self.onDelete = onDelete
    _draft = State(initialValue: rule)
    _showsTriggerAdvanced = State(
      initialValue: TrackpadRuleAdvancedDisclosure.expandsTrigger(for: rule))
    _showsScopeAdvanced = State(
      initialValue: TrackpadRuleAdvancedDisclosure.expandsScope(for: rule))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          TrackpadTriggerEditor(
            trigger: $draft.trigger,
            requiredModifiers: $draft.requiredModifiers,
            isAdvancedExpanded: $showsTriggerAdvanced,
            edgeWidth: settings.edgeWidth,
            sensitivity: settings.sensitivity
          )

          Divider()
          TrackpadActionEditor(
            model: model,
            action: $draft.action,
            triggerKind: draft.trigger.kind
          )

          Divider()
          scopeSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }

      Divider()
      footer
    }
    .frame(width: TrackpadRuleSheetLayout.width)
    .frame(
      minHeight: TrackpadRuleSheetLayout.minimumHeight,
      idealHeight: TrackpadRuleSheetLayout.idealHeight,
      maxHeight: TrackpadRuleSheetLayout.maximumHeight
    )
  }

  private var settings: TrackpadGestureSettings {
    model.settings.trackpadGestureSettings
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(isNewRule ? L10n.string("New Gesture Rule") : L10n.string("Edit Gesture Rule"))
        .font(.headline)

      LabeledContent("Name") {
        TextField("Rule name", text: $draft.name)
          .textFieldStyle(.roundedBorder)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  private var scopeSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Scope")
        .font(.subheadline.weight(.semibold))

      TrackpadApplicationScopeEditor(scope: $draft.applicationScope)

      TrackpadAdvancedDisclosure(
        isExpanded: $showsScopeAdvanced,
        caption: L10n.string("Devices, pointer activation, and notes.")
      ) {
        LabeledContent("Trackpad devices") {
          Picker("Trackpad devices", selection: $draft.deviceScope) {
            ForEach(TrackpadDeviceScope.allCases) { scope in
              Text(scope.settingsTitle).tag(scope)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 260)
        }

        Toggle(
          "Activate the window under the pointer before the action",
          isOn: $draft.activatesWindowUnderPointer
        )
        .help("MenuCue fails closed when macOS cannot identify an activatable window.")

        VStack(alignment: .leading, spacing: 5) {
          Text("Note")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextEditor(text: $draft.note)
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
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if !isNewRule {
        Button("Delete Rule", role: .destructive) {
          onDelete(draft.id)
          dismiss()
        }
      }

      Spacer(minLength: 0)

      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)

      Button("Save") {
        onSave(draft)
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }
}

private enum TrackpadRuleSheetLayout {
  static let width: CGFloat = 560
  static let minimumHeight: CGFloat = 440
  static let idealHeight: CGFloat = 560
  static let maximumHeight: CGFloat = 680
}

/// The tail of an editor section: the fields that have a working default, folded away so
/// the section reads as the handful of choices that actually define the rule.
private struct TrackpadAdvancedDisclosure<Content: View>: View {
  @Binding var isExpanded: Bool
  let caption: String
  @ViewBuilder let content: Content

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .padding(.top, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("Advanced")
          .font(.subheadline.weight(.medium))
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
  }
}

private struct TrackpadTriggerEditor: View {
  @Binding var trigger: TrackpadGestureTrigger
  @Binding var requiredModifiers: Set<TrackpadModifier>
  @Binding var isAdvancedExpanded: Bool
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

      TrackpadAdvancedDisclosure(
        isExpanded: $isAdvancedExpanded,
        caption: L10n.string("Thresholds and tuning. The defaults suit most gestures.")
      ) {
        LabeledContent("Required modifiers") {
          TrackpadModifierSelector(selection: $requiredModifiers)
        }

        familyTuningFields
      }
    }
  }

  /// What the gesture *is*: the parameters that separate this rule from its siblings in the
  /// same family, and the notes that explain them.
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

    case .edgeEntrySwipe:
      edgePicker
      directionPicker

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

    case .tipTap:
      selectedFingerStepper
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

    case .drawing:
      TrackpadDrawingRecorder(points: binding(\.drawingTemplate))

      Text("A drawing trigger runs the selected action directly. It replaces the cross-module normal-mouse drawing bridge with an equivalent editable rule.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    case .edgeContinuous:
      edgePicker
      Toggle("Invert edge direction", isOn: binding(\.isInverted))
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

    case .anchoredSlide:
      selectedFingerStepper
      LabeledContent("Slide axis") {
        Picker("Slide axis", selection: binding(\.slideAxis)) {
          ForEach(TrackpadSlideAxis.allCases) { axis in
            Text(axis.settingsTitle).tag(axis)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }
      Text("Finger positions are assigned left to right when the gesture arms.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Label(
        L10n.format(
          "Uses the global sensitivity of %@.",
          TrackpadUIFormat.multiplier(sensitivity)
        ),
        systemImage: "slider.horizontal.3"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The thresholds behind the gesture. Every one of them ships with a value that works, so
  /// they sit folded away; `TrackpadRuleAdvancedDisclosure.foldedTuning` lists the same
  /// fields per family and is what unfolds the group for a rule that moved one.
  @ViewBuilder
  private var familyTuningFields: some View {
    switch trigger.kind {
    case .contact:
      durationSlider
      movementToleranceSlider

    case .swipe:
      distanceSlider(title: L10n.string("Minimum swipe distance"))
      velocitySlider
      durationSlider
      movementToleranceSlider

    case .edgeEntrySwipe:
      distanceSlider(title: L10n.string("Minimum entry distance"))
      velocitySlider
      durationSlider

    case .pinch:
      distanceSlider(title: L10n.string("Minimum pinch change"))
      durationSlider
      movementToleranceSlider

    case .tipTap:
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

    case .fingerSwipe:
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

      TrackpadLabeledSlider(
        title: L10n.string("Minimum drawing match"),
        value: binding(\.minimumDrawingScore),
        range: 0.30...0.98,
        step: 0.01,
        valueText: TrackpadUIFormat.percent(trigger.minimumDrawingScore)
      )
      durationSlider
      movementToleranceSlider

    case .edgeContinuous:
      distanceSlider(title: L10n.string("Distance per action step"))
      velocitySlider

    case .anchoredSlide:
      distanceSlider(title: L10n.string("Distance per action step"))
      movementToleranceSlider
      Text("The other fingers must stay inside the movement tolerance. Keeping the step distance larger than that tolerance is what separates this gesture from an ordinary two-finger scroll.")
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
      availabilityNotice
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
      }

    case .keyboardShortcut:
      LabeledContent("Shortcut") {
        TrackpadShortcutRecorder(shortcut: binding(\.keyboardShortcut))
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

  /// What is actually wrong right now, as opposed to what this action family requires in
  /// general. Only shown when the rule would fail if the gesture fired this second.
  @ViewBuilder
  private var availabilityNotice: some View {
    let availability = model.trackpadGestureService.availability(for: action)
    if !availability.isAvailable, let reason = availability.reason {
      VStack(alignment: .leading, spacing: 7) {
        Label(reason, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        if let settingsURL = availability.settingsURL {
          Button("Open System Settings") {
            WorkspaceOpener.openSettings(settingsURL)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var permissionGuidance: some View {
    switch action.kind {
    case .keyboardShortcut, .mouse, .scroll, .window:
      Label(
        "This action requires Accessibility when it runs. Touch observation remains independent and pass-through.",
        systemImage: "lock.shield"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

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

    case .open:
      Label("Opening an app, URL, file, or folder does not require Accessibility.", systemImage: "checkmark.shield")
        .font(.caption)
        .foregroundStyle(.secondary)

    // A Quick Action's permissions belong to the action itself, and a rule with no
    // action asks for nothing; both are covered by the notice above when they fail.
    case .quickAction, .none:
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
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

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
