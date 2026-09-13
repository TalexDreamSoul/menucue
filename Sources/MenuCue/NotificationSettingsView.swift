import SwiftUI

struct NotificationSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var configuration: NotificationConfigurationService
  @State private var selectedRuleID: UUID?

  init(model: AppModel) {
    self.model = model
    self.configuration = model.notificationConfigurationService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      if let message = model.notificationRuntimeErrorMessage {
        SettingsBanner(message, systemImage: "exclamationmark.triangle.fill", tint: .red)
      }
      runtimeCard
      channelCard
      rulesCard
      if let rule = selectedRule {
        AlertRuleEditor(model: model, rule: rule)
          .id(rule.id)
      }
      identityCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      if selectedRuleID == nil {
        selectedRuleID = rules.first?.id
      }
    }
  }

  private var rules: [AlertRule] {
    model.settings.notificationSettings.rules
  }

  private var selectedRule: AlertRule? {
    guard let selectedRuleID else { return nil }
    return rules.first { $0.id == selectedRuleID }
  }

  /// The master switch sits above the channels: it is about whether anything samples and
  /// delivers at all, not about one channel or one rule.
  private var runtimeCard: some View {
    SettingsCard(
      L10n.string("Runtime"),
      desc: L10n.string(
        "MenuCue samples the metrics its rules name and delivers to the channels those rules list."
      )
    ) {
      SettingsRows {
        SettingsRowToggle(
          L10n.string("Enable Alert Monitoring"),
          desc: L10n.string(
            "Off keeps every rule and channel configured but stops sampling and delivery."
          ),
          isOn: model.settingsBinding(\.notificationSettings.isGloballyEnabled)
        )

        SettingsStackedRow(L10n.string("Current")) {
          HStack(spacing: 8) {
            SettingsChip(
              L10n.format("%d channels ready", readyChannelCount),
              systemImage: "checkmark",
              tint: .accentColor,
              prominent: true
            )
            .fixedSize(horizontal: true, vertical: false)
            SettingsChip(L10n.format("%d rules enabled", model.settings.notificationSettings.enabledRuleCount))
              .fixedSize(horizontal: true, vertical: false)
            SettingsChip(
              alertsAreRunning ? L10n.string("Sampling") : L10n.string("Paused"),
              systemImage: alertsAreRunning ? "activity" : "pause"
            )
            .fixedSize(horizontal: true, vertical: false)
          }
        }
      }
    }
  }

  private var alertsAreRunning: Bool {
    model.settings.notificationSettings.isGloballyEnabled
  }

  /// A channel counts as ready only when it is switched on *and* its credentials are still
  /// present: an enabled channel whose key was removed delivers nothing.
  private var readyChannelCount: Int {
    let settings = model.settings.notificationSettings
    return NotificationChannelKind.allCases.filter { kind in
      settings.channel(kind).isEnabled && configuration.canEnable(kind, settings: settings)
    }.count
  }

  private var channelCard: some View {
    SettingsCard(
      L10n.string("Channels"),
      desc: L10n.string(
        "Credentials must be saved to the Keychain before a channel can be enabled; disabling a channel removes it from every rule."
      )
    ) {
      SettingsRows {
        ForEach(NotificationChannelKind.allCases, id: \.self) { kind in
          NotificationChannelRow(model: model, configuration: configuration, kind: kind)
        }
      }
    }
  }

  private var rulesCard: some View {
    SettingsCard(
      L10n.string("Alert Rules"),
      desc: L10n.string(
        "Thresholds use each metric's own unit; percentage metrics are compared internally on a 0–1 scale."
      ),
      action: {
        HStack(spacing: 8) {
          Button(L10n.string("Delete Rule")) {
            deleteSelectedRule()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.red)
          .disabled(selectedRule == nil)

          Button(L10n.string("Add Rule")) {
            addRule()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }
    ) {
      if rules.isEmpty {
        SettingsEmptyState(
          L10n.string("No Alert Rules"),
          desc: L10n.string("Add a rule to monitor system metrics or dark wakes."),
          systemImage: "bell.slash"
        )
      } else {
        SettingsTable(columns: rulesColumns) {
          ForEach(rules) { rule in
            Button {
              selectedRuleID = rule.id
            } label: {
              ruleTableRow(rule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rule.name)
          }
        }
        if selectedRule == nil {
          SettingsEmptyState(
            L10n.string("Select a rule"),
            desc: L10n.string("Choose a rule in the table to edit it."),
            systemImage: "hand.point.up.left"
          )
        }
      }
    }
  }

  /// The document's six columns. The document sizes them for its Chinese sample rows; the
  /// app renders metric identifiers (`sensor.thermal.temperature` and friends), so the
  /// metric column takes the width the condition column does not need in English.
  private var rulesColumns: [SettingsTableColumn] {
    [
      SettingsTableColumn(L10n.string("Rule"), weight: 120),
      SettingsTableColumn(L10n.string("Metric"), weight: 205),
      SettingsTableColumn(L10n.string("Condition"), weight: 92),
      SettingsTableColumn(L10n.string("Sustained"), weight: 36),
      SettingsTableColumn(L10n.string("Cooldown"), weight: 36),
      SettingsTableColumn("", weight: 50, alignment: .trailing),
    ]
  }

  private func ruleTableRow(_ rule: AlertRule) -> some View {
    SettingsTableRow {
      HStack(spacing: 6) {
        Image(systemName: rule.isEnabled ? "bell.fill" : "bell.slash")
          .font(.system(size: 11))
          .foregroundStyle(rule.isEnabled ? Color.accentColor : Color.secondary)
        Text(rule.name)
          .font(.system(size: 12.5, weight: .medium))
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(rule.metricID.rawValue)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(conditionSummary(rule))
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(sustainedSummary(rule))
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(secondsSummary(rule.cooldown))
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Group {
        if selectedRule?.id == rule.id {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        } else {
          Color.clear.frame(width: 11, height: 11)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func conditionSummary(_ rule: AlertRule) -> String {
    let definition = AlertMetricCatalog.definition(for: rule.metricID)
    switch rule.condition {
    case .numeric(let comparison, let threshold):
      let value = AlertMetricFormatter.string(for: .number(threshold), definition: definition)
      switch comparison {
      case .above: return L10n.format("Above %@", value)
      case .below: return L10n.format("Below %@", value)
      case .atLeast: return L10n.format("At least %@", value)
      case .atMost: return L10n.format("At most %@", value)
      case .equal: return L10n.format("Equals %@", value)
      case .notEqual: return L10n.format("Does not equal %@", value)
      case .occurs: return L10n.string("Each occurrence")
      }
    case .severity(let comparison, let level):
      let title = severityTitle(level)
      switch comparison {
      case .atLeast: return L10n.format("At least %@", title)
      case .atMost: return L10n.format("At most %@", title)
      case .equal: return L10n.format("Equals %@", title)
      case .notEqual: return L10n.format("Does not equal %@", title)
      case .above: return L10n.format("Above %@", title)
      case .below: return L10n.format("Below %@", title)
      case .occurs: return L10n.string("Each occurrence")
      }
    case .boolean(let expected):
      return expected ? L10n.string("Is true") : L10n.string("Is false")
    case .event:
      return L10n.string("Each occurrence")
    }
  }

  private func severityTitle(_ level: Int) -> String {
    switch level {
    case 1: return L10n.string("Normal")
    case 3: return L10n.string("Critical")
    default: return L10n.string("Warning")
    }
  }

  private func sustainedSummary(_ rule: AlertRule) -> String {
    if AlertMetricCatalog.definition(for: rule.metricID)?.valueKind == .event { return "—" }
    return secondsSummary(rule.alertDuration)
  }

  private func secondsSummary(_ seconds: TimeInterval) -> String {
    L10n.format("%d s", Int(seconds))
  }

  private var identityCard: some View {
    SettingsCard(L10n.string("Device Identity")) {
      SettingsRows {
        SettingsRow(
          L10n.string("Device name"),
          desc: L10n.string("Blank uses the system host name.")
        ) {
          HStack(spacing: 8) {
            TextField("", text: deviceNameBinding)
              .textFieldStyle(.roundedBorder)
              .frame(width: 190)
              .accessibilityLabel(L10n.string("Device name"))
            Button(L10n.string("Reset")) {
              model.updateNotificationSettings { $0.setDeviceNameOverride(nil) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.settings.notificationSettings.deviceNameOverride == nil)
          }
        }
        SettingsRowValue(
          L10n.string("Source shown in notifications"),
          value: resolvedDeviceName
        )
      }
    }
  }

  private var resolvedDeviceName: String {
    model.settings.notificationSettings.resolvedDeviceName(
      systemName: Host.current().localizedName)
  }

  private var deviceNameBinding: Binding<String> {
    Binding(
      get: { model.settings.notificationSettings.deviceNameOverride ?? "" },
      set: { value in model.updateNotificationSettings { $0.setDeviceNameOverride(value) } }
    )
  }

  private func addRule() {
    let channels = Set(
      NotificationChannelKind.allCases.filter {
        model.settings.notificationSettings.channel($0).isEnabled
      })
    let rule = AlertRule(
      name: L10n.string("CPU usage"),
      metricID: "cpu.total.busy",
      condition: .numeric(operator: .above, threshold: 0.9),
      alertDuration: 60,
      recoveryDuration: 60,
      recoveryThreshold: 0.75,
      channels: channels
    )
    model.updateNotificationSettings { $0.rules.append(rule) }
    selectedRuleID = rule.id
  }

  private func deleteSelectedRule() {
    guard let selectedRuleID else { return }
    model.updateNotificationSettings { settings in
      settings.rules.removeAll { $0.id == selectedRuleID }
    }
    self.selectedRuleID = model.settings.notificationSettings.rules.first?.id
  }
}

private struct NotificationChannelRow: View {
  @ObservedObject var model: AppModel
  @ObservedObject var configuration: NotificationConfigurationService
  let kind: NotificationChannelKind

  @State private var isExpanded = false
  @State private var primarySecret = ""
  @State private var optionalSecret = ""
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      SettingsRow(kind.title, desc: statusDescription) {
        HStack(spacing: 8) {
          statusChip
            .fixedSize(horizontal: true, vertical: false)
          Toggle("", isOn: enabledBinding)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(L10n.format("Enable %@", kind.title))
          Button(isExpanded ? L10n.string("Done") : L10n.string("Configure")) {
            isExpanded.toggle()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .fixedSize(horizontal: true, vertical: false)
          Button(L10n.string("Send Test")) {
            Task { await model.testNotificationChannel(kind) }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .fixedSize(horizontal: true, vertical: false)
          .disabled(
            !configuration.canEnable(kind, settings: model.settings.notificationSettings)
              || configuration.testState(for: kind) == .testing
          )
        }
      }

      if isExpanded {
        configurationCard
      }

      if let errorMessage {
        SettingsBanner(errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
      }
    }
  }

  private var configurationCard: some View {
    SettingsCard(
      L10n.format("%@ Configuration", kind.title),
      tone: .inset
    ) {
      SettingsRows {
        switch kind {
        case .system:
          SettingsRow(
            L10n.string("System Notifications"),
            desc: L10n.string("Delivered on this Mac. macOS asks for permission when you send the first test or alert.")
          ) {
            Button(L10n.string("Open Notification Settings")) {
              SettingsLinkOpener.open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        case .feishu:
          secretField(
            L10n.string("Webhook URL"),
            desc: L10n.string(
              "Required; stored in the system Keychain. The interface only shows whether it has been saved."
            ),
            key: NotificationSecretField.feishuWebhook,
            optional: false
          )
          secretField(
            L10n.string("Signing secret"),
            desc: L10n.string("Optional; used to verify callback signatures."),
            key: NotificationSecretField.feishuSigningSecret,
            optional: true
          )
        case .webhook:
          secretField(
            L10n.string("Endpoint URL"),
            desc: L10n.string(
              "Required; stored in the system Keychain. The interface only shows whether it has been saved."
            ),
            key: NotificationSecretField.webhookEndpoint,
            optional: false
          )
          secretField(
            L10n.string("Bearer token"),
            desc: L10n.string("Optional; stored in the system Keychain."),
            key: NotificationSecretField.webhookBearerToken,
            optional: true
          )
        case .bark:
          secretField(
            L10n.string("Device key"),
            desc: L10n.string(
              "Required; stored in the system Keychain. The interface only shows whether it has been saved."
            ),
            key: NotificationSecretField.barkDeviceKey,
            optional: false
          )
          SettingsRowField(
            L10n.string("Server URL"),
            desc: L10n.string("Defaults to https://api.day.app."),
            text: channelBinding(\.barkServerURL),
            monospaced: false
          )
          SettingsRowField(
            L10n.string("Group"),
            text: channelBinding(\.barkGroup),
            monospaced: false
          )
        case .telegram:
          secretField(
            L10n.string("Bot token"),
            desc: L10n.string(
              "Required; stored in the system Keychain. The interface only shows whether it has been saved."
            ),
            key: NotificationSecretField.telegramBotToken,
            optional: false
          )
          SettingsRowField(
            L10n.string("Chat ID"),
            text: channelBinding(\.telegramChatID),
            monospaced: false
          )
          SettingsRowField(
            L10n.string("Topic ID (optional)"),
            text: threadIDBinding,
            monospaced: false
          )
        }

        SettingsRow(
          L10n.string("Removing a required credential"),
          desc: L10n.string(
            "The channel is disabled at the same time and removed from every rule, with no undo."
          )
        ) {
          SettingsChip(
            L10n.string("Cannot be undone"),
            systemImage: "exclamationmark.triangle",
            tint: .orange
          )
        }
      }
    }
  }

  private func secretField(
    _ title: String,
    desc: String?,
    key: NotificationSecretKey,
    optional: Bool
  ) -> some View {
    let binding = optional ? $optionalSecret : $primarySecret
    return SettingsRow(title, desc: desc) {
      HStack(spacing: 8) {
        SecureField("", text: binding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 190)
          .accessibilityLabel(title)
        Button(L10n.string("Save")) {
          do {
            try model.saveNotificationSecret(binding.wrappedValue, for: key)
            binding.wrappedValue = ""
            errorMessage = nil
          } catch {
            errorMessage = L10n.string("Credential could not be saved.")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if configuration.hasSavedSecret(key) {
          SettingsChip(L10n.string("Saved"), systemImage: "lock.fill", tint: .green)
          Button(role: .destructive) {
            do {
              try model.removeNotificationSecret(key)
              if NotificationSecretField.required(for: kind).contains(key) {
                model.updateNotificationSettings { settings in
                  settings.updateChannel(kind) { $0.isEnabled = false }
                  for index in settings.rules.indices {
                    settings.rules[index].channels.remove(kind)
                  }
                }
              }
            } catch {
              errorMessage = L10n.string("Credential could not be removed.")
            }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help(L10n.string("Remove credential"))
          .accessibilityLabel(L10n.string("Remove credential"))
        }
      }
    }
  }

  @ViewBuilder
  private var statusChip: some View {
    switch configuration.testState(for: kind) {
    case .idle:
      if configuration.canEnable(kind, settings: model.settings.notificationSettings) {
        SettingsChip(L10n.string("Ready"), systemImage: "checkmark", tint: .green)
      } else {
        SettingsChip(L10n.string("Not configured"))
      }
    case .testing:
      SettingsChip(L10n.string("Testing…"))
    case .succeeded:
      SettingsChip(L10n.string("Test succeeded"), systemImage: "checkmark", tint: .green)
    case .failed:
      SettingsChip(L10n.string("Test failed"), systemImage: "exclamationmark.triangle", tint: .red)
    }
  }

  private var statusDescription: String? {
    if case .failed(let message) = configuration.testState(for: kind) { return message }
    return nil
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { model.settings.notificationSettings.channel(kind).isEnabled },
      set: { enabled in
        if enabled && !configuration.canEnable(kind, settings: model.settings.notificationSettings)
        {
          errorMessage = L10n.string("Complete the required fields before enabling this channel.")
          return
        }
        model.updateNotificationSettings { settings in
          settings.updateChannel(kind) { $0.isEnabled = enabled }
          if !enabled {
            for index in settings.rules.indices { settings.rules[index].channels.remove(kind) }
          }
        }
        errorMessage = nil
      }
    )
  }

  private func channelBinding<Value>(
    _ keyPath: WritableKeyPath<NotificationChannelSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { model.settings.notificationSettings.channel(kind)[keyPath: keyPath] },
      set: { value in
        model.updateNotificationSettings { settings in
          settings.updateChannel(kind) { $0[keyPath: keyPath] = value }
        }
      }
    )
  }

  private var threadIDBinding: Binding<String> {
    Binding(
      get: {
        model.settings.notificationSettings.channel(kind).telegramThreadID.map { String($0) } ?? ""
      },
      set: { value in
        model.updateNotificationSettings { settings in
          settings.updateChannel(kind) { $0.telegramThreadID = Int(value) }
        }
      }
    )
  }
}

private struct AlertRuleEditor: View {
  @ObservedObject var model: AppModel
  @State private var rule: AlertRule
  @State private var templateMode = NotificationEventState.alert

  init(model: AppModel, rule: AlertRule) {
    self.model = model
    self._rule = State(initialValue: rule)
  }

  private var definition: AlertMetricDefinition? {
    AlertMetricCatalog.definition(for: rule.metricID)
  }

  var body: some View {
    SettingsCard(
      L10n.format("Rule Editor · %@", rule.name),
      desc: L10n.string(
        "Changes are saved only when you click Save Rule; the editor does not show unsaved state."),
      action: {
        HStack(spacing: 10) {
          Toggle(L10n.string("Enabled"), isOn: binding(\.isEnabled))
            .toggleStyle(.switch)
            .controlSize(.small)
          Button(L10n.string("Save Rule"), action: saveRule)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canSave)
        }
      }
    ) {
      SettingsRows {
        SettingsRowField(
          L10n.string("Rule name"),
          text: binding(\.name),
          fieldWidth: 190,
          monospaced: false
        )

        SettingsRowSelect(
          L10n.string("Metric"),
          selection: metricBinding,
          options: AlertMetricCatalog.all.map { (value: $0.id, label: $0.id.displayTitle) }
        )

        if definition?.supportsTargets == true {
          SettingsRowField(
            L10n.string("Target ID"),
            text: optionalStringBinding(\.targetID),
            fieldWidth: 190,
            monospaced: false
          )
        }

        conditionRow

        if definition?.valueKind == .event {
          SettingsRowField(
            L10n.string("Cooldown"),
            desc: L10n.string("Minimum number of seconds between two alerts; 0 means no limit."),
            text: durationBinding(\.cooldown),
            fieldWidth: 74,
            monospaced: false
          )
        } else {
          timingRows
        }

        channelRow
        messageRow

        SettingsRowField(
          L10n.string("Title template"),
          text: titleTemplateBinding,
          fieldWidth: 260,
          monospaced: false
        )

        SettingsStackedRow(L10n.string("Body template")) {
          TextEditor(text: bodyTemplateBinding)
            .font(.body)
            .frame(minHeight: 72)
            .padding(5)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor))
            )
        }

        previewRow
      }
    }
  }

  @ViewBuilder
  private var conditionRow: some View {
    switch rule.condition {
    case .numeric:
      SettingsRow(L10n.string("Condition")) {
        HStack(spacing: 8) {
          Picker("", selection: numericOperatorBinding) {
            Text(L10n.string("Above")).tag(AlertComparisonOperator.above)
            Text(L10n.string("Below")).tag(AlertComparisonOperator.below)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 120)
          .accessibilityLabel(L10n.string("Condition"))
          TextField("", text: numericThresholdBinding)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .accessibilityLabel(L10n.string("Threshold"))
          Text(definition?.unit.shortTitle ?? "")
            .foregroundStyle(.secondary)
        }
      }
    case .severity:
      SettingsRow(L10n.string("Condition")) {
        HStack(spacing: 8) {
          Picker("", selection: severityOperatorBinding) {
            Text(L10n.string("At least")).tag(AlertComparisonOperator.atLeast)
            Text(L10n.string("At most")).tag(AlertComparisonOperator.atMost)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 120)
          .accessibilityLabel(L10n.string("Condition"))
          Picker("", selection: severityThresholdBinding) {
            Text(L10n.string("Normal")).tag(1)
            Text(L10n.string("Warning")).tag(2)
            Text(L10n.string("Critical")).tag(3)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 130)
          .accessibilityLabel(L10n.string("Level"))
        }
      }
    case .boolean:
      SettingsRowToggle(L10n.string("Expected value"), isOn: booleanBinding)
    case .event:
      SettingsRow(
        L10n.string("Condition"),
        desc: L10n.string("Each new dark wake triggers this rule once.")
      ) {
        SettingsChip(L10n.string("Each occurrence"))
      }
    }
  }

  @ViewBuilder
  private var timingRows: some View {
    SettingsRowField(
      L10n.string("Sustained"),
      desc: L10n.string("Alerts only after the condition holds for this many seconds."),
      text: durationBinding(\.alertDuration),
      fieldWidth: 74,
      monospaced: false
    )
    if case .numeric = rule.condition {
      SettingsRow(
        L10n.string("Recovery threshold"),
        desc: L10n.string("Leave empty to reuse the alert threshold.")
      ) {
        HStack(spacing: 8) {
          TextField("", text: optionalDoubleBinding(\.recoveryThreshold))
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .accessibilityLabel(L10n.string("Recovery threshold"))
          Text(definition?.unit.shortTitle ?? "")
            .foregroundStyle(.secondary)
        }
      }
    }
    SettingsRowField(
      L10n.string("Recovery sustained"),
      desc: L10n.string("Sends a recovery message after the condition has held for this many seconds."),
      text: durationBinding(\.recoveryDuration),
      fieldWidth: 74,
      monospaced: false
    )
    SettingsRowField(
      L10n.string("Cooldown"),
      desc: L10n.string("Minimum number of seconds between two alerts; 0 means no limit."),
      text: durationBinding(\.cooldown),
      fieldWidth: 74,
      monospaced: false
    )
  }

  private var channelRow: some View {
    SettingsRow(
      L10n.string("Deliver to"),
      desc: L10n.string("Channels that are not enabled cannot be selected.")
    ) {
      HStack(spacing: 14) {
        ForEach(NotificationChannelKind.allCases, id: \.self) { kind in
          Toggle(kind.title, isOn: channelBinding(kind))
            .disabled(!model.settings.notificationSettings.channel(kind).isEnabled)
        }
      }
    }
  }

  private var messageRow: some View {
    SettingsRow(L10n.string("Message"), desc: variableHint) {
      HStack(spacing: 10) {
        Picker("", selection: $templateMode) {
          Text(L10n.string("Alert")).tag(NotificationEventState.alert)
          if definition?.valueKind != .event {
            Text(L10n.string("Recovery")).tag(NotificationEventState.recovery)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 200)
        .accessibilityLabel(L10n.string("Message"))
        Menu {
          ForEach(NotificationTemplateRenderer.allowedVariables.sorted(), id: \.self) { variable in
            Button("{{\(variable)}}") { appendVariable(variable) }
          }
        } label: {
          Label(L10n.string("Variable"), systemImage: "curlybraces")
        }
      }
    }
  }

  private var variableHint: String? {
    let preferred = ["rule.name", "metric.value", "device.name"]
    let available = Set(NotificationTemplateRenderer.allowedVariables)
    let samples = preferred.filter(available.contains).map { "{{\($0)}}" }
    return samples.isEmpty ? nil : samples.joined(separator: " · ")
  }

  private var previewRow: some View {
    SettingsRow(L10n.string("Preview")) {
      if let templateError {
        Text(templateError)
          .font(.system(size: 11))
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text(templatePreview.title)
            .font(.system(size: 12, weight: .medium))
          Text(templatePreview.body)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var metricBinding: Binding<AlertMetricID> {
    Binding(
      get: { rule.metricID },
      set: { id in
        guard let next = AlertMetricCatalog.definition(for: id) else { return }
        update { rule in
          rule.metricID = id
          rule.targetID = nil
          switch next.valueKind {
          case .number: rule.condition = .numeric(operator: .above, threshold: 0.9)
          case .severity: rule.condition = .severity(operator: .atLeast, threshold: 2)
          case .boolean: rule.condition = .boolean(is: true)
          case .event: rule.condition = .event
          }
        }
      }
    )
  }

  private var numericOperatorBinding: Binding<AlertComparisonOperator> {
    Binding(
      get: {
        if case .numeric(let value, _) = rule.condition { return value }
        return .above
      },
      set: { value in
        update {
          if case .numeric(_, let threshold) = $0.condition {
            $0.condition = .numeric(operator: value, threshold: threshold)
          }
        }
      }
    )
  }

  private var numericThresholdBinding: Binding<String> {
    Binding(
      get: {
        if case .numeric(_, let value) = rule.condition { return String(value) }
        return ""
      },
      set: { text in
        guard let value = Double(text), value.isFinite else { return }
        update {
          if case .numeric(let comparison, _) = $0.condition {
            $0.condition = .numeric(operator: comparison, threshold: value)
          }
        }
      }
    )
  }

  private var severityOperatorBinding: Binding<AlertComparisonOperator> {
    Binding(
      get: {
        if case .severity(let value, _) = rule.condition { return value }
        return .atLeast
      },
      set: { value in
        update {
          if case .severity(_, let threshold) = $0.condition {
            $0.condition = .severity(operator: value, threshold: threshold)
          }
        }
      }
    )
  }

  private var severityThresholdBinding: Binding<Int> {
    Binding(
      get: {
        if case .severity(_, let value) = rule.condition { return value }
        return 2
      },
      set: { value in
        update {
          if case .severity(let comparison, _) = $0.condition {
            $0.condition = .severity(operator: comparison, threshold: value)
          }
        }
      }
    )
  }

  private var booleanBinding: Binding<Bool> {
    Binding(
      get: {
        if case .boolean(let value) = rule.condition { return value }
        return true
      },
      set: { value in update { $0.condition = .boolean(is: value) } }
    )
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<AlertRule, Value>) -> Binding<Value> {
    Binding(
      get: { rule[keyPath: keyPath] },
      set: { value in update { $0[keyPath: keyPath] = value } }
    )
  }

  private func optionalStringBinding(_ keyPath: WritableKeyPath<AlertRule, String?>) -> Binding<
    String
  > {
    Binding(
      get: { rule[keyPath: keyPath] ?? "" },
      set: { value in update { $0[keyPath: keyPath] = value.isEmpty ? nil : value } }
    )
  }

  private func durationBinding(_ keyPath: WritableKeyPath<AlertRule, TimeInterval>) -> Binding<
    String
  > {
    Binding(
      get: { String(Int(rule[keyPath: keyPath])) },
      set: { value in
        guard let seconds = TimeInterval(value), seconds >= 0 else { return }
        update { $0[keyPath: keyPath] = seconds }
      }
    )
  }

  private func optionalDoubleBinding(_ keyPath: WritableKeyPath<AlertRule, Double?>) -> Binding<
    String
  > {
    Binding(
      get: { rule[keyPath: keyPath].map { String($0) } ?? "" },
      set: { value in
        update { $0[keyPath: keyPath] = value.isEmpty ? nil : Double(value) }
      }
    )
  }

  private func channelBinding(_ kind: NotificationChannelKind) -> Binding<Bool> {
    Binding(
      get: { rule.channels.contains(kind) },
      set: { enabled in
        update { rule in
          if enabled { rule.channels.insert(kind) } else { rule.channels.remove(kind) }
        }
      }
    )
  }

  private var titleTemplateBinding: Binding<String> {
    templateMode == .recovery ? binding(\.recoveryTitleTemplate) : binding(\.alertTitleTemplate)
  }

  private var bodyTemplateBinding: Binding<String> {
    templateMode == .recovery ? binding(\.recoveryBodyTemplate) : binding(\.alertBodyTemplate)
  }

  private var templateError: String? {
    do {
      _ = try NotificationTemplateRenderer.parse(titleTemplateBinding.wrappedValue)
      _ = try NotificationTemplateRenderer.parse(bodyTemplateBinding.wrappedValue)
      let title = try NotificationTemplateRenderer.render(
        titleTemplateBinding.wrappedValue, values: previewValues)
      let body = try NotificationTemplateRenderer.render(
        bodyTemplateBinding.wrappedValue, values: previewValues)
      let message = NotificationMessage(
        eventID: "preview",
        deviceName: previewValues["device.name"] ?? "Mac",
        ruleID: rule.id.uuidString,
        state: templateMode,
        occurredAt: Date(),
        title: title,
        body: body,
        metric: nil
      )
      try message.validate()
      return nil
    } catch {
      return L10n.string("Template contains an unknown variable or is too long.")
    }
  }

  private var templatePreview: (title: String, body: String) {
    let title =
      (try? NotificationTemplateRenderer.render(
        titleTemplateBinding.wrappedValue, values: previewValues)) ?? ""
    let body =
      (try? NotificationTemplateRenderer.render(
        bodyTemplateBinding.wrappedValue, values: previewValues)) ?? ""
    return (title, body)
  }

  private var previewValues: [String: String] {
    AlertTemplateContextBuilder.values(
      rule: rule,
      observation: previewObservation,
      deviceName: model.settings.notificationSettings.resolvedDeviceName(
        systemName: Host.current().localizedName),
      state: templateMode
    )
  }

  private var previewObservation: AlertMetricObservation {
    let value: AlertMetricValue
    switch definition?.valueKind {
    case .number: value = .number(0.92)
    case .severity: value = .severity(2)
    case .boolean: value = .boolean(true)
    case .event: value = .event(sourceID: "preview")
    case nil: value = .number(0)
    }
    return .value(
      metricID: rule.metricID,
      targetID: rule.targetID,
      value: value,
      sampledAt: Date(),
      context: [
        "target.name": rule.targetID ?? L10n.string("System"),
        "event.kind": "darkWake",
        "event.reason": "RTC",
      ]
    )
  }

  private func appendVariable(_ variable: String) {
    bodyTemplateBinding.wrappedValue += "{{\(variable)}}"
  }

  private var enabledChannelKinds: Set<NotificationChannelKind> {
    Set(
      NotificationChannelKind.allCases.filter {
        model.settings.notificationSettings.channel($0).isEnabled
      })
  }

  private var canSave: Bool {
    templateError == nil
      && !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !rule.channels.intersection(enabledChannelKinds).isEmpty
      && (definition?.supportsTargets != true || rule.targetID != nil)
  }

  private func saveRule() {
    let sanitized = rule.limitingChannels(to: enabledChannelKinds)
    model.updateNotificationSettings { settings in
      guard let index = settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
      settings.rules[index] = sanitized
    }
    rule = sanitized
  }

  private func update(_ mutation: (inout AlertRule) -> Void) {
    mutation(&rule)
  }
}

extension NotificationChannelKind {
  fileprivate var title: String {
    switch self {
    case .system: return L10n.string("System Notifications")
    case .feishu: return L10n.string("Feishu")
    case .webhook: return L10n.string("Webhook")
    case .bark: return L10n.string("Bark")
    case .telegram: return L10n.string("Telegram")
    }
  }
}

extension AlertMetricID {
  fileprivate var displayTitle: String { L10n.string(rawValue) }
}

extension AlertMetricUnit {
  fileprivate var shortTitle: String {
    switch self {
    case .fraction: return "%"
    case .bytes: return "B"
    case .bytesPerSecond: return "B/s"
    case .operationsPerSecond: return "ops/s"
    case .celsius: return "°C"
    case .rpm: return "RPM"
    case .watts: return "W"
    case .percentPerHour: return "%/h"
    case .load, .none: return ""
    }
  }
}
