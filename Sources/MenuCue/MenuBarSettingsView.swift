import SwiftUI

/// Everything that decides what the menu bar itself shows: the rotating clock, the
/// content it shows, the format it renders with, and the carousel of clocks it rotates
/// through.
struct MenuBarSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var pendingTimeZoneID = TimeZone.autoupdatingCurrent.identifier

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      MenuBarFormatSettingsView(model: model)
      clockCarouselCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var clockCarouselCard: some View {
    SettingsCard(
      L10n.string("Clock carousel"),
      desc: L10n.string(
        "Drag to set the carousel order. Scroll over the menu-bar clock to switch temporarily; after one interval, rotation continues unless a context-menu clock is pinned."
      )
    ) {
      SettingsRows {
        MenuBarIntervalRow(
          title: L10n.string("Switch interval"),
          value: model.settingsBinding(\.statusBarSwitchIntervalSeconds),
          range: 2...30,
          valueLabel: L10n.format("%ds", Int(model.settings.statusBarSwitchIntervalSeconds))
        )

        clockCarouselList

        MenuBarAddClockRow(
          selection: $pendingTimeZoneID,
          canAdd: canAddPendingTimeZone,
          showsAddSystemClock: !systemClockIsConfigured,
          onAdd: { model.addTimeZone(identifier: pendingTimeZoneID) },
          onAddSystemClock: { model.addSystemClock() }
        )

        SettingsRow(
          L10n.string("Role of the First Clock"),
          desc: L10n.string(
            "The first clock is the fallback for overview and appearance settings when their selected time zone is unavailable."
          )
        ) {
          SettingsChip(L10n.string("Referenced"))
        }
      }
    }
  }

  /// The carousel is the one list in the settings window the user reorders by dragging,
  /// so it stays a `List` — restyled to sit flush on the card the way every other row
  /// does, with the shared list-row shape inside it.
  private var clockCarouselList: some View {
    List {
      ForEach(model.settings.clockTimeZones) { clock in
        SettingsListRow(
          clock.isSystem ? L10n.string("System Clock") : clock.title,
          desc: clock.isSystem ? clock.subtitle : clock.identifier,
          showsHandle: true
        ) {
          ClockLabelEditor(label: clock.customLabel) { label in
            model.updateClockLabel(id: clock.id, label: label)
          }
          .frame(width: 150)

          Button(role: .destructive) {
            model.removeClock(id: clock.id)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .disabled(model.settings.clockEntries.count == 1)
          .help(L10n.string("Remove clock"))
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
      .onMove { source, destination in
        model.moveClocks(fromOffsets: source, toOffset: destination)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .frame(minHeight: 150, maxHeight: 260)
  }


  private var systemClockIsConfigured: Bool {
    model.settings.clockEntries.contains(where: \.isSystem)
  }

  private var canAddPendingTimeZone: Bool {
    guard TimeZone(identifier: pendingTimeZoneID) != nil else { return false }
    return !model.settings.clockEntries.contains(where: { $0.id == pendingTimeZoneID })
  }
}

private struct ClockLabelEditor: View {
  let label: String?
  let onCommit: (String?) -> Void
  @State private var draft: String
  @FocusState private var isFocused: Bool

  init(label: String?, onCommit: @escaping (String?) -> Void) {
    self.label = label
    self.onCommit = onCommit
    self._draft = State(initialValue: label ?? "")
  }

  var body: some View {
    TextField(L10n.string("Custom label"), text: $draft)
      .textFieldStyle(.roundedBorder)
      .focused($isFocused)
      .onSubmit(commit)
      .onChange(of: isFocused) { focused in
        if !focused { commit() }
      }
      .onChange(of: label) { value in
        if !isFocused { draft = value ?? "" }
      }
  }

  private func commit() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.isEmpty ? nil : trimmed
    if normalized != label { onCommit(normalized) }
    if draft != trimmed { draft = trimmed }
  }
}

/// The design system's row set covers pickers, toggles, fields and sliders; the carousel
/// interval is a stepper, so this supplies just that control inside the shared row
/// chrome rather than inventing a second row style.
private struct MenuBarIntervalRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let valueLabel: String

  var body: some View {
    SettingsRow(title) {
      HStack(spacing: 10) {
        Text(valueLabel)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
        Stepper("", value: $value, in: range)
          .labelsHidden()
      }
    }
  }
}

/// Adding a clock is a control cluster with no label of its own, which no shared row
/// models, so it borrows the row chrome directly.
private struct MenuBarAddClockRow: View {
  @Environment(\.settingsSurface) private var surface
  @Binding var selection: String
  let canAdd: Bool
  let showsAddSystemClock: Bool
  let onAdd: () -> Void
  let onAddSystemClock: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "plus")
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)

      TimeZonePicker(title: L10n.string("Add"), selection: $selection)

      Spacer(minLength: 0)

      Button(L10n.string("Add"), action: onAdd)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canAdd)

      if showsAddSystemClock {
        Button(L10n.string("Add System Clock"), action: onAddSystemClock)
          .buttonStyle(.link)
          .controlSize(.small)
      }
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, SettingsMetrics.rowPaddingV)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface)
  }
}

