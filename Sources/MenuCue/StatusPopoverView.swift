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

/// The published schedule only describes days under the statutory scheme — a plain
/// Monday–Friday week has nothing to say about a holiday, so it stays unlabelled.
private func holidayTag(for date: Date, scheme: WorkdayScheme, calendar: Calendar) -> String? {
  guard scheme == .chineseStatutory,
    let kind = ChineseHolidaySchedule.kind(of: date, calendar: calendar)
  else {
    return nil
  }
  switch kind {
  case .holiday: return L10n.format("%@ · Holiday", kind.name)
  case .makeupWorkday: return L10n.format("%@ · Makeup workday", kind.name)
  }
}

private func eventAccentColor(for event: CalendarEventInfo) -> Color {
  let scalarTotal = event.calendarTitle.unicodeScalars.reduce(0) { $0 + Int($1.value) }
  return eventAccentPalette[scalarTotal % eventAccentPalette.count]
}

extension PopoverTab {
  static func allowsNavigation(modifiers: EventModifiers) -> Bool {
    let shortcutModifiers: EventModifiers = [.shift, .control, .option, .command]
    return modifiers.intersection(shortcutModifiers).isEmpty
  }

  var title: String {
    switch self {
    case .status: return L10n.string("Status")
    case .power: return L10n.string("Power")
    case .calendar: return L10n.string("Calendar")
    case .actions: return L10n.string("Actions")
    }
  }

  var systemImage: String {
    switch self {
    case .status: return "waveform.path.ecg"
    case .power: return "bolt.heart.fill"
    case .calendar: return "calendar"
    case .actions: return "square.grid.2x2"
    }
  }
}

struct StatusPopoverView: View {
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  let quitApp: () -> Void
  /// Publishes sideways flicks recognized by the AppKit container that hosts this view.
  @ObservedObject var swipeRelay: SwipeRelay
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var metrics = SystemMetricsService()
  /// Mirrors `router.popoverTab`, and is what the transition animates against. The
  /// router carries no direction, so the local copy is what tells a tap from a swipe
  /// which way to slide.
  @State private var selectedTab: PopoverTab = .status
  @State private var visibleMonthDate = Date()
  @State private var selectedCalendarDate = Date()
  @State private var calendarPresentationCache = CalendarMonthPresentationCache()
  @State private var quickEventDraft: QuickEventDraft?
  /// Which way the next tab change travels. Set before `selectedTab` so the
  /// transition below is already pointing the right way when SwiftUI evaluates it.
  @State private var navigationDirection = 1
  @FocusState private var isPopoverFocused: Bool

  init(
    model: AppModel,
    quitApp: @escaping () -> Void,
    swipeRelay: SwipeRelay
  ) {
    self.model = model
    self.quitApp = quitApp
    self.swipeRelay = swipeRelay
    // Nothing has asked for a tab yet, so the popover opens on the first one in the
    // user's own order.
    _selectedTab = State(initialValue: model.settings.popoverTabOrder.first ?? .status)
  }

  private var tabs: [PopoverTab] {
    model.settings.popoverTabOrder
  }

  private var motion: MotionProfile {
    MotionProfile(quality: model.settings.animationQuality, reducesMotion: reduceMotion)
  }

