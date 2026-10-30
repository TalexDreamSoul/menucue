import SwiftUI

struct ReminderSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var editingReminder: ReminderRule?

  private var reminders: [ReminderRule] {
    model.settings.notificationSettings.reminders
  }

  var body: some View {
    SettingsCard(
      L10n.string("Reminders"),
      desc: L10n.string(
        "Schedule personal reminders locally. System notifications use the enabled System channel; Bark is added when its channel is configured."
      ),
      action: {
        HStack(spacing: 8) {
          Button(L10n.string("Reset Reminders")) {
            model.updateSettings { $0.notificationSettings.reminders = DefaultReminderRules.all() }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          Button(L10n.string("Add Reminder")) {
            editingReminder = ReminderRule(
              name: L10n.string("New reminder"),
              schedule: .daily(hour: 9, minute: 0),
              title: L10n.string("Reminder"),
              body: L10n.string("This is a scheduled reminder.")
            )
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }
    ) {
      if reminders.isEmpty {
        SettingsEmptyState(
          L10n.string("No Reminders"),
          desc: L10n.string("Add a reminder for a daily routine or a repeating task."),
          systemImage: "bell.slash"
        ) {
          Button(L10n.string("Add Reminder")) {
            editingReminder = ReminderRule(
              name: L10n.string("New reminder"),
              schedule: .daily(hour: 9, minute: 0),
              title: L10n.string("Reminder"),
              body: L10n.string("This is a scheduled reminder.")
            )
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      } else {
        SettingsRows {
          ForEach(reminders) { reminder in
            SettingsStackedRow(reminder.name, desc: reminder.schedule.summary) {
              HStack(spacing: 10) {
                Toggle(
                  "",
                  isOn: Binding(
                    get: { reminderBinding(for: reminder.id).wrappedValue.isEnabled },
                    set: { value in
                      var updated = reminderBinding(for: reminder.id).wrappedValue
                      updated.isEnabled = value
                      reminderBinding(for: reminder.id).wrappedValue = updated
                    }
                  )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                Button(L10n.string("Edit")) {
                  editingReminder = reminder
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                  delete(reminder)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .accessibilityLabel(L10n.string("Delete Reminder"))
              }
            }
          }
        }
      }
    }
    .sheet(item: $editingReminder) { reminder in
      ReminderEditorSheet(reminder: reminder) { updated in
        save(updated)
        editingReminder = nil
      } onCancel: {
        editingReminder = nil
      }
    }
  }

  private func reminderBinding(for id: UUID) -> Binding<ReminderRule> {
    Binding(
      get: {
        reminders.first(where: { $0.id == id })
          ?? DefaultReminderRules.all()[0]
      },
      set: { value in
        model.updateSettings { settings in
          guard let index = settings.notificationSettings.reminders.firstIndex(where: { $0.id == id })
          else { return }
          settings.notificationSettings.reminders[index] = value
        }
      }
    )
  }

  private func save(_ reminder: ReminderRule) {
    model.updateSettings { settings in
      if let index = settings.notificationSettings.reminders.firstIndex(where: { $0.id == reminder.id }) {
        settings.notificationSettings.reminders[index] = reminder
      } else {
        settings.notificationSettings.reminders.append(reminder)
      }
    }
  }

  private func delete(_ reminder: ReminderRule) {
    model.updateSettings { settings in
      settings.notificationSettings.reminders.removeAll { $0.id == reminder.id }
    }
  }
}

private struct ReminderEditorSheet: View {
  private enum ScheduleKind: String, CaseIterable, Identifiable {
    case daily
    case everyDays
    case everyHours

    var id: String { rawValue }

    var title: String {
      switch self {
      case .daily: return L10n.string("Daily")
      case .everyDays: return L10n.string("Every N days")
      case .everyHours: return L10n.string("Every N hours")
      }
    }
  }

  let onSave: (ReminderRule) -> Void
  let onCancel: () -> Void
  @State private var draft: ReminderRule
  @State private var kind: ScheduleKind
  @State private var time: Date
  @State private var interval = 7
  @State private var hours = 2
  @State private var startHour = 9
  @State private var endHour = 18
  @State private var lidCloseEnabled: Bool
  @State private var lidCloseAfterHour: Int

  init(reminder: ReminderRule, onSave: @escaping (ReminderRule) -> Void, onCancel: @escaping () -> Void) {
    self.onSave = onSave
    self.onCancel = onCancel
    _draft = State(initialValue: reminder)
    switch reminder.schedule {
    case let .daily(hour, minute):
      _kind = State(initialValue: .daily)
      _interval = State(initialValue: 7)
      _hours = State(initialValue: 2)
      _startHour = State(initialValue: 9)
      _endHour = State(initialValue: 18)
      _time = State(initialValue: Self.date(hour: hour, minute: minute))
    case let .everyDays(days):
      _kind = State(initialValue: .everyDays)
      _interval = State(initialValue: max(1, days))
      _hours = State(initialValue: 2)
      _startHour = State(initialValue: 9)
      _endHour = State(initialValue: 18)
      _time = State(initialValue: Self.date(hour: 9, minute: 0))
    case let .everyHours(hours, startHour, endHour):
      _kind = State(initialValue: .everyHours)
      _interval = State(initialValue: 7)
      _hours = State(initialValue: max(1, hours))
      _startHour = State(initialValue: startHour)
      _endHour = State(initialValue: endHour)
      _time = State(initialValue: Self.date(hour: startHour, minute: 0))
    }
    _lidCloseEnabled = State(initialValue: reminder.lidCloseAfterHour != nil)
    _lidCloseAfterHour = State(initialValue: reminder.lidCloseAfterHour ?? 17)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.string("Edit Reminder"))
        .font(.title2.weight(.semibold))
      Form {
        TextField(L10n.string("Name"), text: $draft.name)
        Toggle(L10n.string("Enabled"), isOn: $draft.isEnabled)
        Picker(L10n.string("Schedule"), selection: $kind) {
          ForEach(ScheduleKind.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        switch kind {
        case .daily:
          DatePicker(
            L10n.string("Time"),
            selection: $time,
            displayedComponents: .hourAndMinute
          )
        case .everyDays:
          Stepper(
            L10n.format("Every %d days", interval),
            value: $interval,
            in: 1...365
          )
        case .everyHours:
          Stepper(L10n.format("Every %d hours", hours), value: $hours, in: 1...12)
          Stepper(L10n.format("Start at %02d:00", startHour), value: $startHour, in: 0...23)
          Stepper(L10n.format("End at %02d:00", endHour), value: $endHour, in: 0...23)
        }
        Toggle(L10n.string("Also remind when the lid closes"), isOn: $lidCloseEnabled)
        if lidCloseEnabled {
          Stepper(
            L10n.format("Only after %02d:00", lidCloseAfterHour),
            value: $lidCloseAfterHour,
            in: 0...23
          )
        }
        Section(L10n.string("Notification")) {
          TextField(L10n.string("Title"), text: $draft.title)
          TextField(L10n.string("Body"), text: $draft.body, axis: .vertical)
          ForEach(NotificationChannelKind.allCases, id: \.self) { channel in
            Toggle(channel.displayTitle, isOn: channelBinding(channel))
          }
        }
      }
      HStack {
        Spacer()
        Button(L10n.string("Cancel"), action: onCancel)
        Button(L10n.string("Save"), action: save)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 520, height: 560)
  }

  private func save() {
    let components = Calendar.current.dateComponents([.hour, .minute], from: time)
    switch kind {
    case .daily:
      draft.schedule = .daily(hour: components.hour ?? 9, minute: components.minute ?? 0)
    case .everyDays:
      draft.schedule = .everyDays(days: interval)
    case .everyHours:
      draft.schedule = .everyHours(hours: hours, startHour: startHour, endHour: endHour)
    }
    draft.lidCloseAfterHour = lidCloseEnabled ? lidCloseAfterHour : nil
    onSave(draft)
  }

  private func channelBinding(_ channel: NotificationChannelKind) -> Binding<Bool> {
    Binding(
      get: { draft.channels.contains(channel) },
      set: { enabled in
        if enabled { draft.channels.insert(channel) }
        else { draft.channels.remove(channel) }
      }
    )
  }

  private static func date(hour: Int, minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
  }
}

private extension NotificationChannelKind {
  var displayTitle: String {
    switch self {
    case .system: return L10n.string("System Notifications")
    case .feishu: return L10n.string("Feishu")
    case .webhook: return L10n.string("Webhook")
    case .bark: return L10n.string("Bark")
    case .telegram: return L10n.string("Telegram")
    }
  }
}