private struct MenuBarFormatSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var advancedDateDraft: String
  @State private var advancedTimeDraft: String

  init(model: AppModel) {
    self.model = model
    self._advancedDateDraft = State(
      initialValue: model.settings.menuBarFormat.advancedDatePattern)
    self._advancedTimeDraft = State(
      initialValue: model.settings.menuBarFormat.advancedTimePattern)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      statusItemCard
      formatCard
      structuredOptionsCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: model.settings.menuBarFormat.advancedDatePattern) { value in
      if value != advancedDateDraft { advancedDateDraft = value }
    }
    .onChange(of: model.settings.menuBarFormat.advancedTimePattern) { value in
      if value != advancedTimeDraft { advancedTimeDraft = value }
    }
  }

  /// What the status item *is*: the rotating clock, or a fixed icon.
  private var statusItemCard: some View {
    SettingsCard(L10n.string("Status item")) {
      SettingsRows {
        SettingsRowSegmented(
          L10n.string("Content"),
          selection: statusContentSelection,
          options: StatusBarContent.allCases.map(\.title)
        )

        SettingsRowSelect(
          L10n.string("Icon"),
          desc: L10n.string(
            "Shows the selected icon in place of the rotating clock. Click it to open MenuCue."
          ),
          selection: formatBinding(\.statusItemIcon),
          options: StatusBarIcon.allCases.map { (value: $0, label: $0.title) }
        )
        .disabled(!isIconMode)
      }
    }
  }

  /// How the clock renders. The pattern fields belong to Advanced mode and the whole
  /// card is inert while the status item is an icon.
  private var formatCard: some View {
    SettingsCard(
      L10n.string("Clock Format"),
      desc: L10n.string(
        "Uses Unicode date-field patterns, for example EEE MMM d and HH:mm:ss."
      ),
      action: {
        Button(L10n.string("Reset"), action: resetFormat)
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    ) {
      SettingsRows {
        SettingsRowSegmented(
          L10n.string("Mode"),
          selection: formatModeSelection,
          options: MenuBarFormatMode.allCases.map(\.title)
        )

        SettingsRowField(
          L10n.string("Date pattern (empty hides date)"),
          text: $advancedDateDraft,
          fieldWidth: 190
        )
        .disabled(!isAdvancedMode)
        .onChange(of: advancedDateDraft) { _ in commitAdvancedDraftIfValid() }

        SettingsRowField(
          L10n.string("Time pattern"),
          text: $advancedTimeDraft,
          fieldWidth: 190
        )
        .disabled(!isAdvancedMode)
        .onChange(of: advancedTimeDraft) { _ in commitAdvancedDraftIfValid() }

        SettingsRow(
          L10n.string("Preview"),
          desc: L10n.string("The current format's actual width in the menu bar.")
        ) {
          VStack(alignment: .trailing, spacing: 6) {
            MenuBarFormatPreview(format: previewFormat, clock: previewClock)
            if let message = draftValidation.message, !isIconMode {
              Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
        }

        SettingsRowSelect(
          L10n.string("Order"),
          desc: L10n.string("In Advanced mode the pattern strings set their own order."),
          selection: formatBinding(\.segmentOrder),
          options: MenuBarSegmentOrder.allCases.map { (value: $0, label: $0.title) }
        )
      }
      .disabled(isIconMode)
    }
  }

  /// The pickers Structured mode assembles the clock from. Their values survive a switch
  /// to Advanced mode, where they are kept but take no effect.
  private var structuredOptionsCard: some View {
    SettingsCard(
      L10n.string("Structured Options"),
      desc: L10n.string("These values are kept but have no effect in Advanced mode."),
      tone: .inset
    ) {
      if let editingHint {
        SettingsRow(
          L10n.string("How to edit these options"),
          desc: editingHint
        ) {
          SettingsChip(L10n.string("Locked"), systemImage: "lock.fill", tint: .orange)
        }
      }

      SettingsRows {
        SettingsRowSelect(
          L10n.string("Clock cycle"),
          selection: formatBinding(\.clockCycle),
          options: ClockCycle.allCases.map { (value: $0, label: $0.title) }
        )

        SettingsRowToggle(L10n.string("Show seconds"), isOn: formatBinding(\.showsSeconds))

        SettingsRowSelect(
          L10n.string("Date"),
          selection: formatBinding(\.dateStyle),
          options: MenuBarDateStyle.allCases.map { (value: $0, label: $0.title) }
        )

        SettingsRowSelect(
          L10n.string("Weekday"),
          selection: formatBinding(\.weekdayStyle),
          options: WeekdayStyle.allCases.map { (value: $0, label: $0.title) }
        )
      }
      .disabled(isIconMode || !isStructuredMode)
    }
  }

  private var isIconMode: Bool {
    model.settings.menuBarFormat.statusItemContent == .icon
  }

  private var isStructuredMode: Bool {
    model.settings.menuBarFormat.mode == .structured
  }

  private var isAdvancedMode: Bool {
    model.settings.menuBarFormat.mode == .advanced
  }

  private var editingHint: String? {
    if isIconMode {
      return L10n.string("Choose Clock in Status item › Content before editing these options.")
    }
    if !isStructuredMode {
      return L10n.string("Choose Structured in Clock Format › Mode before editing these options.")
    }
    return nil
  }

  private var statusContentSelection: Binding<Int> {
    Binding(
      get: {
        StatusBarContent.allCases.firstIndex(of: model.settings.menuBarFormat.statusItemContent)
          ?? 0
      },
      set: { index in
        guard StatusBarContent.allCases.indices.contains(index) else { return }
        formatBinding(\.statusItemContent).wrappedValue = StatusBarContent.allCases[index]
      }
    )
  }

  private var formatModeSelection: Binding<Int> {
    Binding(
      get: { MenuBarFormatMode.allCases.firstIndex(of: model.settings.menuBarFormat.mode) ?? 0 },
      set: { index in
        guard MenuBarFormatMode.allCases.indices.contains(index) else { return }
        formatBinding(\.mode).wrappedValue = MenuBarFormatMode.allCases[index]
      }
    )
  }

  private var previewClock: ClockTimeZone {
    model.settings.clockTimeZones.first ?? .system(timeZone: .autoupdatingCurrent)
  }

  private var previewFormat: MenuBarFormatSettings {
    guard model.settings.menuBarFormat.mode == .advanced else {
      return model.settings.menuBarFormat
    }
    var candidate = model.settings.menuBarFormat
    candidate.advancedDatePattern = advancedDateDraft
    candidate.advancedTimePattern = advancedTimeDraft
    return candidate
  }

  private var draftValidation: MenuBarFormatValidation {
    MenuBarClockRenderer.validation(for: previewFormat, clock: previewClock)
  }

  private func formatBinding<Value>(
    _ keyPath: WritableKeyPath<MenuBarFormatSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { model.settings.menuBarFormat[keyPath: keyPath] },
      set: { value in
        var updated = model.settings.menuBarFormat
        updated[keyPath: keyPath] = value
        model.updateMenuBarFormat(updated)
      }
    )
  }

  private func resetFormat() {
    let defaults = MenuBarFormatSettings.compatibilityDefault
    advancedDateDraft = defaults.advancedDatePattern
    advancedTimeDraft = defaults.advancedTimePattern
    model.resetMenuBarFormat()
  }

  private func commitAdvancedDraftIfValid() {
    let candidate = previewFormat
    guard MenuBarClockRenderer.validation(for: candidate, clock: previewClock) == .valid else {
      return
    }
    model.updateMenuBarFormat(candidate)
  }
}

/// The rendered menu-bar string, sampled once a second. The row around it carries the
/// label, so this renders only the value.
private struct MenuBarFormatPreview: View {
  let format: MenuBarFormatSettings
  let clock: ClockTimeZone
  @State private var renderer = MenuBarClockRenderer()

  var body: some View {
    if format.statusItemContent == .icon {
      iconPreview
    } else {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let output = rendering(at: context.date)
        VStack(alignment: .trailing, spacing: 6) {
          Text(
            output.combinedText.isEmpty ? L10n.string("No visible output") : output.combinedText
          )
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

          if MenuBarClockRenderer.exceedsRecommendedWidth(output.combinedText) {
            Text(L10n.string("This format may occupy too much menu-bar width."))
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var iconPreview: some View {
    Group {
      if format.statusItemIcon == .appIcon {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
      } else if let systemImageName = format.statusItemIcon.systemImageName {
        Image(systemName: systemImageName)
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: 18, height: 18)
    .padding(8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
  }

  private func rendering(at date: Date) -> MenuBarClockRendering {
    renderer.update(format: format)
    return renderer.render(date: date, clock: clock)
  }
}
