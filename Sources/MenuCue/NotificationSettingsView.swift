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
    VStack(alignment: .leading, spacing: 24) {
      if let message = model.notificationRuntimeErrorMessage {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
      }
      identitySection
      Divider()
      channelSection
      Divider()
      ruleSection
    }
    .onAppear {
      if selectedRuleID == nil {
        selectedRuleID = model.settings.notificationSettings.rules.first?.id
      }
    }
  }

  private var identitySection: some View {
    SettingsGroup(spacing: 12) {
      Text("Device Identity").font(.headline)
      HStack(spacing: 10) {
        TextField("Device name", text: deviceNameBinding)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 360)
        Button("Reset") {
          model.updateNotificationSettings { $0.setDeviceNameOverride(nil) }
        }
        .disabled(model.settings.notificationSettings.deviceNameOverride == nil)
      }
      Text(
        model.settings.notificationSettings.resolvedDeviceName(
          systemName: Host.current().localizedName)
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var channelSection: some View {
    SettingsGroup(spacing: 14) {
      Text("Channels").font(.headline)
      ForEach(NotificationChannelKind.allCases, id: \.self) { kind in
        NotificationChannelRow(model: model, configuration: configuration, kind: kind)
        if kind != NotificationChannelKind.allCases.last { Divider() }
      }
    }
  }

  private var ruleSection: some View {
    SettingsGroup(spacing: 14) {
      HStack {
        Text("Alert Rules").font(.headline)
        Spacer()
        Button {
          addRule()
        } label: {
          Label("Add Rule", systemImage: "plus")
        }
      }

      if model.settings.notificationSettings.rules.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "bell.slash")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("No Alert Rules")
            .font(.headline)
          Text("Add a rule to monitor system metrics or dark wakes.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        HStack(alignment: .top, spacing: 20) {
          ruleList
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 250)
          Divider()
          if let selectedRuleID,
            let rule = model.settings.notificationSettings.rules.first(where: {
              $0.id == selectedRuleID
            })
          {
            AlertRuleEditor(model: model, rule: rule)
              .id(rule.id)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text("Select a rule")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: 180)
          }
        }
      }
    }
  }

  private var ruleList: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(model.settings.notificationSettings.rules) { rule in
        Button {
          selectedRuleID = rule.id
        } label: {
          HStack(spacing: 8) {
            Image(systemName: rule.isEnabled ? "bell.fill" : "bell.slash")
              .foregroundStyle(rule.isEnabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(rule.name).lineLimit(1)
              Text(rule.metricID.displayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .frame(height: 44)
          .background(
            selectedRuleID == rule.id ? Color.accentColor.opacity(0.12) : Color.clear
          )
          .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
      }

      if let selectedRuleID {
        Button(role: .destructive) {
          model.updateNotificationSettings { settings in
            settings.rules.removeAll { $0.id == selectedRuleID }
          }
          self.selectedRuleID = model.settings.notificationSettings.rules.first?.id
        } label: {
          Label("Delete Rule", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .padding(.top, 4)
      }
    }
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
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: kind.systemImage)
          .frame(width: 20)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(kind.title).font(.subheadline.weight(.medium))
          statusText
        }
        Spacer()
        Toggle("Enabled", isOn: enabledBinding).labelsHidden()
          .accessibilityLabel(L10n.format("Enable %@", kind.title))
        Button(isExpanded ? "Done" : "Configure") { isExpanded.toggle() }
      }

      if isExpanded {
        channelFields
          .padding(.leading, 30)
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.leading, 30)
      }
    }
  }

  @ViewBuilder
  private var channelFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch kind {
      case .feishu:
        secretField("Webhook URL", key: NotificationSecretField.feishuWebhook, optional: false)
        secretField(
          "Signing secret", key: NotificationSecretField.feishuSigningSecret, optional: true)
      case .webhook:
        secretField("Endpoint URL", key: NotificationSecretField.webhookEndpoint, optional: false)
        secretField(
          "Bearer token", key: NotificationSecretField.webhookBearerToken, optional: true)
      case .bark:
        secretField("Device key", key: NotificationSecretField.barkDeviceKey, optional: false)
        TextField("Server URL", text: channelBinding(\.barkServerURL))
          .textFieldStyle(.roundedBorder)
        TextField("Group", text: channelBinding(\.barkGroup))
          .textFieldStyle(.roundedBorder)
      case .telegram:
        secretField("Bot token", key: NotificationSecretField.telegramBotToken, optional: false)
        TextField("Chat ID", text: channelBinding(\.telegramChatID))
          .textFieldStyle(.roundedBorder)
        TextField("Topic ID (optional)", text: threadIDBinding)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Button("Send Test") {
          Task { await model.testNotificationChannel(kind) }
        }
        .disabled(
          !configuration.canEnable(kind, settings: model.settings.notificationSettings)
            || configuration.testState(for: kind) == .testing
        )
        Spacer()
      }
    }
    .frame(maxWidth: 460)
  }

  private func secretField(
    _ title: LocalizedStringKey,
    key: NotificationSecretKey,
    optional: Bool
  ) -> some View {
    let binding = optional ? $optionalSecret : $primarySecret
    return HStack(spacing: 8) {
      SecureField(title, text: binding)
        .textFieldStyle(.roundedBorder)
      Button("Save") {
        do {
          try model.saveNotificationSecret(binding.wrappedValue, for: key)
          binding.wrappedValue = ""
          errorMessage = nil
        } catch {
          errorMessage = L10n.string("Credential could not be saved.")
        }
      }
      .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      if configuration.hasSavedSecret(key) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityLabel("Saved")
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
        .help("Remove credential")
        .accessibilityLabel("Remove credential")
      }
    }
  }

  @ViewBuilder
  private var statusText: some View {
    switch configuration.testState(for: kind) {
    case .idle:
      Text(
        configuration.canEnable(kind, settings: model.settings.notificationSettings)
          ? "Ready" : "Not configured"
      )
      .font(.caption).foregroundStyle(.secondary)
    case .testing:
      Text("Testing…").font(.caption).foregroundStyle(.secondary)
    case .succeeded:
      Text("Test succeeded").font(.caption).foregroundStyle(.green)
    case .failed(let message):
      Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
    }
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
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        TextField("Rule name", text: binding(\.name))
          .textFieldStyle(.roundedBorder)
        Toggle("Enabled", isOn: binding(\.isEnabled))
          .toggleStyle(.switch)
        Button("Save Rule", action: saveRule)
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
      }

      Picker("Metric", selection: metricBinding) {
        ForEach(AlertMetricCatalog.all, id: \.id) { metric in
          Text(metric.id.displayTitle).tag(metric.id)
        }
      }
      .frame(maxWidth: 420)

      if definition?.supportsTargets == true {
        TextField("Target ID", text: optionalStringBinding(\.targetID))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 420)
      }

      conditionControls

      if definition?.valueKind == .event {
        HStack {
          Text("Cooldown")
          TextField("Seconds", text: durationBinding(\.cooldown))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
          Text("seconds").foregroundStyle(.secondary)
        }
      } else {
        timingControls
      }

      channelControls
      templateControls
    }
  }

  @ViewBuilder
  private var conditionControls: some View {
    switch rule.condition {
    case .numeric:
      HStack {
        Picker("Condition", selection: numericOperatorBinding) {
          Text("Above").tag(AlertComparisonOperator.above)
          Text("Below").tag(AlertComparisonOperator.below)
        }
        .frame(width: 190)
        TextField("Threshold", text: numericThresholdBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 110)
        Text(definition?.unit.shortTitle ?? "")
          .foregroundStyle(.secondary)
      }
    case .severity:
      HStack {
        Picker("Condition", selection: severityOperatorBinding) {
          Text("At least").tag(AlertComparisonOperator.atLeast)
          Text("At most").tag(AlertComparisonOperator.atMost)
        }
        Picker("Level", selection: severityThresholdBinding) {
          Text("Normal").tag(1)
          Text("Warning").tag(2)
          Text("Critical").tag(3)
        }
      }
    case .boolean:
      Toggle("Expected value", isOn: booleanBinding)
    case .event:
      Label("Each new dark wake triggers this rule once.", systemImage: "moon.zzz")
        .foregroundStyle(.secondary)
    }
  }

  private var timingControls: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
      GridRow {
        Text("Sustained")
        TextField("Seconds", text: durationBinding(\.alertDuration))
          .textFieldStyle(.roundedBorder)
        Text("seconds").foregroundStyle(.secondary)
      }
      if case .numeric = rule.condition {
        GridRow {
          Text("Recovery threshold")
          TextField("Threshold", text: optionalDoubleBinding(\.recoveryThreshold))
            .textFieldStyle(.roundedBorder)
          Text(definition?.unit.shortTitle ?? "").foregroundStyle(.secondary)
        }
      }
      GridRow {
        Text("Recovery sustained")
        TextField("Seconds", text: durationBinding(\.recoveryDuration))
          .textFieldStyle(.roundedBorder)
        Text("seconds").foregroundStyle(.secondary)
      }
      GridRow {
        Text("Cooldown")
        TextField("Seconds", text: durationBinding(\.cooldown))
          .textFieldStyle(.roundedBorder)
        Text("seconds").foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: 430)
  }

  private var channelControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Deliver to").font(.subheadline.weight(.medium))
      HStack(spacing: 14) {
        ForEach(NotificationChannelKind.allCases, id: \.self) { kind in
          Toggle(kind.title, isOn: channelBinding(kind))
            .disabled(!model.settings.notificationSettings.channel(kind).isEnabled)
        }
      }
    }
  }

  private var templateControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Picker("Message", selection: $templateMode) {
          Text("Alert").tag(NotificationEventState.alert)
          if definition?.valueKind != .event {
            Text("Recovery").tag(NotificationEventState.recovery)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        Spacer()
        Menu {
          ForEach(NotificationTemplateRenderer.allowedVariables.sorted(), id: \.self) { variable in
            Button("{{\(variable)}}") { appendVariable(variable) }
          }
        } label: {
          Label("Variable", systemImage: "curlybraces")
        }
      }

      TextField("Title template", text: titleTemplateBinding)
        .textFieldStyle(.roundedBorder)
      TextEditor(text: bodyTemplateBinding)
        .font(.body)
        .frame(minHeight: 72)
        .padding(5)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor))
        )

      if let templateError {
        Text(templateError).font(.caption).foregroundStyle(.red)
      } else {
        VStack(alignment: .leading, spacing: 3) {
          Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          Text(templatePreview.title).font(.subheadline.weight(.medium))
          Text(templatePreview.body).font(.caption).foregroundStyle(.secondary)
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
    case .feishu: return L10n.string("Feishu")
    case .webhook: return L10n.string("Webhook")
    case .bark: return L10n.string("Bark")
    case .telegram: return L10n.string("Telegram")
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .feishu: return "bubble.left.and.text.bubble.right"
    case .webhook: return "arrow.triangle.branch"
    case .bark: return "app.badge"
    case .telegram: return "paperplane"
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
