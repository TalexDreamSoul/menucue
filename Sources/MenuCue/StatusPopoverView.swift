import AppKit
import Foundation
import SwiftUI

private let eventAccentPalette: [Color] = [.orange, .purple, .blue, .green, .pink]

private func gregorianCalendar(for timeZone: TimeZone, weekStartDay: WeekStartDay) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = .autoupdatingCurrent
  calendar.timeZone = timeZone
  calendar.firstWeekday = weekStartDay.firstWeekday
  return calendar
}

private func eventAccentColor(for event: CalendarEventInfo) -> Color {
  let scalarTotal = event.calendarTitle.unicodeScalars.reduce(0) { $0 + Int($1.value) }
  return eventAccentPalette[scalarTotal % eventAccentPalette.count]
}

enum PopoverTab: String, CaseIterable, Identifiable {
  case status
  case calendar
  case actions

  var id: String { rawValue }

  func moving(by offset: Int) -> PopoverTab {
    let tabs = Self.allCases
    guard let index = tabs.firstIndex(of: self) else { return self }
    return tabs[(index + offset + tabs.count) % tabs.count]
  }

  static func allowsNavigation(modifiers: EventModifiers) -> Bool {
    let shortcutModifiers: EventModifiers = [.shift, .control, .option, .command]
    return modifiers.intersection(shortcutModifiers).isEmpty
  }

  var title: String {
    switch self {
    case .status: return L10n.string("Status")
    case .calendar: return L10n.string("Calendar")
    case .actions: return L10n.string("Actions")
    }
  }

  var systemImage: String {
    switch self {
    case .status: return "waveform.path.ecg"
    case .calendar: return "calendar"
    case .actions: return "square.grid.2x2"
    }
  }
}

struct StatusPopoverView: View {
  @ObservedObject var model: AppModel
  let openSettings: () -> Void
  /// Opens the Settings window on the Quick Actions pane, which is also where the
  /// full action catalog is run from.
  let openQuickActionSettings: () -> Void
  /// Opens the Settings window on the Dashboard, pre-selected to a metric's tab.
  let openDashboard: (DashboardSection) -> Void
  let quitApp: () -> Void
  /// Publishes sideways flicks recognized by the AppKit container that hosts this view.
  @ObservedObject var swipeRelay: PopoverSwipeRelay
  @StateObject private var metrics = SystemMetricsService()
  @State private var selectedTab: PopoverTab = .status
  @State private var visibleMonthDate = Date()
  @State private var selectedCalendarDate = Date()
  @State private var quickEventDraft: QuickEventDraft?
  /// Which way the next tab change travels. Set before `selectedTab` so the
  /// transition below is already pointing the right way when SwiftUI evaluates it.
  @State private var navigationDirection = 1
  @FocusState private var isPopoverFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      PopoverTabBar(selection: tabSelection)
        .padding(.horizontal, PopoverMetrics.contentPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)

      Divider()
        .opacity(0.5)

      tabContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The outgoing and incoming tabs overlap while sliding; without this they
        // spill past the dividers onto the tab bar and the footer.
        .clipped()

      Divider()
        .opacity(0.5)