  var body: some View {
    VStack(spacing: 0) {
      PopoverTabBar(tabs: tabs, selection: tabSelection)
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
    .menuCueFocusEffectDisabled()
    .onAppear {
      isPopoverFocused = true
    }
    .menuCueHorizontalArrowNavigation { offset in
      select(selectedTab.moving(by: offset, in: tabs), direction: offset)
    }
    .onChange(of: swipeRelay.command) { command in
      guard let command else { return }
      let destination = selectedTab.moving(by: command.direction, in: tabs)
      if ProcessInfo.processInfo.environment["MENUCUE_SWIPE_LOG"] == "1" {
        FileHandle.standardError.write(
          Data("[swipe] TAB \(selectedTab.rawValue) -> \(destination.rawValue)\n".utf8)
        )
      }
      select(destination, direction: command.direction)
    }
    // Both halves compare before writing, so the pair settles after one pass rather
    // than bouncing the value back and forth through SwiftUI's update loop.
    .onChange(of: router.popoverTab) { requested in
      guard let requested, requested != selectedTab else { return }
      select(requested, direction: navigationDirection(to: requested))
    }
    .onChange(of: selectedTab) { tab in
      guard router.popoverTab != tab else { return }
      router.popoverTab = tab
    }
    .sheet(isPresented: quickEventSheetBinding) {
      quickEventSheet
    }
    .environment(\.menuCueMotion, motion)
  }

  /// Routes every tab-bar tap through `select` so a click animates the same way a
  /// swipe or an arrow key does.
  private var tabSelection: Binding<PopoverTab> {
    Binding(
      get: { selectedTab },
      set: { tab in
        select(tab, direction: navigationDirection(to: tab))
      }
    )
  }

  private func navigationDirection(to tab: PopoverTab) -> Int {
    guard
      let from = tabs.firstIndex(of: selectedTab),
      let to = tabs.firstIndex(of: tab)
    else { return 1 }
    return to >= from ? 1 : -1
  }

  private func select(_ tab: PopoverTab, direction: Int) {
    guard tab != selectedTab else { return }
    navigationDirection = direction
    withAnimation(motion.navigationAnimation) {
      selectedTab = tab
    }
    MenuCueHaptics.performAlignment()
  }

  /// Tabs slide in from the side they came from, so the motion matches the gesture
  /// that caused it — the outgoing tab leaves the way the incoming one arrives.
  private var tabTransition: AnyTransition {
    motion.navigationTransition(forward: navigationDirection >= 0)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .status:
      StatusTabView(model: model, metrics: metrics)
        .transition(tabTransition)
    case .power:
      PowerTabView(
        model: model,
        diagnostics: model.powerDiagnosticsService,
        processEnergy: model.processEnergyService,
        processHealth: model.processHealthService
      )
      .transition(tabTransition)
    case .calendar:
      calendarTab
        .transition(tabTransition)
    case .actions:
      ActionsTabView(model: model)
        .transition(tabTransition)
    }
  }

