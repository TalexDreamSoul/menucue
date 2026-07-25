import AppKit
import Foundation
import SwiftUI

private let eventAccentPalette: [Color] = [.orange, .purple, .blue, .green, .pink]

private func gregorianCalendar(for timeZone: TimeZone, weekStartDay: WeekStartDay) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = timeZone
  calendar.firstWeekday = weekStartDay.firstWeekday
  return calendar
}

private func eventAccentColor(for event: CalendarEventInfo) -> Color {
  let scalarTotal = event.calendarTitle.unicodeScalars.reduce(0) { $0 + Int($1.value) }
  return eventAccentPalette[scalarTotal % eventAccentPalette.count]
}

struct StatusPopoverView: View {
  @ObservedObject var model: AppModel
  let openSettings: () -> Void
  let openQuickActions: () -> Void
  @State private var visibleMonthDate = Date()
  @State private var selectedCalendarDate = Date()
  @State private var quickEventDraft: QuickEventDraft?

  var body: some View {
    overviewView
      .padding(18)
      .frame(width: 304, height: 640, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
      .sheet(isPresented: quickEventSheetBinding) {
        quickEventSheet
      }
  }

  private var overviewView: some View {
    TimelineView(.periodic(from: Date(), by: 1)) { context in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          QuickActionGrid(model: model, openMore: openQuickActions)
          clockSection(date: context.date)
          MonthCalendarView(
            monthDate: $visibleMonthDate,
            selectedDate: $selectedCalendarDate,
            events: model.events,
            timeZone: model.settings.overviewTimeZone,
            weekStartDay: model.settings.calendarWeekStartDay
          )
          DailyGuideCard(
            date: selectedCalendarDate,
            timeZone: model.settings.overviewTimeZone
          )
          eventsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func clockSection(date: Date) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("World Clocks")
        .font(.headline)
      ForEach(model.settings.clockTimeZones) { clock in
        ClockCard(clock: clock, date: date)
      }
    }
  }

  private var eventsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Events")
          .font(.headline)
        Spacer()
        Button("New Event") {
          openQuickEventEditor()
        }
        .disabled(
          !model.authorizationState.canReadEvents && model.authorizationState != .notDetermined)
        Button("Settings") {
          openSettings()
        }
      }

      if !model.authorizationState.canReadEvents {
        VStack(alignment: .leading, spacing: 8) {
          Text("Grant Calendar access to show iCloud and local Calendar events.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Grant Calendar Access") {
            model.requestCalendarAccess()
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        AgendaList(
          events: model.events,
          timeZone: model.settings.overviewTimeZone,
          weekStartDay: model.settings.calendarWeekStartDay
        )
      }
    }
  }

  private var quickEventSheetBinding: Binding<Bool> {
    Binding(
      get: { quickEventDraft != nil },
      set: { isPresented in
        if !isPresented {
          quickEventDraft = nil
        }
      }
    )
  }

  @ViewBuilder
  private var quickEventSheet: some View {
    if let currentDraft = quickEventDraft {
      QuickEventEditor(
        draft: Binding(
          get: { quickEventDraft ?? currentDraft },
          set: { quickEventDraft = $0 }
        ),
        calendars: model.calendars,
        onCancel: { quickEventDraft = nil },
        onSave: { draft in
          model.createEvent(from: draft)
          quickEventDraft = nil
        }
      )
      .padding(20)
      .frame(width: 540)
    }
  }

  private func openQuickEventEditor() {
    if model.authorizationState == .notDetermined {
      model.requestCalendarAccess()
      return
    }
    quickEventDraft = model.quickEventDraft(startDate: selectedCalendarDate)
  }
}

private struct DailyGuide {
  let favorable: [String]
  let unfavorable: [String]

  private static let favorableActivities = [
    "专注", "计划", "学习", "会友", "出行", "运动",
    "整理", "创作", "沟通", "休息", "复盘", "开始",
  ]
  private static let unfavorableActivities = [
    "拖延", "熬夜", "冲动消费", "过度承诺", "仓促决定",
    "争执", "冒险", "久坐", "分心", "强求结果",
  ]

  static func make(for date: Date, timeZone: TimeZone) -> DailyGuide {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    let seed =
      (components.year ?? 0) * 372
      + (components.month ?? 0) * 31
      + (components.day ?? 0)

    return DailyGuide(
      favorable: picks(from: favorableActivities, count: 3, seed: seed, step: 5),
      unfavorable: picks(from: unfavorableActivities, count: 2, seed: seed * 7 + 3, step: 3)
    )
  }

