import SwiftUI

/// Which events MenuCue may read, and how the month view lays out the dates it draws
/// them on. The access state and its remediation live here too, so the permission the
/// pane depends on is granted in the same place it is used.
///
/// The access state leads the pane as a banner rather than as loose text, so a denied or
/// restricted Mac reads as one actionable block above the cards it degrades.
struct CalendarSettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      authorizationBanners

      if model.authorizationState.canReadEvents {
        eventSourcesCard
      }

      monthViewCard
      refreshCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// What macOS currently answers about event access, plus whatever the last read
  /// reported as a failure. Both are banners: the same remediation the pane has always
  /// offered, attached to the state it belongs to.
  @ViewBuilder
  private var authorizationBanners: some View {
    let state = model.authorizationState
    let guidance = model.calendarPermissionGuidance

    if state.canReadEvents {
      SettingsBanner(
        state.title,
        systemImage: "checkmark.circle.fill",
        tint: .green
      )
    } else {
      SettingsBanner(
        state.title,
        desc: guidance?.message,
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      ) {
        if let guidance {
          Button(guidance.action.buttonTitle) {
            model.performCalendarPermissionAction(guidance.action)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }
    }

    if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
      SettingsBanner(
        errorMessage,
        systemImage: "exclamationmark.triangle.fill",
        tint: .red
      )
    }
  }

  private var eventSourcesCard: some View {
    SettingsCard(
      L10n.string("Event Sources"),
      desc: L10n.string("Choose Selected Calendars to turn each source on or off.")
    ) {
      SettingsRows {
        SettingsRowSegmented(
          L10n.string("Show"),
          selection: selectionModeIndex,
          options: CalendarSelectionMode.allCases.map(\.title)
        )

        if model.settings.calendarSelectionMode == .custom {
          calendarSelectionList
        }
      }
    }
  }

  private var monthViewCard: some View {
    SettingsCard(
      L10n.string("Month View"),
      desc: L10n.string("Affects the popover's Calendar tab and the dashboard calendar.")
    ) {
      SettingsRows {
        SettingsRowSelect(
          L10n.string("Week starts"),
          desc: L10n.string("Month view and week numbers use this start day."),
          selection: model.settingsBinding(\.calendarWeekStartDay),
          options: WeekStartDay.allCases.map { day in (value: day, label: day.title) }
        )

        SettingsRowToggle(
          L10n.string("Show lunar calendar"),
          desc: L10n.string("Show lunar dates, traditional festivals, and solar terms in the month view."),
          isOn: model.settingsBinding(\.showsLunarCalendar)
        )

        SettingsRowSelect(
          L10n.string("All-day events"),
          desc: L10n.string("Keep their original civil date, or regroup them using the overview time zone."),
          selection: model.settingsBinding(\.allDayEventDatePolicy),
          options: AllDayEventDatePolicy.allCases.map { policy in (value: policy, label: policy.title) }
        )

        SettingsRowToggle(
          L10n.string("Show date distance"),
          desc: L10n.string("Show how far a date sits from today, both while hovering and for the selected date."),
          isOn: model.settingsBinding(\.calendarShowsDateDistance)
        )

        SettingsRowToggle(
          L10n.string("Show monthly workdays"),
          desc: L10n.string("Count the workdays and days off in the month currently on screen."),
          isOn: model.settingsBinding(\.calendarShowsMonthStats)
        )

        SettingsRowSelect(
          L10n.string("Workday basis"),
          desc: L10n.string("Statutory holidays follow the published Chinese schedule, including the weekends moved to workdays."),
          selection: model.settingsBinding(\.calendarWorkdayScheme),
          options: WorkdayScheme.allCases.map { scheme in (value: scheme, label: scheme.title) }
        )
      }
    }
  }

  /// Automatic refresh has no switch: the app listens to the system calendar and
  /// debounces its own reload. The card says so, and keeps the manual reload beside it
  /// for the times the user does not want to wait.
  private var refreshCard: some View {
    SettingsCard(L10n.string("Refresh")) {
      SettingsRows {
        SettingsRow(
          L10n.string("Auto Refresh"),
          desc: L10n.string("Listens for system calendar changes and refreshes after a 0.2 second debounce; nothing to do by hand.")
        ) {
          SettingsChip(
            L10n.string("Enabled"),
            systemImage: "arrow.triangle.2.circlepath",
            tint: .accentColor,
            prominent: true
          )
        }

        SettingsRowButton(
          L10n.string("Refresh Now"),
          desc: L10n.string("Re-reads the event sources and recomputes the month statistics."),
          buttonTitle: L10n.string("Refresh"),
          kind: .secondary
        ) {
          model.refreshCalendarData()
        }
      }
    }
  }

  @ViewBuilder
  private var calendarSelectionList: some View {
    ForEach(model.calendars) { calendar in
      SettingsRowToggle(
        calendar.title,
        desc: calendar.sourceTitle,
        isOn: calendarBinding(calendar.id)
      )
    }
  }

  /// The segmented control is index-based; the model stores the mode itself, so the
  /// index is derived on read and never cached.
  private var selectionModeIndex: Binding<Int> {
    let mode = model.settingsBinding(\.calendarSelectionMode)
    return Binding(
      get: { CalendarSelectionMode.allCases.firstIndex(of: mode.wrappedValue) ?? 0 },
      set: { index in
        guard CalendarSelectionMode.allCases.indices.contains(index) else { return }
        mode.wrappedValue = CalendarSelectionMode.allCases[index]
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
}