  private var calendarTab: some View {
    PopoverHapticScrollView {
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
          presentationCache: calendarPresentationCache,
          events: model.events,
          timeZone: model.settings.overviewTimeZone,
          weekStartDay: model.settings.calendarWeekStartDay,
          showsLunarCalendar: model.settings.showsLunarCalendar,
          allDayEventDatePolicy: model.settings.allDayEventDatePolicy,
          showsDateDistance: model.settings.calendarShowsDateDistance,
          showsMonthStats: model.settings.calendarShowsMonthStats,
          workdayScheme: model.settings.calendarWorkdayScheme
        )
        .onAppear {
          model.setVisibleCalendarMonth(visibleMonthDate)
        }
        .onChange(of: visibleMonthDate) { value in
          model.setVisibleCalendarMonth(value)
        }
        CalendarDateDetailCard(
          date: selectedCalendarDate,
          events: model.events,
          timeZone: model.settings.overviewTimeZone,
          weekStartDay: model.settings.calendarWeekStartDay,
          showsLunarCalendar: model.settings.showsLunarCalendar,
          allDayEventDatePolicy: model.settings.allDayEventDatePolicy,
          showsDateDistance: model.settings.calendarShowsDateDistance,
          workdayScheme: model.settings.calendarWorkdayScheme
        )
        eventsSection
      }
    }
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
      if let guidance = model.calendarPermissionGuidance {
        VStack(alignment: .leading, spacing: 8) {
          Text(guidance.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(guidance.action.buttonTitle) {
            model.performCalendarPermissionAction(guidance.action)
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
          weekStartDay: model.settings.calendarWeekStartDay,
          allDayEventDatePolicy: model.settings.allDayEventDatePolicy
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

private struct CalendarDateDetailCard: View {
  let date: Date
  let events: [CalendarEventInfo]
  let timeZone: TimeZone
  let weekStartDay: WeekStartDay
  let showsLunarCalendar: Bool
  let allDayEventDatePolicy: AllDayEventDatePolicy
  let showsDateDistance: Bool
  let workdayScheme: WorkdayScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("Date Details")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(dateText)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      if showsDateDistance {
        HStack(spacing: 6) {
          Label(distanceText, systemImage: "clock.arrow.circlepath")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          if let holidayText {
            Text(holidayText)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(Color.accentColor)
          }
          Spacer(minLength: 0)
        }
      }

      if let lunarInfo {
        Label(lunarInfo.fullText, systemImage: "moon.stars")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        if !lunarInfo.sexagenaryYearText.isEmpty {
          Text(L10n.format("Sexagenary year: %@", lunarInfo.sexagenaryYearText))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if let dateContextTitle {
          Label(dateContextTitle, systemImage: "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
      }

      Divider()

      Text("Selected date events")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      if selectedEvents.isEmpty {
        Text("No events on this date.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(selectedEvents.prefix(4)) { event in
          SelectedDateEventRow(
            event: event,
            timeZone: timeZone,
            accent: eventAccentColor(for: event)
          )
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var civilDate: CivilDateKey {
    CivilDateKey(date: date, timeZone: timeZone)
  }

  private var calendar: Calendar {
    gregorianCalendar(for: timeZone, weekStartDay: weekStartDay)
  }

  private var distanceText: String {
    WorkdayCalculator.distance(from: Date(), to: date, calendar: calendar).localizedDescription
  }

  private var holidayText: String? {
    holidayTag(for: date, scheme: workdayScheme, calendar: calendar)
  }

  private var lunarInfo: LunarDateInfo? {
    guard showsLunarCalendar else { return nil }
    return LunarDateProvider(timeZone: timeZone, locale: L10n.appLocale).info(for: date)
  }

  private var solarTerm: SolarTerm? {
    guard showsLunarCalendar else { return nil }
    return SolarTermStore.bundled?.term(on: civilDate)
  }

  private var dateContextTitle: String? {
    lunarInfo?.festival?.title ?? solarTerm?.title
  }

  private var selectedEvents: [CalendarEventInfo] {
    EventDateProjector.eventsByCivilDate(
      events,
      timeZone: timeZone,
      allDayPolicy: allDayEventDatePolicy
    )[civilDate] ?? []
  }

  private var dateText: String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEE, MMM d, yyyy"
    return formatter.string(from: date)
  }
}

private struct SelectedDateEventRow: View {
  let event: CalendarEventInfo
  let timeZone: TimeZone
  let accent: Color

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(accent)
        .frame(width: 3, height: 28)

      VStack(alignment: .leading, spacing: 1) {
        Text(event.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Text(event.calendarTitle)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      Text(timeText)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
  }

  private var timeText: String {
    guard !event.isAllDay else { return L10n.string("All day") }
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: event.startDate)
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
  @Environment(\.menuCueMotion) private var motion
  @Binding var monthDate: Date
  @Binding var selectedDate: Date
  let presentationCache: CalendarMonthPresentationCache
  let events: [CalendarEventInfo]
  let timeZone: TimeZone
  let weekStartDay: WeekStartDay
  let showsLunarCalendar: Bool
  let allDayEventDatePolicy: AllDayEventDatePolicy
  let showsDateDistance: Bool
  let showsMonthStats: Bool
  let workdayScheme: WorkdayScheme
  @State private var hoveredDate: Date?

  private let weekNumberColumnWidth: CGFloat = 22
  private var dateCellHeight: CGFloat { showsLunarCalendar ? 39 : 27 }
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
              withAnimation(motion.navigationAnimation) { setYear(year) }
            } label: {
              Text(verbatim: String(year))
            }
          }
        } label: {
          Text(yearTitle)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.secondary)
            .menuCueNumericTransition(value: yearTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Spacer(minLength: 4)

        CalendarNavButton(systemImage: "chevron.left", help: "Previous month") {
          withAnimation(motion.navigationAnimation) { changeMonth(by: -1) }
        }
        CalendarNavButton(title: "Today", help: "Jump to today") {
          withAnimation(motion.navigationAnimation) {
            monthDate = Date()
            selectedDate = Date()
          }
        }
        CalendarNavButton(systemImage: "chevron.right", help: "Next month") {
          withAnimation(motion.navigationAnimation) { changeMonth(by: 1) }
        }
      }
      .animation(motion.navigationAnimation, value: monthName)

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
              withAnimation(motion.stateAnimation) {
                selectedDate = day.date
                monthDate = day.date
              }
            } label: {
              VStack(spacing: showsLunarCalendar ? 0 : 2) {
                Text(verbatim: String(day.number))
                  .font(.system(size: 12.5, weight: dayWeight(for: day), design: .rounded))
                  .foregroundStyle(dayForeground(for: day))

                if showsLunarCalendar {
                  Text(day.secondaryText ?? " ")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(secondaryForeground(for: day))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: 32, minHeight: 10, maxHeight: 10)
                }

                HStack(spacing: 2) {
                  ForEach(Array(day.events.prefix(3).enumerated()), id: \.offset) { _, event in
                    Circle()
                      .fill(
                        day.isSelected
                          ? Color.white.opacity(0.85) : eventAccentColor(for: event)
                      )
                      .frame(width: 3, height: 3)
                  }
                }
                .frame(height: showsLunarCalendar ? 4 : 3)
              }
              .frame(
                width: showsLunarCalendar ? 34 : 32,
                height: showsLunarCalendar ? 37 : 25
              )
              .background(
                dayChipFill(for: day),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
              )
              .frame(maxWidth: .infinity)
              .frame(height: dateCellHeight)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dayAccessibilityLabel(for: day))
            .help(dayHelpText(for: day))
            .onHover { isHovering in
              withAnimation(motion.hoverAnimation) {
                // Only the cell that owns the current hover may clear it, otherwise
                // the exit event of the previous cell wipes the new one.
                hoveredDate = isHovering ? day.date : (isHovered(day) ? nil : hoveredDate)
              }
            }
          }
        }
      }
      .overlay(monthOutline)
      .animation(motion.navigationAnimation, value: monthStart)

      if showsMonthStats {
        monthStatsRow
      }

      if showsDateDistance {
        dateDistanceRow
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  /// How much of the visible month is work. Fixed height, like the row below it, so
  /// neither one makes the card breathe as the pointer crosses the grid.
  private var monthStatsRow: some View {
    let stats = WorkdayCalculator.monthStats(
      month: monthDate,
      scheme: workdayScheme,
      calendar: calendar,
      now: Date()
    )
    return HStack(spacing: 6) {
      Text(stats.localizedSummary)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
      if stats.isEstimated {
        Text(L10n.string("Estimated as Mon-Fri"))
          .font(.system(size: 9.5))
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
    .lineLimit(1)
    .frame(height: 13)
  }

  /// Reads the hovered day when there is one, and falls back to the selected day so the
  /// row always says something rather than appearing and disappearing under the grid.
  private var dateDistanceRow: some View {
    let date = hoveredDate ?? selectedDate
    return HStack(spacing: 6) {
      Text(distanceDateText(for: date))
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(hoveredDate == nil ? Color.secondary : Color.primary)
      Text(
        WorkdayCalculator.distance(from: Date(), to: date, calendar: calendar)
          .localizedDescription
      )
      .font(.system(size: 10.5))
      .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      if let tag = holidayTag(for: date, scheme: workdayScheme, calendar: calendar) {
        Text(tag)
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
    }
    .lineLimit(1)
    .frame(height: 14)
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

  private func distanceDateText(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEE, MMM d"
    return formatter.string(from: date)
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
        number: weekDays.first?.weekNumber ?? calendar.component(.weekOfYear, from: monthStart),
        days: weekDays
      )
    }
  }

  private var days: [CalendarDayPresentation] {
    presentationCache.days(
      monthDate: monthDate,
      selectedDate: selectedDate,
      now: Date(),
      timeZone: timeZone,
      weekStartDay: weekStartDay,
      showsLunarCalendar: showsLunarCalendar,
      allDayEventDatePolicy: allDayEventDatePolicy,
      events: events,
      solarTerms: SolarTermStore.bundled
    )
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
  private func dayChipFill(for day: CalendarDayPresentation) -> Color {
    if day.isSelected { return .accentColor }
    if day.isToday { return .accentColor.opacity(0.14) }
    if isHovered(day) { return .primary.opacity(0.07) }
    return .clear
  }

  private func dayForeground(for day: CalendarDayPresentation) -> Color {
    if day.isSelected { return .white }
    if day.isToday { return .accentColor }
    return day.isInMonth ? .primary : .secondary.opacity(0.4)
  }

  private func secondaryForeground(for day: CalendarDayPresentation) -> Color {
    if day.isSelected { return .white.opacity(0.82) }
    return day.isInMonth ? .secondary : .secondary.opacity(0.35)
  }

  private func dayWeight(for day: CalendarDayPresentation) -> Font.Weight {
    (day.isSelected || day.isToday) ? .bold : .medium
  }

  private func isHovered(_ day: CalendarDayPresentation) -> Bool {
    hoveredDate.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
  }

  private func dayAccessibilityLabel(for day: CalendarDayPresentation) -> String {
    let eventSummary: String
    if day.events.isEmpty {
      eventSummary = L10n.string("No events")
    } else if day.events.count == 1 {
      eventSummary = L10n.format("%d event", day.events.count)
    } else {
      eventSummary = L10n.format("%d events", day.events.count)
    }
    var parts = [dateTooltipText(for: day.date)]
    if let lunar = day.lunar {
      parts.append(lunar.fullText)
    }
    if let context = day.lunar?.festival?.title ?? day.solarTerm?.title {
      parts.append(context)
    }
    parts.append(eventSummary)
    return parts.joined(separator: ", ")
  }

  private func dayHelpText(for day: CalendarDayPresentation) -> String {
    "\(dayAccessibilityLabel(for: day)) • \(L10n.string("Click to select"))"
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
  @Environment(\.menuCueMotion) private var motion
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
      withAnimation(motion.hoverAnimation) { isHovering = hovering }
    }
    .help(L10n.string(help))
  }
}

struct AnimationQualitySettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    SettingsGroup(spacing: 10) {
      HStack(spacing: 12) {
        Text("Animation effects")
        Spacer(minLength: 12)
        AnimationQualitySegmentedControl(
          selection: Binding(
            get: { model.settings.animationQuality },
            set: { quality in
              model.updateSettings { $0.animationQuality = quality }
            }
          ),
          accessibilityHelp: model.settings.animationQuality.detail
        )
        .frame(width: 360)
      }

      Text(model.settings.animationQuality.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

struct AnimationQualitySegmentedControl: NSViewRepresentable {
  @Binding var selection: AnimationQuality
  let accessibilityHelp: String

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: AnimationQuality.allCases.map(\.title),
      trackingMode: .selectOne,
      target: context.coordinator,
      action: #selector(Coordinator.selectionChanged(_:))
    )
    control.segmentStyle = .automatic
    configure(control, coordinator: context.coordinator)
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.parent = self
    configure(control, coordinator: context.coordinator)
  }

  private func configure(_ control: NSSegmentedControl, coordinator: Coordinator) {
    let qualities = AnimationQuality.allCases
    for index in qualities.indices {
      control.setLabel(qualities[index].title, forSegment: index)
    }
    control.selectedSegment = qualities.firstIndex(of: selection) ?? 1
    control.setAccessibilityLabel(L10n.string("Animation effects"))
    control.setAccessibilityHelp(accessibilityHelp)
  }

  final class Coordinator: NSObject {
    var parent: AnimationQualitySegmentedControl

    init(parent: AnimationQualitySegmentedControl) {
      self.parent = parent
    }

    @objc func selectionChanged(_ sender: NSSegmentedControl) {
      let qualities = AnimationQuality.allCases
      guard qualities.indices.contains(sender.selectedSegment) else { return }
      parent.selection = qualities[sender.selectedSegment]
    }
  }
}

private struct CalendarWeek: Identifiable {
  let id: Date
  let number: Int
  let days: [CalendarDayPresentation]
}

private struct AgendaList: View {
  let events: [CalendarEventInfo]
  let timeZone: TimeZone
  let weekStartDay: WeekStartDay
  let allDayEventDatePolicy: AllDayEventDatePolicy

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

      if groupedWeekEvents.isEmpty {
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

  private var groupedWeekEvents: [AgendaDayGroup] {
    let grouped = AgendaEventProjector.eventsByCivilDate(
      events,
      now: Date(),
      timeZone: timeZone,
      allDayPolicy: allDayEventDatePolicy
    )

    return grouped.keys.sorted().compactMap { key in
      guard let day = key.date(in: timeZone) else { return nil }
      return AgendaDayGroup(
        id: day,
        title: dayTitle(for: day),
        dateText: shortDateText(for: day),
        events: grouped[key]?.sorted { $0.startDate < $1.startDate } ?? []
      )
    }
  }

  private var dateRangeText: String {
    let start = Date()
    let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
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