  private static func picks(
    from activities: [String],
    count: Int,
    seed: Int,
    step: Int
  ) -> [String] {
    guard !activities.isEmpty else { return [] }
    let start = ((seed % activities.count) + activities.count) % activities.count
    return (0..<min(count, activities.count)).map { offset in
      activities[(start + offset * step) % activities.count]
    }
  }
}

private struct DailyGuideCard: View {
  let date: Date
  let timeZone: TimeZone

  var body: some View {
    let guide = DailyGuide.make(for: date, timeZone: timeZone)

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("Daily Guide")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(dateText)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      guideRow(label: "宜", color: .green, activities: guide.favorable)
      guideRow(label: "忌", color: .red, activities: guide.unfavorable)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .help("A light daily guide generated on-device for the selected date.")
  }

  private func guideRow(label: String, color: Color, activities: [String]) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.caption.weight(.bold))
        .foregroundStyle(color)
        .frame(width: 24, height: 20)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      Text(activities.joined(separator: " · "))
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
  }

  private var dateText: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
  }
}

struct QuickEventWindowView: View {
  @ObservedObject var model: AppModel
  @State private var draft: QuickEventDraft
  let onClose: () -> Void

  init(model: AppModel, startDate: Date = Date(), onClose: @escaping () -> Void) {
    self.model = model
    self._draft = State(initialValue: model.quickEventDraft(startDate: startDate))
    self.onClose = onClose
  }

  var body: some View {
    QuickEventEditor(
      draft: $draft,
      calendars: model.calendars,
      onCancel: onClose,
      onSave: { draft in
        model.createEvent(from: draft)
        onClose()
      }
    )
    .padding(20)
    .frame(width: 540)
  }
}

private struct QuickEventEditor: View {
  @Binding var draft: QuickEventDraft
  let calendars: [CalendarInfo]
  let onCancel: () -> Void
  let onSave: (QuickEventDraft) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Rectangle()
          .fill(Color.accentColor)
          .frame(width: 3, height: 36)
          .clipShape(Capsule())
        TextField("New Event", text: $draft.title)
          .font(.system(size: 28, weight: .medium))
          .textFieldStyle(.plain)
        Spacer()
        if !calendars.isEmpty {
          Picker("Calendar", selection: calendarSelection) {
            ForEach(calendars) { calendar in
              Text(calendar.title).tag(Optional(calendar.id))
            }
          }
          .labelsHidden()
          .frame(width: 150)
        }
      }

      TextField("Add Location or Video Call", text: $draft.location)
        .font(.title3)
        .textFieldStyle(.plain)

      Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
        GridRow {
          Text("All-day:")
          Toggle("", isOn: $draft.isAllDay)
            .labelsHidden()
            .gridColumnAlignment(.leading)
        }
        GridRow {
          Text("Starts:")
          DatePicker("", selection: $draft.startDate, displayedComponents: datePickerComponents)
            .labelsHidden()
            .gridColumnAlignment(.leading)
        }
        GridRow {
          Text("Ends:")
          DatePicker("", selection: $draft.endDate, displayedComponents: datePickerComponents)
            .labelsHidden()
            .gridColumnAlignment(.leading)
        }
        GridRow {
          Text("Repeat:")
          Picker("Repeat", selection: $draft.repeatMode) {
            ForEach(EventRepeatMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .frame(width: 300)
          .gridColumnAlignment(.leading)
        }
        GridRow {
          Text("Alert:")
          Picker("Alert", selection: $draft.alertMode) {
            ForEach(EventAlertMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .frame(width: 300)
          .gridColumnAlignment(.leading)
        }
      }
      .font(.title3)

      TextField("Add Notes", text: $draft.notes, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.plain)
        .foregroundStyle(.secondary)
      TextField("Add URL", text: $draft.urlString)
        .textFieldStyle(.plain)
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save Event") {
          onSave(draft)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
      }
    }
  }

  private var canSave: Bool {
    !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.endDate > draft.startDate
  }

  private var calendarSelection: Binding<String?> {
    Binding(
      get: { draft.calendarID ?? calendars.first?.id },
      set: { draft.calendarID = $0 }
    )
  }

  private var datePickerComponents: DatePickerComponents {
    draft.isAllDay ? [.date] : [.date, .hourAndMinute]
  }
}

struct SettingsWindowView: View {
  @ObservedObject var model: AppModel
  @State private var selectedPane: SettingsPane

  init(model: AppModel, initialPane: SettingsPane = .dateAndEvents) {
    self.model = model
    self._selectedPane = State(initialValue: initialPane)
  }

