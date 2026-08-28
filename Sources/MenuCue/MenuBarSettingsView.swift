import SwiftUI

/// Everything that decides what the menu bar itself shows: the clock format, the
/// carousel of clocks it rotates through, the time zone MenuCue displays dates in, and
/// the macOS system time zone those all sit on top of.
struct MenuBarSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var pendingTimeZoneID = TimeZone.autoupdatingCurrent.identifier

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      MenuBarFormatSettingsView(model: model)
      clockCarouselSection
      overviewDisplaySection

      Divider()
      SystemTimeZoneSettingsView(
        powerHelper: model.quickActionService.powerHelperManager
      )
    }
  }

  private var clockCarouselSection: some View {
    SettingsGroup(spacing: 14) {
      Stepper(
        L10n.format(
          "Switch every %ds",
          Int(model.settings.statusBarSwitchIntervalSeconds)
        ),
        value: model.settingsBinding(\.statusBarSwitchIntervalSeconds),
        in: 2...30,
        step: 1
      )

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Clock carousel")
            .font(.subheadline.weight(.medium))
          Spacer()
          if !systemClockIsConfigured {
            Button("Add System Clock") {
              model.addSystemClock()
            }
          }
        }

        List {
          ForEach(model.settings.clockTimeZones) { clock in
            HStack(spacing: 10) {
              Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)

              VStack(alignment: .leading, spacing: 2) {
                Text(clock.isSystem ? L10n.string("System Clock") : clock.title)
                  .font(.body)
                Text(clock.isSystem ? clock.subtitle : clock.identifier)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .frame(minWidth: 150, alignment: .leading)

              Spacer()

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
              .help("Remove clock")
            }
            .padding(.vertical, 3)
          }
          .onMove { source, destination in
            model.moveClocks(fromOffsets: source, toOffset: destination)
          }
        }
        .frame(minHeight: 150, maxHeight: 260)

        Text(
          "Drag to set the carousel order. Scroll over the menu-bar clock to switch temporarily; after one interval, rotation continues unless a context-menu clock is pinned."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        TimeZonePicker(title: L10n.string("Add"), selection: $pendingTimeZoneID)
          .frame(maxWidth: 420)
        Button("Add") {
          model.addTimeZone(identifier: pendingTimeZoneID)
        }
        .disabled(!canAddPendingTimeZone)
      }

      Text(
        "The first clock is the fallback for overview and appearance settings when their selected time zone is unavailable."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var overviewDisplaySection: some View {
    SettingsGroup(spacing: 12) {
      Text("Overview Display")
        .font(.subheadline.weight(.medium))

      TimeZonePicker(
        title: L10n.string("Display time zone"),
        selection: model.settingsBinding(\.overviewTimeZoneID)
      )
      .frame(maxWidth: 460)

      Text("This changes dates and times shown inside MenuCue without changing macOS.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
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
    TextField("Custom label", text: $draft)
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
    SettingsGroup(spacing: 14) {
      HStack {
        Text("Menu Bar Format")
          .font(.headline)
        Spacer()
        Button("Reset") {
          let defaults = MenuBarFormatSettings.compatibilityDefault
          advancedDateDraft = defaults.advancedDatePattern
          advancedTimeDraft = defaults.advancedTimePattern
          model.resetMenuBarFormat()
        }
      }

      Picker("Mode", selection: formatBinding(\.mode)) {
        ForEach(MenuBarFormatMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 320)

      if model.settings.menuBarFormat.mode == .structured {
        structuredControls
      } else {
        advancedControls
      }

      Picker("Order", selection: formatBinding(\.segmentOrder)) {
        ForEach(MenuBarSegmentOrder.allCases) { order in
          Text(order.title).tag(order)
        }
      }
      .frame(maxWidth: 320)

      MenuBarFormatPreview(format: previewFormat, clock: previewClock)

      if let message = draftValidation.message {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .onChange(of: model.settings.menuBarFormat.advancedDatePattern) { value in
      if value != advancedDateDraft { advancedDateDraft = value }
    }
    .onChange(of: model.settings.menuBarFormat.advancedTimePattern) { value in
      if value != advancedTimeDraft { advancedTimeDraft = value }
    }
  }

  @ViewBuilder
  private var structuredControls: some View {
    Picker("Clock cycle", selection: formatBinding(\.clockCycle)) {
      ForEach(ClockCycle.allCases) { cycle in
        Text(cycle.title).tag(cycle)
      }
    }
    .frame(maxWidth: 320)

    Toggle("Show seconds", isOn: formatBinding(\.showsSeconds))

    Picker("Date", selection: formatBinding(\.dateStyle)) {
      ForEach(MenuBarDateStyle.allCases) { style in
        Text(style.title).tag(style)
      }
    }
    .frame(maxWidth: 320)

    Picker("Weekday", selection: formatBinding(\.weekdayStyle)) {
      ForEach(WeekdayStyle.allCases) { style in
        Text(style.title).tag(style)
      }
    }
    .frame(maxWidth: 320)
  }

  @ViewBuilder
  private var advancedControls: some View {
    TextField("Date pattern (empty hides date)", text: $advancedDateDraft)
      .textFieldStyle(.roundedBorder)
      .onChange(of: advancedDateDraft) { _ in commitAdvancedDraftIfValid() }

    TextField("Time pattern", text: $advancedTimeDraft)
      .textFieldStyle(.roundedBorder)
      .onChange(of: advancedTimeDraft) { _ in commitAdvancedDraftIfValid() }

    Text("Uses Unicode date-field patterns, for example EEE MMM d and HH:mm:ss.")
      .font(.caption)
      .foregroundStyle(.secondary)
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

  private func commitAdvancedDraftIfValid() {
    let candidate = previewFormat
    guard MenuBarClockRenderer.validation(for: candidate, clock: previewClock) == .valid else {
      return
    }
    model.updateMenuBarFormat(candidate)
  }
}

private struct MenuBarFormatPreview: View {
  let format: MenuBarFormatSettings
  let clock: ClockTimeZone
  @State private var renderer = MenuBarClockRenderer()

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let output = rendering(at: context.date)
      VStack(alignment: .leading, spacing: 6) {
        Text("Preview")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Text(
          output.combinedText.isEmpty ? L10n.string("No visible output") : output.combinedText
        )
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        if MenuBarClockRenderer.exceedsRecommendedWidth(output.combinedText) {
          Text("This format may occupy too much menu-bar width.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
    }
  }

  private func rendering(at date: Date) -> MenuBarClockRendering {
    renderer.update(format: format)
    return renderer.render(date: date, clock: clock)
  }
}