      PopoverFooter(
        bootDate: metrics.bootDate,
        openSettings: openSettings,
        openQuickActionSettings: openQuickActionSettings,
        newEvent: openQuickEventEditor,
        quitApp: quitApp
      )
      .padding(.horizontal, PopoverMetrics.contentPadding)
      .padding(.vertical, 7)
    }
    .frame(width: PopoverMetrics.width, height: PopoverMetrics.height, alignment: .top)
    .background(Color(nsColor: .windowBackgroundColor))
    .focusable()
    .focused($isPopoverFocused)
    .focusEffectDisabled()
    .onAppear {
      isPopoverFocused = true
    }
    .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
      guard PopoverTab.allowsNavigation(modifiers: press.modifiers) else { return .ignored }
      let offset = press.key == .leftArrow ? -1 : 1
      select(selectedTab.moving(by: offset), direction: offset)
      return .handled
    }
    .onChange(of: swipeRelay.command) { _, command in
      guard let command else { return }
      select(selectedTab.moving(by: command.direction), direction: command.direction)
    }
    .sheet(isPresented: quickEventSheetBinding) {
      quickEventSheet
    }
  }

  /// Routes every tab-bar tap through `select` so a click animates the same way a
  /// swipe or an arrow key does.
  private var tabSelection: Binding<PopoverTab> {
    Binding(
      get: { selectedTab },
      set: { tab in
        let tabs = PopoverTab.allCases
        guard
          let from = tabs.firstIndex(of: selectedTab),
          let to = tabs.firstIndex(of: tab)
        else { return }
        select(tab, direction: to >= from ? 1 : -1)
      }
    )
  }

  private func select(_ tab: PopoverTab, direction: Int) {
    guard tab != selectedTab else { return }
    navigationDirection = direction
    withAnimation(PopoverMotion.navigation) {
      selectedTab = tab
    }
  }

  /// Tabs slide in from the side they came from, so the motion matches the gesture
  /// that caused it — the outgoing tab leaves the way the incoming one arrives.
  private var tabTransition: AnyTransition {
    let forward = navigationDirection >= 0
    return .asymmetric(
      insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
      removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
    )
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .status:
      StatusTabView(
        model: model,
        metrics: metrics,
        openAllActions: { select(.actions, direction: 1) },
        openDashboard: openDashboard
      )
      .transition(tabTransition)
    case .calendar:
      calendarTab
        .transition(tabTransition)
    case .actions:
      ActionsTabView(model: model, openSettings: openQuickActionSettings)
        .transition(tabTransition)
    }
  }

  private var calendarTab: some View {
    ScrollView {
      VStack(spacing: PopoverMetrics.cardSpacing) {
        // Scoped to the clock card. Wrapping the whole ScrollView in a 1 Hz
        // TimelineView rebuilt the calendar and agenda every second, which fought
        // with scroll momentum.
        TimelineView(.periodic(from: Date(), by: 1)) { context in
          clockCard(date: context.date)
        }
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
      .padding(.horizontal, PopoverMetrics.contentPadding)
      .padding(.vertical, 2)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private func clockCard(date: Date) -> some View {
    PopoverCard(title: "World Clocks", systemImage: "globe.desk", tint: .indigo) {
      Text("\(model.settings.clockTimeZones.count)")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
    } content: {
      ForEach(model.settings.clockTimeZones) { clock in
        ClockCard(clock: clock, date: date)
      }
    }
  }

  private var eventsSection: some View {
    PopoverCard(title: "Events", systemImage: "calendar.badge.clock", tint: .orange) {
      Button {
        openQuickEventEditor()
      } label: {
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
      .buttonStyle(.plain)
      .help("New Event")
      .disabled(
        !model.authorizationState.canReadEvents && model.authorizationState != .notDetermined)
    } content: {
      if !model.authorizationState.canReadEvents {
        VStack(alignment: .leading, spacing: 8) {
          Text("Grant Calendar access to show iCloud and local Calendar events.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Grant Calendar Access") {
            model.requestCalendarAccess()
          }
          .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    "Focus", "Planning", "Learning", "Socializing", "Travel", "Exercise",
    "Organizing", "Creating", "Communication", "Rest", "Reflection", "Starting",
  ].map(L10n.string)
  private static let unfavorableActivities = [
    "Procrastination", "Staying up late", "Impulse spending", "Overcommitting",
    "Hasty decisions", "Arguments", "Risk-taking", "Sitting too long", "Distraction",
    "Forcing outcomes",
  ].map(L10n.string)

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

      guideRow(label: L10n.string("Good for"), color: .green, activities: guide.favorable)
      guideRow(label: L10n.string("Avoid"), color: .red, activities: guide.unfavorable)
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
    formatter.locale = .autoupdatingCurrent
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
  @ObservedObject var updateService: UpdateService
  @ObservedObject var languageService: AppLanguageService
  @State private var selectedPane: SettingsPane
  /// Which Dashboard tab a popover card deep-linked to. Only read when the window
  /// opens on `.dashboard`; `showSettingsWindow` rebuilds this view on every call,
  /// so a repeat deep-link re-honors it.
  private let initialDashboardSection: DashboardSection

  init(
    model: AppModel,
    updateService: UpdateService,
    languageService: AppLanguageService,
    initialPane: SettingsPane = .overview,
    initialDashboardSection: DashboardSection = .cpu
  ) {
    self.model = model
    self.updateService = updateService
    self.languageService = languageService
    self.initialDashboardSection = initialDashboardSection
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
      SettingsContentView(
        model: model,
        updateService: updateService,
        languageService: languageService,
        pane: selectedPane,
        initialDashboardSection: initialDashboardSection,
        selectPane: { pane in
          withAnimation(PopoverMotion.navigation) { selectedPane = pane }
        }
      )
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
  case dashboard
  case overview
  case dateAndEvents
  case quickActions
  case menuBarTimeZones
  case appearance
  case calendars
  case iCloud
  case languageAndRegion
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dashboard: return L10n.string("Dashboard")
    case .overview: return L10n.string("Overview")
    case .dateAndEvents: return L10n.string("Date & Events")
    case .quickActions: return L10n.string("Quick Actions")
    case .menuBarTimeZones: return L10n.string("Menu Bar")
    case .appearance: return L10n.string("Appearance")
    case .calendars: return L10n.string("Calendars")
    case .iCloud: return L10n.string("iCloud Sync")
    case .languageAndRegion: return L10n.string("Language & Region")
    case .about: return L10n.string("About")
    }
  }

  var subtitle: String {
    switch self {
    case .dashboard:
      return L10n.string("Live CPU, GPU, memory, storage, network, and sensor readings.")
    case .overview:
      return L10n.string(
        "This Mac at a glance, sampling behavior, and anything needing attention.")
    case .dateAndEvents:
      return L10n.string("Calendar display, overview time zone, and week layout.")
    case .quickActions:
      return L10n.string("Run any action, pin your favorites, and manage Apple Shortcuts.")
    case .menuBarTimeZones:
      return L10n.string("Status item clocks and rotation behavior.")
    case .appearance:
      return L10n.string("App appearance and optional macOS Light/Dark automation.")
    case .calendars:
      return L10n.string("Calendar permissions and event sources.")
    case .iCloud:
      return L10n.string("Portable preferences, conflict choices, and synchronization status.")
    case .languageAndRegion:
      return L10n.string("MenuCue language and macOS system region controls.")
    case .about:
      return L10n.string("Version, GitHub releases, and project links.")
    }
  }

  var systemImage: String {
    switch self {
    case .dashboard: return "chart.line.uptrend.xyaxis"
    case .overview: return "gauge.with.dots.needle.33percent"
    case .dateAndEvents: return "calendar"
    case .quickActions: return "square.grid.2x2"
    case .menuBarTimeZones: return "menubar.rectangle"
    case .appearance: return "circle.lefthalf.filled"
    case .calendars: return "calendar.badge.clock"
    case .iCloud: return "icloud"
    case .languageAndRegion: return "globe"
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
  @ObservedObject var updateService: UpdateService
  @ObservedObject var languageService: AppLanguageService
  let pane: SettingsPane
  var initialDashboardSection: DashboardSection = .cpu
  let selectPane: (SettingsPane) -> Void
  @State private var pendingTimeZoneID = TimeZone.autoupdatingCurrent.identifier

  var body: some View {
    // The Dashboard pins its own tab bar and scrolls per tab, so it opts out of the
    // shared scroll container rather than nesting one inside another.
    if pane == .dashboard {
      DashboardView(model: model, initialSection: initialDashboardSection)
        .background(Color(nsColor: .windowBackgroundColor))
    } else {
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
  }

  @ViewBuilder
  private var selectedPaneContent: some View {
    switch pane {
    case .dashboard:
      // Handled in `body` before this switch is reached.
      EmptyView()
    case .overview:
      OverviewSettingsView(
        model: model, updateService: updateService, selectPane: selectPane)
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
    case .languageAndRegion:
      LanguageRegionSettingsView(
        languageService: languageService,
        powerHelper: model.quickActionService.powerHelperManager
      )
    case .about:
      aboutSection
    }
  }

  private var overviewSettingsSection: some View {
    SettingsGroup {
      TimeZonePicker(
        title: L10n.string("Display time zone"),
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
        L10n.format(
          "Switch every %ds",
          Int(model.settings.statusBarSwitchIntervalSeconds)
        ),
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
          title: L10n.string("Auto reference"),
          selection: binding(\.appearanceTimeZoneID)
        )
        .frame(maxWidth: 460)
        Text("Auto uses light from 07:00-19:00 in the selected time zone.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Toggle("Apply to macOS system appearance", isOn: binding(\.appliesSystemAppearance))

      Text(
        "When enabled, MenuCue switches the system Light/Dark appearance via macOS Automation permissions. When disabled, only this app previews the selected appearance."
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
        Text(ProductBrand.displayName)
          .font(.title2.weight(.semibold))
        Text(L10n.format("Version %@", appVersion))
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Startup")
          .font(.headline)
        Toggle("Launch MenuCue at login", isOn: launchAtLoginBinding)
          .disabled(model.launchAtLoginState == .unavailable)

        switch model.launchAtLoginState {
        case .disabled:
          Text("MenuCue starts only when you open it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .enabled:
          Text("MenuCue will start automatically after you sign in.")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .requiresApproval:
          Text("macOS requires approval before MenuCue can start at login.")
            .font(.caption)
            .foregroundStyle(.orange)
          Button("Open Login Items Settings") {
            model.openLoginItemsSettings()
          }
        case .unavailable:
          Text(
            "Launch at Login is available when MenuCue runs from its app bundle."
          )
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

      VStack(alignment: .leading, spacing: 10) {
        Text("Updates")
          .font(.headline)

        Toggle(
          "Automatically check and download updates",
          isOn: automaticUpdatesBinding
        )

        Text(updateStatusMessage)
          .font(.caption)
          .foregroundStyle(updateStatusIsError ? Color.red : Color.secondary)

        if let lastCheckText {
          Text(lastCheckText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        Button("Check for Updates") {
          updateService.checkForUpdates()
        }
        .disabled(!updateService.canCheckForUpdates)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Links")
          .font(.headline)
        HStack(spacing: 10) {
          Button("GitHub Repository") {
            openURL("https://github.com/TalexDreamSoul/menucue")
          }
          Button("Release Notes") {
            openURL("https://github.com/TalexDreamSoul/menucue/releases")
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
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.4"
  }

  private var automaticUpdatesBinding: Binding<Bool> {
    Binding(
      get: { updateService.automaticUpdatesEnabled },
      set: { updateService.setAutomaticUpdatesEnabled($0) }
    )
  }

  private var updateStatusMessage: String {
    switch updateService.status {
    case .idle:
      return updateService.automaticUpdatesEnabled
        ? L10n.string("MenuCue checks for updates every 12 hours.")
        : L10n.string("Automatic updates are off. Manual checks remain available.")
    case .checking:
      return L10n.string("Checking for updates...")
    case .available(let version):
      return L10n.format("Version %@ is available.", version)
    case .downloading(let version):
      return L10n.format("Downloading version %@...", version)
    case .downloaded(let version):
      return L10n.format("Version %@ is downloaded and ready to install.", version)
    case .installing(let version):
      return L10n.format("Installing version %@...", version)
    case .current:
      return L10n.string("MenuCue is up to date.")
    case .failed(let message):
      return L10n.format("Update failed: %@", message)
    }
  }

  private var updateStatusIsError: Bool {
    if case .failed = updateService.status { return true }
    return false
  }

  private var lastCheckText: String? {
    updateService.lastUpdateCheckDate.map { date in
      L10n.format(
        "Last checked %@.",
        date.formatted(date: .abbreviated, time: .shortened)
      )
    }
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

private struct ClockCard: View {
  let clock: ClockTimeZone
  let date: Date

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          // Real signal, not decoration: tells you at a glance whether it is a
          // reasonable hour to contact someone there.
          Image(systemName: isDaytime ? "sun.max.fill" : "moon.stars.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isDaytime ? Color.orange : Color.indigo)
          Text(clock.title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
        }
        Text(clock.subtitle)
          .font(.system(size: 9.5))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(timeText)
          .font(.system(size: 16, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Text(dateText)
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    // Region flag bled off the trailing edge as a watermark. Stacked behind the
    // fill so it sits under the text, and clipped by the card's own shape.
    .background(alignment: .trailing) {
      Text(clock.flag)
        .font(.system(size: 54))
        .opacity(0.32)
        .offset(x: 8)
        .accessibilityHidden(true)
    }
    // Wash pulled from the flag's own two dominant hues, so every region reads
    // differently without a hand-maintained country palette.
    .background(tint.gradient)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(tint.primary.opacity(0.30), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var tint: FlagTint {
    FlagPalette.tint(for: clock.flag)
  }

  private var isDaytime: Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = clock.timeZone
    let hour = calendar.component(.hour, from: date)
    return (6..<18).contains(hour)
  }

  private var timeText: String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = clock.timeZone
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  private var dateText: String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
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

  private let weekNumberColumnWidth: CGFloat = 22
  private let dateCellHeight: CGFloat = 27
  private let weekdayRowHeight: CGFloat = 20
  /// Day columns flex so the grid spans the whole card. Fixed-width columns left
  /// roughly a third of the card empty on the trailing edge.
  private var columns: [GridItem] {
    [GridItem(.fixed(weekNumberColumnWidth), spacing: 0)]
      + Array(repeating: GridItem(.flexible(minimum: 24), spacing: 0), count: 7)
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
          .font(.system(size: 13, weight: .bold))
        // The month stays outside the Menu: `.borderlessButton` renders only the
        // first text element of a custom label, which silently dropped the year.
        Menu {
          ForEach(yearRange, id: \.self) { year in
            Button {
              withAnimation(PopoverMotion.navigation) { setYear(year) }
            } label: {
              Text(verbatim: String(year))
            }
          }
        } label: {
          Text(yearTitle)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Spacer(minLength: 4)

        CalendarNavButton(systemImage: "chevron.left", help: "Previous month") {
          withAnimation(PopoverMotion.navigation) { changeMonth(by: -1) }
        }
        CalendarNavButton(title: "Today", help: "Jump to today") {
          withAnimation(PopoverMotion.navigation) {
            monthDate = Date()
            selectedDate = Date()
          }
        }
        CalendarNavButton(systemImage: "chevron.right", help: "Next month") {
          withAnimation(PopoverMotion.navigation) { changeMonth(by: 1) }
        }
      }
      .animation(PopoverMotion.navigation, value: monthName)

      LazyVGrid(columns: columns, alignment: .center, spacing: 0) {
        Text("")
          .frame(width: weekNumberColumnWidth, height: weekdayRowHeight)
        ForEach(Array(weekdayTitles.enumerated()), id: \.offset) { _, title in
          Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: weekdayRowHeight)
        }

        ForEach(weeks) { week in
          Text(verbatim: String(week.number))
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.quaternary)
            .frame(width: weekNumberColumnWidth, height: dateCellHeight, alignment: .center)

          ForEach(week.days) { day in
            Button {
              withAnimation(PopoverMotion.state) {
                selectedDate = day.date
                monthDate = day.date
              }
            } label: {
              VStack(spacing: 2) {
                Text(verbatim: String(day.number))
                  .font(.system(size: 12.5, weight: dayWeight(for: day), design: .rounded))
                  .foregroundStyle(dayForeground(for: day))
                HStack(spacing: 2) {
                  ForEach(Array(day.eventColors.enumerated()), id: \.offset) { _, color in
                    Circle()
                      .fill(day.isSelected ? Color.white.opacity(0.85) : color)
                      .frame(width: 3, height: 3)
                  }
                }
                .frame(height: 3)
              }
              // The chip is sized independently of the flexible column so the
              // selection reads as a rounded square instead of a full-width bar.
              .frame(width: 32, height: 25)
              .background(
                dayChipFill(for: day),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
              )
              .frame(maxWidth: .infinity)
              .frame(height: dateCellHeight)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(dayHelpText(for: day))
            .onHover { isHovering in
              withAnimation(PopoverMotion.hover) {
                // Only the cell that owns the current hover may clear it, otherwise
                // the exit event of the previous cell wipes the new one.
                hoveredDate = isHovering ? day.date : (isHovered(day) ? nil : hoveredDate)
              }
            }
          }
        }
      }
      .overlay(monthOutline)
      .animation(PopoverMotion.navigation, value: monthStart)

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
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM"
    return formatter.string(from: monthDate)
  }

  private var yearTitle: String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy"
    return formatter.string(from: monthDate)
  }

  private var selectedDateText: String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
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
      if hours == 0 {
        return L10n.string("Less than 1 hour ago")
      }
      return hours == 1
        ? L10n.format("%d hour ago", hours)
        : L10n.format("%d hours ago", hours)
    }

    let days = abs(calendar.dateComponents([.day], from: todayStart, to: selectedStart).day ?? 0)
    if selectedStart < todayStart {
      return days == 1
        ? L10n.format("%d day ago", days)
        : L10n.format("%d days ago", days)
    }
    return days == 1
      ? L10n.format("In %d day", days)
      : L10n.format("In %d days", days)
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

  /// Hairline outline tracing the visible month. Built as one continuous path so
  /// the staircase corners can be filleted — the previous per-cell edges were four
  /// separate rectangles and could only ever meet at right angles.
  private var monthOutline: some View {
    GeometryReader { proxy in
      let cellWidth = (proxy.size.width - weekNumberColumnWidth) / 7
      let cellHeight = (proxy.size.height - weekdayRowHeight) / CGFloat(max(1, weeks.count))
      monthOutlinePath(
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        radius: min(7, cellHeight / 2 - 1)
      )
      .stroke(
        Color.primary.opacity(0.16),
        style: StrokeStyle(lineWidth: 1, lineJoin: .round)
      )
    }
    .allowsHitTesting(false)
  }

  /// The visible month is always one contiguous run of cells, so its outline is a
  /// staircase with at most eight corners.
  private func monthOutlinePath(cellWidth: CGFloat, cellHeight: CGFloat, radius: CGFloat) -> Path {
    let firstIndex = leadingDays
    let lastIndex = leadingDays + daysInVisibleMonth - 1
    let firstRow = firstIndex / 7
    let firstColumn = firstIndex % 7
    let lastRow = lastIndex / 7
    let lastColumn = lastIndex % 7

    func corner(column: Int, row: Int) -> CGPoint {
      CGPoint(
        x: weekNumberColumnWidth + CGFloat(column) * cellWidth,
        y: weekdayRowHeight + CGFloat(row) * cellHeight
      )
    }

    // Clockwise from the first day of the month.
    let corners = [
      corner(column: firstColumn, row: firstRow),
      corner(column: 7, row: firstRow),
      corner(column: 7, row: lastRow),
      corner(column: lastColumn + 1, row: lastRow),
      corner(column: lastColumn + 1, row: lastRow + 1),
      corner(column: 0, row: lastRow + 1),
      corner(column: 0, row: firstRow + 1),
      corner(column: firstColumn, row: firstRow + 1),
    ]
    return Self.roundedPath(through: Self.pruningStraightRuns(corners), radius: radius)
  }

  /// Months starting on the first weekday, or ending on the last, degenerate some
  /// corners into duplicates or straight runs. Filleting those would bulge the line.
  private static func pruningStraightRuns(_ points: [CGPoint]) -> [CGPoint] {
    var distinct: [CGPoint] = []
    for point in points where !(distinct.last.map { isSamePoint($0, point) } ?? false) {
      distinct.append(point)
    }
    if let first = distinct.first, let last = distinct.last, distinct.count > 1,
      isSamePoint(first, last)
    {
      distinct.removeLast()
    }
    guard distinct.count > 2 else { return distinct }

    return distinct.indices.compactMap { index in
      let point = distinct[index]
      let previous = distinct[(index - 1 + distinct.count) % distinct.count]
      let next = distinct[(index + 1) % distinct.count]
      let cross =
        (point.x - previous.x) * (next.y - point.y) - (point.y - previous.y) * (next.x - point.x)
      return abs(cross) < 0.01 ? nil : point
    }
  }

  private static func isSamePoint(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
    abs(lhs.x - rhs.x) < 0.01 && abs(lhs.y - rhs.y) < 0.01
  }

  private static func roundedPath(through corners: [CGPoint], radius: CGFloat) -> Path {
    var path = Path()
    guard corners.count > 2, radius > 0 else {
      guard let start = corners.first else { return path }
      path.move(to: start)
      corners.dropFirst().forEach { path.addLine(to: $0) }
      path.closeSubpath()
      return path
    }

    // Starting mid-edge keeps the first arc from being clipped by the initial move.
    let last = corners[corners.count - 1]
    path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
    for index in corners.indices {
      path.addArc(
        tangent1End: corners[index],
        tangent2End: corners[(index + 1) % corners.count],
        radius: radius
      )
    }
    path.closeSubpath()
    return path
  }

  /// Selection is a filled chip and today is a tinted chip; the rest is carried by
  /// type color rather than per-cell borders.
  private func dayChipFill(for day: CalendarDay) -> Color {
    if day.isSelected { return .accentColor }
    if day.isToday { return .accentColor.opacity(0.14) }
    if isHovered(day) { return .primary.opacity(0.07) }
    return .clear
  }

  private func dayForeground(for day: CalendarDay) -> Color {
    if day.isSelected { return .white }
    if day.isToday { return .accentColor }
    return day.isInMonth ? .primary : .secondary.opacity(0.4)
  }

  private func dayWeight(for day: CalendarDay) -> Font.Weight {
    (day.isSelected || day.isToday) ? .bold : .medium
  }

  private func isHovered(_ day: CalendarDay) -> Bool {
    hoveredDate.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
  }

  private func dayHelpText(for day: CalendarDay) -> String {
    let events = eventsForDay(day.date)
    let eventSummary: String
    if events.isEmpty {
      eventSummary = L10n.string("No events")
    } else if events.count == 1 {
      eventSummary = L10n.format("%d event", events.count)
    } else {
      eventSummary = L10n.format("%d events", events.count)
    }
    return L10n.format(
      "%@ • %@ • Click to select",
      dateTooltipText(for: day.date),
      eventSummary
    )
  }

  private func eventsForDay(_ date: Date) -> [CalendarEventInfo] {
    events.filter { calendar.isDate($0.startDate, inSameDayAs: date) }
  }

  private func dateTooltipText(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEEE, MMM d, yyyy"
    return formatter.string(from: date)
  }
}

/// Month navigation control. Uses the popover's own hover language rather than the
/// stock bordered button, which reads far too heavy inside a card.
private struct CalendarNavButton: View {
  var systemImage: String?
  var title: String?
  let help: String
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Group {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 10, weight: .bold))
            .frame(width: 22, height: 20)
        } else if let title {
          Text(L10n.string(title))
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 20)
        }
      }
      .foregroundStyle(isHovering ? Color.primary : Color.secondary)
      .background(
        Color.primary.opacity(isHovering ? 0.09 : 0.05),
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(PressableButtonStyle(pressedScale: 0.92))
    .onHover { hovering in
      withAnimation(PopoverMotion.hover) { isHovering = hovering }
    }
    .help(L10n.string(help))
  }
}

private struct CalendarDay: Identifiable {
  let id: Date
  let date: Date
  let number: Int
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
    return L10n.format(
      "%@ – %@",
      shortDateText(for: start),
      shortDateText(for: end)
    )
  }

  private func dayTitle(for date: Date) -> String {
    if calendar.isDate(date, inSameDayAs: Date()) {
      return L10n.string("Today")
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
      calendar.isDate(date, inSameDayAs: tomorrow)
    {
      return L10n.string("Tomorrow")
    }
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEEE"
    return formatter.string(from: date)
  }

  private func shortDateText(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
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
      return L10n.string("All day")
    }

    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: event.startDate)
  }
}
