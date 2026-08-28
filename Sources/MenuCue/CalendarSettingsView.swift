import SwiftUI

/// Which events MenuCue may read, and how the month view lays out the dates it draws
/// them on. The access state and its remediation live here too, so the permission the
/// pane depends on is granted in the same place it is used.
struct CalendarSettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    SettingsGroup(spacing: 12) {
      Text("Calendar & Events")
        .font(.headline)
      Text("Choose the event sources and date layout used in the popover.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Week starts", selection: model.settingsBinding(\.calendarWeekStartDay)) {
        ForEach(WeekStartDay.allCases) { day in
          Text(day.title).tag(day)
        }
      }
      .frame(maxWidth: 250)

      Text("Month view and week numbers use this start day.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Toggle("Show lunar calendar", isOn: model.settingsBinding(\.showsLunarCalendar))

      Text("Show lunar dates, traditional festivals, and solar terms in the month view.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("All-day events", selection: model.settingsBinding(\.allDayEventDatePolicy)) {
        ForEach(AllDayEventDatePolicy.allCases) { policy in
          Text(policy.title).tag(policy)
        }
      }
      .frame(maxWidth: 320)

      Text("Keep their original civil date, or regroup them using the overview time zone.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Divider()

      HStack {
        Button("Refresh") {
          model.refreshCalendarData()
        }
        Spacer()
      }

      Text(model.authorizationState.title)
        .font(.caption)
        .foregroundStyle(model.authorizationState.canReadEvents ? Color.secondary : Color.orange)

      if let guidance = model.calendarPermissionGuidance {
        Text(guidance.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button(guidance.action.buttonTitle) {
          model.performCalendarPermissionAction(guidance.action)
        }
      }

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if model.authorizationState.canReadEvents {
        Picker("Show", selection: model.settingsBinding(\.calendarSelectionMode)) {
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
}