  var body: some View {
    NavigationSplitView {
      List(availablePanes, selection: $selectedPane) { pane in
        Label(pane.title, systemImage: pane.systemImage)
          .tag(pane)
      }
      .listStyle(.sidebar)
      .navigationTitle("Settings")
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
    } detail: {
      SettingsContentView(model: model, pane: selectedPane)
    }
    .frame(minWidth: 700, idealWidth: 760, minHeight: 520, idealHeight: 640, alignment: .topLeading)
  }

  private var availablePanes: [SettingsPane] {
    SettingsPane.allCases.filter { pane in
      pane != .iCloud || model.preferenceSyncService.isEntitled
    }
  }
}

enum SettingsPane: String, CaseIterable, Identifiable {
  case dateAndEvents
  case quickActions
  case menuBarTimeZones
  case appearance
  case calendars
  case iCloud
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dateAndEvents: return "Date & Events"
    case .quickActions: return "Quick Actions"
    case .menuBarTimeZones: return "Menu Bar"
    case .appearance: return "Appearance"
    case .calendars: return "Calendars"
    case .iCloud: return "iCloud Sync"
    case .about: return "About"
    }
  }

  var subtitle: String {
    switch self {
    case .dateAndEvents:
      return "Calendar display, overview time zone, and week layout."
    case .quickActions:
      return "Pinned actions, ordering, availability, and Apple Shortcuts."
    case .menuBarTimeZones:
      return "Status item clocks and rotation behavior."
    case .appearance:
      return "App appearance and optional macOS Light/Dark automation."
    case .calendars:
      return "Calendar permissions and event sources."
    case .iCloud:
      return "Portable preferences, conflict choices, and synchronization status."
    case .about:
      return "Version, GitHub releases, and project links."
    }
  }

  var systemImage: String {
    switch self {
    case .dateAndEvents: return "calendar"
    case .quickActions: return "square.grid.2x2"
    case .menuBarTimeZones: return "menubar.rectangle"
    case .appearance: return "circle.lefthalf.filled"
    case .calendars: return "calendar.badge.clock"
    case .iCloud: return "icloud"
    case .about: return "info.circle"
    }
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
      .onChange(of: isFocused) { _, focused in
        if !focused { commit() }
      }
      .onChange(of: label) { _, value in
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
    .onChange(of: model.settings.menuBarFormat.advancedDatePattern) { _, value in
      if value != advancedDateDraft { advancedDateDraft = value }
    }
    .onChange(of: model.settings.menuBarFormat.advancedTimePattern) { _, value in
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
      .onChange(of: advancedDateDraft) { _, _ in commitAdvancedDraftIfValid() }

    TextField("Time pattern", text: $advancedTimeDraft)
      .textFieldStyle(.roundedBorder)
      .onChange(of: advancedTimeDraft) { _, _ in commitAdvancedDraftIfValid() }

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
        Text(output.combinedText.isEmpty ? "No visible output" : output.combinedText)
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

private struct PreferenceSyncSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: PreferenceSyncService

  init(model: AppModel) {
    self.model = model
    self._service = ObservedObject(wrappedValue: model.preferenceSyncService)
  }

  var body: some View {
    SettingsGroup(spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: statusSymbol)
          .font(.title2)
          .foregroundStyle(statusColor)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text(service.status.title)
            .font(.headline)
          Text(service.status.message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      syncActions

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("Synced between Macs")
          .font(.subheadline.weight(.medium))
        Text(
          "Menu-bar format, clock order and labels, rotation interval, overview time zone, week start, and app appearance."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Text("Kept on this Mac")
          .font(.subheadline.weight(.medium))
          .padding(.top, 4)
        Text(
          "Calendar access and selection, system appearance control, Quick Actions, sync choices, and temporary UI state."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var syncActions: some View {
    switch service.status {
    case .needsOnboarding:
      HStack {
        Button("Enable iCloud Sync") {
          model.completePreferenceSyncOnboarding(enable: true)
        }
        .buttonStyle(.borderedProminent)
        Button("Keep Settings on This Mac") {
          model.completePreferenceSyncOnboarding(enable: false)
        }
      }
    case .needsSourceDecision:
      HStack {
        Button("Use iCloud Settings") {
          model.chooseCloudPreferenceSettings()
        }
        .buttonStyle(.borderedProminent)
        Button("Use This Mac's Settings") {
          model.chooseLocalPreferenceSettings()
        }
      }
    default:
      Toggle("Sync portable preferences with iCloud", isOn: syncEnabledBinding)
      if case .failed = service.status {
        Button("Retry Sync") { model.retryPreferenceSync() }
      } else if service.status == .signedOut {
        Button("Retry After Signing In") { model.retryPreferenceSync() }
      }
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

private struct SettingsContentView: View {
  @ObservedObject var model: AppModel
  let pane: SettingsPane
  @State private var pendingTimeZoneID = TimeZone.autoupdatingCurrent.identifier
  @State private var isCheckingForUpdates = false
  @State private var updateCheckMessage = "Check GitHub releases for a newer build."
  @State private var latestReleaseURL: URL?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        SettingsPaneHeader(pane: pane)
        selectedPaneContent
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var selectedPaneContent: some View {
    switch pane {
    case .dateAndEvents:
      overviewSettingsSection
    case .quickActions:
      QuickActionSettingsView(model: model)
    case .menuBarTimeZones:
      VStack(alignment: .leading, spacing: 24) {
        MenuBarFormatSettingsView(model: model)
        Divider()
        timeZoneSettingsSection
      }
    case .appearance:
      appearanceSection
    case .calendars:
      calendarSection
    case .iCloud:
      PreferenceSyncSettingsView(model: model)
    case .about:
      aboutSection
    }
  }

  private var overviewSettingsSection: some View {
    SettingsGroup {
      TimeZonePicker(
        title: "Display time zone",
        selection: binding(\.overviewTimeZoneID)
      )
      .frame(maxWidth: 460)

      Picker("Week starts", selection: binding(\.calendarWeekStartDay)) {
        ForEach(WeekStartDay.allCases) { day in
          Text(day.title).tag(day)
        }
      }
      .frame(maxWidth: 250)

      Text("Month view and week numbers use this start day.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var timeZoneSettingsSection: some View {
    SettingsGroup(spacing: 14) {
      Stepper(
        "Switch every \(Int(model.settings.statusBarSwitchIntervalSeconds))s",
        value: binding(\.statusBarSwitchIntervalSeconds),
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
                Text(clock.isSystem ? "System Clock" : clock.title)
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
        TimeZonePicker(title: "Add", selection: $pendingTimeZoneID)
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

  private var appearanceSection: some View {
    SettingsGroup(spacing: 14) {
      Picker("Appearance", selection: binding(\.appearanceMode)) {
        ForEach(AppearanceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .frame(maxWidth: 320)

      if model.settings.appearanceMode == .automaticByTimeZone {
        TimeZonePicker(
          title: "Auto reference",
          selection: binding(\.appearanceTimeZoneID)
        )
        .frame(maxWidth: 460)
        Text("Auto uses light from 07:00-19:00 in the selected time zone.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Toggle("Apply to macOS system appearance", isOn: binding(\.appliesSystemAppearance))

      Text(
        "When enabled, TouchMacer switches the system Light/Dark appearance via macOS Automation permissions. When disabled, only this app previews the selected appearance."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var calendarSection: some View {
    SettingsGroup(spacing: 12) {
      HStack {
        Button("Refresh") {
          model.refreshCalendarData()
        }
        Spacer()
      }

      Text(model.authorizationState.title)
        .font(.caption)
        .foregroundStyle(model.authorizationState.canReadEvents ? Color.secondary : Color.orange)

      if model.authorizationState == .notDetermined || model.authorizationState == .denied
        || model.authorizationState == .writeOnly
      {
        Button("Grant Calendar Access") {
          model.requestCalendarAccess()
        }
      }

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if model.authorizationState.canReadEvents {
        Picker("Show", selection: binding(\.calendarSelectionMode)) {
          ForEach(CalendarSelectionMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .frame(maxWidth: 320)

        if model.settings.calendarSelectionMode == .custom {
          calendarSelectionList
        }
      }
    }
  }

  private var aboutSection: some View {
    SettingsGroup(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("TouchMacer")
          .font(.title2.weight(.semibold))
        Text("Version \(appVersion)")
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Startup")
          .font(.headline)
        Toggle("Launch TouchMacer at login", isOn: launchAtLoginBinding)
          .disabled(model.launchAtLoginState == .unavailable)

        switch model.launchAtLoginState {
        case .disabled:
          Text("TouchMacer starts only when you open it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .enabled:
          Text("TouchMacer will start automatically after you sign in.")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .requiresApproval:
          Text("macOS requires approval before TouchMacer can start at login.")
            .font(.caption)
            .foregroundStyle(.orange)
          Button("Open Login Items Settings") {
            model.openLoginItemsSettings()
          }
        case .unavailable:
          Text("Launch at Login is available when TouchMacer runs from its app bundle.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let errorMessage = model.launchAtLoginErrorMessage, !errorMessage.isEmpty {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Updates")
          .font(.headline)
        Text(updateCheckMessage)
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 10) {
          Button(isCheckingForUpdates ? "Checking..." : "Check GitHub Updates") {
            checkForGitHubUpdates()
          }
          .disabled(isCheckingForUpdates)

          if let latestReleaseURL {
            Button("Open Latest Release") {
              NSWorkspace.shared.open(latestReleaseURL)
            }
          }
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Links")
          .font(.headline)
        HStack(spacing: 10) {
          Button("GitHub Repository") {
            openURL("https://github.com/TalexDreamSoul/touch-macer")
          }
          Button("Release Notes") {
            openURL("https://github.com/TalexDreamSoul/touch-macer/releases")
          }
        }
      }
    }
    .onAppear {
      model.refreshLaunchAtLoginState()
    }
  }

  private var calendarSelectionList: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.calendars) { calendar in
        Toggle(isOn: calendarBinding(calendar.id)) {
          VStack(alignment: .leading, spacing: 1) {
            Text(calendar.title)
            Text(calendar.sourceTitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var systemClockIsConfigured: Bool {
    model.settings.clockEntries.contains(where: \.isSystem)
  }

  private var canAddPendingTimeZone: Bool {
    guard TimeZone(identifier: pendingTimeZoneID) != nil else { return false }
    return !model.settings.clockEntries.contains(where: { $0.id == pendingTimeZoneID })
  }


  private var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { model.launchAtLoginState.isRegistered },
      set: { model.setLaunchAtLoginEnabled($0) }
    )
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1"
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(
      get: { model.settings[keyPath: keyPath] },
      set: { newValue in
        model.updateSettings { settings in
          settings[keyPath: keyPath] = newValue
        }
      }
    )
  }

  private func calendarBinding(_ calendarID: String) -> Binding<Bool> {
    Binding(
      get: { model.settings.selectedCalendarIDs.contains(calendarID) },
      set: { isSelected in
        model.updateSettings { settings in
          if isSelected {
            settings.selectedCalendarIDs.insert(calendarID)
          } else {
            settings.selectedCalendarIDs.remove(calendarID)
          }
        }
      }
    )
  }

  private func checkForGitHubUpdates() {
    isCheckingForUpdates = true
    updateCheckMessage = "Checking GitHub releases..."
    latestReleaseURL = nil

    Task {
      let result = await GitHubReleaseChecker.check(currentVersion: appVersion)
      await MainActor.run {
        isCheckingForUpdates = false
        updateCheckMessage = result.message
        latestReleaseURL = result.releaseURL
      }
    }
  }

  private func openURL(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct SettingsPaneHeader: View {
  let pane: SettingsPane

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(pane.title, systemImage: pane.systemImage)
        .font(.title2.weight(.semibold))
      Text(pane.subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SettingsGroup<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      content
    }
    .frame(maxWidth: 560, alignment: .leading)
  }
}

private struct GitHubUpdateResult {
  let message: String
  let releaseURL: URL?
}

private struct GitHubRelease: Decodable {
  let tagName: String
  let htmlURL: String

  private enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
}

private enum GitHubReleaseChecker {
  static func check(currentVersion: String) async -> GitHubUpdateResult {
    guard
      let url = URL(
        string: "https://api.github.com/repos/TalexDreamSoul/touch-macer/releases/latest")
    else {
      return GitHubUpdateResult(message: "GitHub releases URL is invalid.", releaseURL: nil)
    }

    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        return GitHubUpdateResult(
          message: "GitHub returned an unreadable response.", releaseURL: nil)
      }

      if httpResponse.statusCode == 404 {
        return GitHubUpdateResult(message: "No GitHub releases are published yet.", releaseURL: nil)
      }

      guard (200..<300).contains(httpResponse.statusCode) else {
        return GitHubUpdateResult(
          message: "GitHub update check failed with HTTP \(httpResponse.statusCode).",
          releaseURL: nil)
      }

      let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
      let latestVersion = normalizedVersion(release.tagName)
      let current = normalizedVersion(currentVersion)
      let releaseURL = URL(string: release.htmlURL)

      if latestVersion.compare(current, options: .numeric) == .orderedDescending {
        return GitHubUpdateResult(
          message: "Version \(latestVersion) is available on GitHub.", releaseURL: releaseURL)
      }

      return GitHubUpdateResult(
        message: "TouchMacer is up to date. Latest release: \(latestVersion).",
        releaseURL: releaseURL)
    } catch {
      return GitHubUpdateResult(
        message: "GitHub update check failed: \(error.localizedDescription)", releaseURL: nil)
    }
  }

  private static func normalizedVersion(_ version: String) -> String {
    String(
      version.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingPrefix("v")
        .trimmingPrefix("V"))
  }
}

private struct ClockCard: View {
  let clock: ClockTimeZone
  let date: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(clock.title)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(timeText)
          .font(.system(size: 16, weight: .semibold, design: .rounded))
          .monospacedDigit()
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(clock.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(dateText)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
    .padding(7)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var timeText: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = clock.timeZone
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  private var dateText: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = clock.timeZone
    formatter.dateFormat = "EEE, MMM d"
    return formatter.string(from: date)
  }
}

private struct MonthCalendarView: View {
  @Binding var monthDate: Date
  @Binding var selectedDate: Date
  let events: [CalendarEventInfo]
  let timeZone: TimeZone
  let weekStartDay: WeekStartDay
  @State private var hoveredDate: Date?

  private let weekNumberColumnWidth: CGFloat = 24
  private let dateCellSize: CGFloat = 26
  private var columns: [GridItem] {
    [GridItem(.fixed(weekNumberColumnWidth), spacing: 0)]
      + Array(repeating: GridItem(.fixed(dateCellSize), spacing: 0), count: 7)
  }

  private var weekdayTitles: [String] {
    let symbols = Calendar(identifier: .gregorian).veryShortStandaloneWeekdaySymbols
    let zeroBasedStart = max(0, min(6, weekStartDay.firstWeekday - 1))
    return (0..<7).map { symbols[($0 + zeroBasedStart) % 7].uppercased() }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        Text(monthName)
          .font(.headline.weight(.bold))
        Menu {
          ForEach(yearRange, id: \.self) { year in
            Button("\(year)") {
              setYear(year)
            }
          }
        } label: {
          Text(yearTitle)
            .font(.headline.weight(.bold))
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Spacer()
        Button {
          changeMonth(by: -1)
        } label: {
          Image(systemName: "chevron.left")
        }
        Button("Today") {
          monthDate = Date()
          selectedDate = Date()
        }
        Button {
          changeMonth(by: 1)
        } label: {
          Image(systemName: "chevron.right")
        }
      }
      .controlSize(.small)

      LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
        Text("")
          .frame(width: weekNumberColumnWidth, height: 20)
        ForEach(Array(weekdayTitles.enumerated()), id: \.offset) { _, title in
          Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: dateCellSize, height: 20)
        }

        ForEach(weeks) { week in
          Text("\(week.number)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: weekNumberColumnWidth, height: dateCellSize, alignment: .center)

          ForEach(week.days) { day in
            Button {
              selectedDate = day.date
              monthDate = day.date
            } label: {
              VStack(spacing: 2) {
                Text("\(day.number)")
                  .font(
                    .system(size: 13, weight: day.isSelected ? .bold : .semibold, design: .rounded)
                  )
                  .foregroundStyle(day.isInMonth ? Color.primary : Color.secondary.opacity(0.38))
                HStack(spacing: 1) {
                  ForEach(Array(day.eventColors.enumerated()), id: \.offset) { _, color in
                    Circle()
                      .fill(color)
                      .frame(width: 3.5, height: 3.5)
                  }
                }
                .frame(height: 4)
              }
              .frame(width: dateCellSize, height: dateCellSize)
              .contentShape(Rectangle())
              .background(dayBackground(for: day))
              .overlay(monthBoundary(for: day))
              .overlay(dayBorder(for: day))
            }
            .buttonStyle(.plain)
            .help(dayHelpText(for: day))
            .onHover { isHovering in
              hoveredDate = isHovering ? day.date : nil
            }
          }
        }
      }

    }
    .padding(10)
    .background(Color.secondary.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var calendar: Calendar {
    gregorianCalendar(for: timeZone, weekStartDay: weekStartDay)
  }

  private var monthStart: Date {
    let components = calendar.dateComponents([.year, .month], from: monthDate)
    return calendar.date(from: components) ?? monthDate
  }

  private var monthName: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM"
    return formatter.string(from: monthDate)
  }

  private var yearTitle: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy"
    return formatter.string(from: monthDate)
  }

  private var selectedDateText: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEE, MMM d, yyyy"
    return formatter.string(from: selectedDate)
  }

  private var selectedDateRelativeText: String {
    let now = Date()
    let todayStart = calendar.startOfDay(for: now)
    let selectedStart = calendar.startOfDay(for: selectedDate)

    if calendar.isDate(selectedStart, inSameDayAs: todayStart) {
      let hours = max(0, Int(now.timeIntervalSince(todayStart) / 3600))
      return hours == 0 ? "Less than 1 hour ago" : "\(hours) \(hours == 1 ? "hour" : "hours") ago"
    }

    let days = abs(calendar.dateComponents([.day], from: todayStart, to: selectedStart).day ?? 0)
    let unit = days == 1 ? "day" : "days"
    return selectedStart < todayStart ? "\(days) \(unit) ago" : "In \(days) \(unit)"
  }

  private var daysInVisibleMonth: Int {
    calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
  }

  private var leadingDays: Int {
    let weekday = calendar.component(.weekday, from: monthStart)
    return (weekday - calendar.firstWeekday + 7) % 7
  }

  private var yearRange: [Int] {
    let year = calendar.component(.year, from: monthDate)
    return Array((year - 10)...(year + 10))
  }

  private var weeks: [CalendarWeek] {
    stride(from: 0, to: days.count, by: 7).map { index in
      let weekDays = Array(days[index..<min(index + 7, days.count)])
      return CalendarWeek(
        id: weekDays.first?.date ?? monthStart,
        number: weekNumber(for: weekDays.first?.date ?? monthStart), days: weekDays)
    }
  }

  private var days: [CalendarDay] {
    let currentMonth = calendar.component(.month, from: monthStart)

    return (-leadingDays..<(42 - leadingDays)).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: monthStart) else {
        return nil
      }
      let eventColors = eventsForDay(date)
        .prefix(3)
        .map(eventAccentColor)
      return CalendarDay(
        id: date,
        date: date,
        number: calendar.component(.day, from: date),
        column: (offset + leadingDays) % 7,
        isInMonth: calendar.component(.month, from: date) == currentMonth,
        isToday: calendar.isDate(date, inSameDayAs: Date()),
        isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
        eventColors: Array(eventColors)
      )
    }
  }

  private func weekNumber(for date: Date) -> Int {
    calendar.component(.weekOfYear, from: date)
  }

  private func changeMonth(by value: Int) {
    monthDate = calendar.date(byAdding: .month, value: value, to: monthDate) ?? monthDate
  }

  private func setYear(_ year: Int) {
    let month = calendar.component(.month, from: monthDate)
    let selectedDay = calendar.component(.day, from: selectedDate)
    let cappedDay = min(selectedDay, daysInMonth(year: year, month: month))
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = timeZone
    components.year = year
    components.month = month
    components.day = cappedDay
    guard let nextDate = calendar.date(from: components) else { return }
    monthDate = nextDate
    selectedDate = nextDate
  }

  private func daysInMonth(year: Int, month: Int) -> Int {
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = timeZone
    components.year = year
    components.month = month
    components.day = 1
    guard let date = calendar.date(from: components) else { return 30 }
    return calendar.range(of: .day, in: .month, for: date)?.count ?? 30
  }

  private func monthBoundary(for day: CalendarDay) -> some View {
    GeometryReader { proxy in
      let lineWidth: CGFloat = 1.4
      let color = Color.primary.opacity(0.72)
      ZStack {
        if drawsMonthBoundary(day, dayOffset: -7) {
          Rectangle()
            .fill(color)
            .frame(height: lineWidth)
            .position(x: proxy.size.width / 2, y: lineWidth / 2)
        }
        if drawsMonthBoundary(day, dayOffset: 7) {
          Rectangle()
            .fill(color)
            .frame(height: lineWidth)
            .position(x: proxy.size.width / 2, y: proxy.size.height - lineWidth / 2)
        }
        if day.column == 0 || drawsMonthBoundary(day, dayOffset: -1) {
          Rectangle()
            .fill(color)
            .frame(width: lineWidth)
            .position(x: lineWidth / 2, y: proxy.size.height / 2)
        }
        if day.column == 6 || drawsMonthBoundary(day, dayOffset: 1) {
          Rectangle()
            .fill(color)
            .frame(width: lineWidth)
            .position(x: proxy.size.width - lineWidth / 2, y: proxy.size.height / 2)
        }
      }
    }
    .opacity(day.isInMonth ? 1 : 0)
  }

  private func drawsMonthBoundary(_ day: CalendarDay, dayOffset: Int) -> Bool {
    guard day.isInMonth,
      let adjacentDate = calendar.date(byAdding: .day, value: dayOffset, to: day.date)
    else { return false }
    return calendar.component(.month, from: adjacentDate)
      != calendar.component(.month, from: monthStart)
  }

  private func dayBackground(for day: CalendarDay) -> some ShapeStyle {
    if day.isSelected {
      return Color.blue.opacity(0.16)
    }
    if isHovered(day) {
      return Color.blue.opacity(0.08)
    }
    if day.isToday {
      return Color.orange.opacity(0.12)
    }
    return Color.clear
  }

  private func dayBorder(for day: CalendarDay) -> some View {
    RoundedRectangle(cornerRadius: 9, style: .continuous)
      .stroke(dayBorderColor(for: day), lineWidth: day.isSelected ? 2 : 1)
  }

  private func dayBorderColor(for day: CalendarDay) -> Color {
    if day.isSelected {
      return .blue
    }
    if isHovered(day) {
      return .blue.opacity(0.45)
    }
    return .clear
  }

  private func isHovered(_ day: CalendarDay) -> Bool {
    hoveredDate.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
  }

  private func dayHelpText(for day: CalendarDay) -> String {
    let events = eventsForDay(day.date)
    let eventSummary =
      events.isEmpty ? "No events" : "\(events.count) \(events.count == 1 ? "event" : "events")"
    return "\(dateTooltipText(for: day.date)) • \(eventSummary) • Click to select"
  }

  private func eventsForDay(_ date: Date) -> [CalendarEventInfo] {
    events.filter { calendar.isDate($0.startDate, inSameDayAs: date) }
  }

  private func dateTooltipText(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEEE, MMM d, yyyy"
    return formatter.string(from: date)
  }
}

private struct CalendarDay: Identifiable {
  let id: Date
  let date: Date
  let number: Int
  let column: Int
  let isInMonth: Bool
  let isToday: Bool
  let isSelected: Bool
  let eventColors: [Color]
}

private struct CalendarWeek: Identifiable {
  let id: Date
  let number: Int
  let days: [CalendarDay]
}

private struct AgendaList: View {
  let events: [CalendarEventInfo]
  let timeZone: TimeZone
  let weekStartDay: WeekStartDay

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Next 7 Days")
          .font(.headline)
        Spacer()
        Text(dateRangeText)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      if weekEvents.isEmpty {
        Text("No events in the next 7 days.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.secondary.opacity(0.06))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        ForEach(groupedWeekEvents) { group in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
              Text(group.title)
                .font(.subheadline.weight(.semibold))
              Spacer()
              Text(group.dateText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            ForEach(group.events) { event in
              EventRow(event: event, timeZone: timeZone, accent: eventAccentColor(for: event))
            }
          }
        }
      }
    }
  }

  private var calendar: Calendar {
    gregorianCalendar(for: timeZone, weekStartDay: weekStartDay)
  }

  private var weekEvents: [CalendarEventInfo] {
    let start = Date()
    let end =
      calendar.date(byAdding: .day, value: 7, to: start)
      ?? start.addingTimeInterval(7 * 24 * 60 * 60)
    return
      events
      .filter { $0.endDate >= start && $0.startDate < end }
      .sorted { $0.startDate < $1.startDate }
  }

  private var groupedWeekEvents: [AgendaDayGroup] {
    let grouped = Dictionary(grouping: weekEvents) { event in
      calendar.startOfDay(for: event.startDate)
    }
    return grouped.keys.sorted().map { day in
      AgendaDayGroup(
        id: day,
        title: dayTitle(for: day),
        dateText: shortDateText(for: day),
        events: grouped[day]?.sorted { $0.startDate < $1.startDate } ?? []
      )
    }
  }

  private var dateRangeText: String {
    let start = Date()
    let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
    return "\(shortDateText(for: start)) – \(shortDateText(for: end))"
  }

  private func dayTitle(for date: Date) -> String {
    if calendar.isDate(date, inSameDayAs: Date()) {
      return "Today"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
      calendar.isDate(date, inSameDayAs: tomorrow)
    {
      return "Tomorrow"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEEE"
    return formatter.string(from: date)
  }

  private func shortDateText(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
  }
}

private struct AgendaDayGroup: Identifiable {
  let id: Date
  let title: String
  let dateText: String
  let events: [CalendarEventInfo]
}

private struct TimeZonePicker: View {
  let title: String
  @Binding var selection: String

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(TimeZoneCatalog.identifiers, id: \.self) { identifier in
        Text(TimeZoneCatalog.displayName(for: identifier)).tag(identifier)
      }
    }
  }
}

private struct EventRow: View {
  let event: CalendarEventInfo
  let timeZone: TimeZone
  let accent: Color

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(accent)
        .frame(width: 5, height: 28)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(event.title)
            .font(.subheadline.weight(.medium))
            .lineLimit(2)
          Spacer(minLength: 8)
          Text(timeText)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        Text(event.calendarTitle)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(accent.opacity(0.09))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var timeText: String {
    if event.isAllDay {
      return "All day"
    }

    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: event.startDate)
  }
}
