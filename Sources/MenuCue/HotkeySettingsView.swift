import SwiftUI

/// Keyboard Shortcuts pane: every global combination this Mac answers to, and the catalog
/// action each one runs.
///
/// A shortcut is claimed from the system the moment it is saved, so this pane reports what
/// the system said back: a combination another application already holds shows the refusal
/// on its own row instead of quietly doing nothing when pressed.
struct HotkeySettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @ObservedObject var model: AppModel
  @ObservedObject private var hotkeyService: HotkeyService
  @ObservedObject private var quickActionService: QuickActionService

  @State private var sheetTarget: HotkeySheetTarget?
  @State private var restoreFeedback: String?

  init(model: AppModel) {
    self.model = model
    self.hotkeyService = model.hotkeyService
    self.quickActionService = model.quickActionService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      globalShortcutsCard
      shortcutsCard
      actionLibraryCard
      builtInDefaultsCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(motion.stateAnimation, value: bindings)
    .onAppear {
      quickActionService.refreshAll()
    }
    .sheet(item: $sheetTarget) { target in
      HotkeyEditorSheet(
        model: model,
        binding: target.binding,
        isNew: target.isNew,
        others: bindings.filter { $0.id != target.binding.id },
        onSave: { model.upsertHotkeyBinding($0) },
        onDelete: { model.removeHotkeyBinding(id: $0) }
      )
    }
  }

  /// The master switch, above the list: it decides whether any combination is claimed from
  /// the system at all, which is a different question from which combination runs what.
  private var globalShortcutsCard: some View {
    SettingsCard(
      L10n.string("Global shortcuts"),
      desc: L10n.string("MenuCue answers these combinations from any application.")
    ) {
      SettingsRows {
        SettingsRowToggle(
          L10n.string("Enable Global Shortcuts"),
          desc: L10n.string("Off keeps every binding but registers none of them."),
          isOn: model.settingsBinding(\.hotkeysGloballyEnabled)
        )

        SettingsRow(L10n.string("Current")) {
          HStack(spacing: 8) {
            if bindingsAreRegistered {
              SettingsChip(
                L10n.format("%d registered", registeredCount),
                systemImage: "checkmark",
                tint: .accentColor,
                prominent: true
              )
            } else {
              SettingsChip(L10n.string("Paused"), systemImage: "pause")
            }
            SettingsChip(
              L10n.format("%d unavailable", unavailableCount),
              systemImage: unavailableCount > 0 ? "exclamationmark.triangle" : nil,
              tint: unavailableCount > 0 ? .orange : nil
            )
          }
        }
      }
    }
  }

  /// The catalog is the single definition of every action, so the pane says so and hands the
  /// reader over instead of restating the catalog here.
  private var actionLibraryCard: some View {
    SettingsCard(L10n.string("Actions Come from the Action Library"), tone: .inset) {
      SettingsRows {
        SettingsPaneLinkRow(
          L10n.string("Action Library"),
          desc: L10n.string("Shortcuts, gestures, and the panel all reference the same action definitions."),
          destination: .actionCenter,
          actionTitle: L10n.string("See All Actions and References")
        )
        SettingsRow(
          L10n.string("Needs ⌘, ⌃ or ⌥"),
          desc: L10n.string("A combination with no modifier would intercept everyday typing, so it is rejected when saved.")
        ) {
          SettingsChip(L10n.string("Checked when saved"))
        }
        SettingsRow(
          L10n.string("System Claims"),
          desc: L10n.string("A combination macOS or another application already owns stays theirs; this shortcut will not fire.")
        ) {
          SettingsChip(L10n.string("Cannot Be Detected"))
        }
      }
    }
  }

  /// The defaults are merged silently when a stored list predates them; this is the explicit
  /// door to the same merge for what was deleted afterwards.
  private var builtInDefaultsCard: some View {
    SettingsCard(
      L10n.string("Built-in Defaults"),
      desc: L10n.string("MenuCue ships a set of default shortcuts and merges any that are missing when a stored list is older than the app."),
      tone: .inset
    ) {
      SettingsRows {
        SettingsRowButton(
          L10n.string("Restore Built-in Defaults"),
          desc: L10n.string("Only adds missing defaults; it never overwrites a combination you set yourself."),
          buttonTitle: L10n.string("Restore"),
          kind: .secondary
        ) {
          let restored = model.restoreBuiltInHotkeyDefaults()
          restoreFeedback =
            restored == 0
            ? L10n.string("Every built-in default is already present.")
            : L10n.format("%d shortcuts restored", restored)
        }
        if let restoreFeedback {
          SettingsRow(restoreFeedback) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }
      }
    }
  }

  private var bindingsAreRegistered: Bool {
    model.settings.hotkeysGloballyEnabled
  }

  private var registeredCount: Int {
    guard bindingsAreRegistered else { return 0 }
    return entries.filter { entry in
      entry.binding.isEnabled && entry.registrationFailure == nil && entry.availability.isAvailable
    }.count
  }

  private var unavailableCount: Int {
    entries.filter { entry in
      entry.registrationFailure != nil || !entry.availability.isAvailable
    }.count
  }

  /// One card, because the pane is one list. The table's columns are the design document's,
  /// and adding a shortcut sits on the title line, where every card keeps its action.
  private var shortcutsCard: some View {
    SettingsCard(
      L10n.string("Global shortcuts"),
      desc: L10n.string(
        "A shortcut only defines how to trigger an action; the action itself comes from the action library."
      ),
      action: {
        Button {
          sheetTarget = HotkeySheetTarget(binding: HotkeyBinding(), isNew: true)
        } label: {
          Label(L10n.string("Add Shortcut"), systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
    ) {
      if entries.isEmpty {
        SettingsEmptyState(
          L10n.string("No global shortcuts yet."),
          desc: L10n.string("Add one to run a Quick Action, a Shortcut, or a window action from the keyboard."),
          systemImage: "keyboard"
        )
      } else {
        SettingsTable(columns: shortcutColumns) {
          ForEach(entries) { entry in
            HotkeyBindingTableRow(
              entry: entry,
              onToggle: { model.setHotkeyBinding(id: entry.binding.id, isEnabled: $0) },
              onEdit: { sheetTarget = HotkeySheetTarget(binding: entry.binding, isNew: false) },
              onDelete: { model.removeHotkeyBinding(id: entry.binding.id) }
            )
          }
        }
      }
    }
  }

  /// The document's five columns, with the document's own proportions: the action title is
  /// the widest cell, and the trailing control column stays narrow. Weights are shares of
  /// the card's inner width, so the header and every row resolve the same grid.
  private var shortcutColumns: [SettingsTableColumn] {
    [
      SettingsTableColumn(L10n.string("Key combination"), weight: 110),
      SettingsTableColumn(L10n.string("Action"), weight: 190),
      SettingsTableColumn(L10n.string("Name"), weight: 90),
      SettingsTableColumn(L10n.string("Status"), weight: 100),
      SettingsTableColumn("", weight: 74),
    ]
  }

  private var bindings: [HotkeyBinding] {
    model.settings.hotkeyBindings
  }

  /// Resolved once for the pane: each row would otherwise re-read the Accessibility state
  /// and the Shortcuts list for itself.
  private var entries: [HotkeyBindingEntry] {
    let items = ActionCatalog.allItems(shortcuts: quickActionService.shortcuts)
    let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return bindings.map { binding in
      HotkeyBindingEntry(
        binding: binding,
        item: itemsByID[binding.actionItemID],
        availability: model.hotkeyActionAvailability(binding.actionItemID),
        registrationFailure: hotkeyService.unavailableReasons[binding.id]
      )
    }
  }
}

/// Which binding the editor sheet is open on. A new binding carries its blank draft here
/// rather than into the stored list, so nothing exists until the sheet saves.
private struct HotkeySheetTarget: Identifiable {
  let binding: HotkeyBinding
  let isNew: Bool

  var id: UUID { binding.id }
}

/// One binding with everything a row has to state: what it runs, whether that action can
/// run today, and whether the system granted the combination.
private struct HotkeyBindingEntry: Identifiable {
  let binding: HotkeyBinding
  let item: ActionCatalogItem?
  let availability: ActionAvailability
  let registrationFailure: String?

  var id: UUID { binding.id }

  /// A Shortcut that is missing right now still shows the name it was bound to, because
  /// "the Shortcut named Foo is gone" is a different message from "this row points at
  /// nothing"; the badge beside it is what says which one happened.
  var actionTitle: String {
    item?.title ?? staleActionTitle(for: binding.actionItemID)
  }
}

/// What to call an action the catalog can no longer find. A Shortcut keeps the name it was
/// bound to — that is the part the user recognizes, and the only clue to what went missing.
private func staleActionTitle(for itemID: String) -> String {
  if let reference = QuickActionReference(storageValue: itemID) {
    return reference.displayTitle
  }
  return L10n.string("This action is no longer available.")
}

/// One row of the shortcut table. Everything but the enable switch and the row menu opens
/// the editor sheet: the row states what the shortcut is, and the sheet is where it is
/// changed.
///
/// Every cell fills its column share — the empty status cell included — because a cell
/// that hugged its content would take a different share than the header's and slide the
/// columns out of line.
private struct HotkeyBindingTableRow: View {
  let entry: HotkeyBindingEntry
  let onToggle: (Bool) -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    SettingsTableRow {
      shortcutCell
      actionCell
      nameCell
      statusCell
      controlsCell
    }
    // The dimming is for the row's content, not for its fill: a row blended with the
    // hairline behind the table would tint the whole cell grey instead of quietening it.
    .opacity(entry.binding.isEnabled ? 1 : 0.68)
    .background(Color.settingsCardSurface)
  }

  /// The combination itself, or the fact that none was ever recorded.
  private var shortcutCell: some View {
    SettingsChip(
      entry.binding.shortcut.isUnset ? L10n.string("Not set") : entry.binding.shortcut.displayText,
      tint: entry.binding.shortcut.isUnset ? nil : Color.primary
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var actionCell: some View {
    Button(action: onEdit) {
      HStack(spacing: 6) {
        Image(systemName: entry.item?.systemImage ?? "questionmark.circle")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
        Text(entry.actionTitle)
          .font(.system(size: 12))
          .foregroundStyle(entry.item == nil ? .secondary : .primary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Edit shortcut")
  }

  private var nameCell: some View {
    Text(entry.binding.name.isEmpty ? "—" : entry.binding.name)
      .font(.system(size: 12))
      .foregroundStyle(entry.binding.name.isEmpty ? .tertiary : .primary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Two different failures, and a row has to tell them apart: the action cannot run, or
  /// the combination was never granted in the first place. Only a healthy, enabled row is
  /// one the system confirmed.
  @ViewBuilder
  private var statusCell: some View {
    if let registrationFailure = entry.registrationFailure {
      ActionUnavailableBadge(reason: registrationFailure)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if !entry.availability.isAvailable {
      ActionUnavailableBadge(
        reason: entry.availability.reason,
        settingsURL: entry.availability.settingsURL
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if entry.binding.isEnabled {
      SettingsChip(L10n.string("Registered"), systemImage: "checkmark", tint: .green)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Color.clear.frame(maxWidth: .infinity)
    }
  }

  private var controlsCell: some View {
    HStack(spacing: 10) {
      Toggle(
        "Enabled",
        isOn: Binding(get: { entry.binding.isEnabled }, set: onToggle)
      )
      .labelsHidden()
      .accessibilityLabel(
        L10n.format("Enable %@", entry.binding.settingsDisplayName(actionTitle: entry.item?.title))
      )

      Menu {
        Button(action: onEdit) {
          Label("Edit Shortcut", systemImage: "slider.horizontal.3")
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
          Label("Delete Shortcut", systemImage: "trash")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel(
        L10n.format(
          "Actions for %@",
          entry.binding.settingsDisplayName(actionTitle: entry.item?.title)
        )
      )
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// One binding, edited apart from the list. Save is refused until the combination and the
/// action are both something the system can be asked for, so a shortcut that could never
/// work is caught while it is being written rather than on the first press.
private struct HotkeyEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: AppModel
  let isNew: Bool
  let others: [HotkeyBinding]
  let onSave: (HotkeyBinding) -> Void
  let onDelete: (UUID) -> Void

  @State private var draft: HotkeyBinding

  init(
    model: AppModel,
    binding: HotkeyBinding,
    isNew: Bool,
    others: [HotkeyBinding],
    onSave: @escaping (HotkeyBinding) -> Void,
    onDelete: @escaping (UUID) -> Void
  ) {
    self.model = model
    self.isNew = isNew
    self.others = others
    self.onSave = onSave
    self.onDelete = onDelete
    _draft = State(initialValue: binding)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          shortcutSection
          Divider()
          actionSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }

      Divider()
      footer
    }
    .frame(width: 480)
    .frame(minHeight: 360, idealHeight: 420, maxHeight: 560)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(isNew ? L10n.string("New Shortcut") : L10n.string("Edit Shortcut"))
        .font(.headline)

      LabeledContent("Name") {
        TextField("Optional name", text: $draft.name)
          .textFieldStyle(.roundedBorder)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  private var shortcutSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Shortcut")
        .font(.subheadline.weight(.semibold))

      LabeledContent("Key combination") {
        TrackpadShortcutRecorder(
          shortcut: $draft.shortcut,
          help: "Click, then press the combination that runs this action."
        )
      }

      Text("A global shortcut needs ⌘, ⌃, or ⌥ so it cannot capture ordinary typing.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      // macOS does not report losing a combination it keeps for itself, so the only place
      // this can be said is before the shortcut is recorded.
      Text("A combination macOS or another app already uses keeps working there, and this shortcut stays silent.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let message = validation.message {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var actionSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Action")
        .font(.subheadline.weight(.semibold))

      LabeledContent("Runs") {
        Picker("Runs", selection: $draft.actionItemID) {
          if draft.actionItemID.isEmpty {
            Text("Choose an action…").tag("")
          } else if !items.contains(where: { $0.id == draft.actionItemID }) {
            // A Shortcut renamed since the binding was written matches no row here. It
            // still needs a tag of its own: a selection with nothing to select is one the
            // picker may quietly replace with its first entry, which would repoint the
            // shortcut at an unrelated action without the user touching it.
            Text(staleActionTitle(for: draft.actionItemID)).tag(draft.actionItemID)
          }
          ForEach(ActionSource.allCases) { source in
            let sourced = items.filter { $0.source == source }
            // A Mac with no Shortcuts would otherwise show that heading over nothing.
            if !sourced.isEmpty {
              Section(header: Text(source.title)) {
                ForEach(sourced) { item in
                  Text(item.title).tag(item.id)
                }
              }
            }
          }
        }
        .labelsHidden()
        .frame(maxWidth: 300)
      }

      availabilityNotice

      Text("Actions that place or move windows ask for Accessibility the first time they run.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// What is wrong with this action right now, as opposed to what it requires in general:
  /// only shown when the shortcut would fail if it were pressed this second.
  @ViewBuilder
  private var availabilityNotice: some View {
    let availability = model.hotkeyActionAvailability(draft.actionItemID)
    if !draft.actionItemID.isEmpty, !availability.isAvailable, let reason = availability.reason {
      VStack(alignment: .leading, spacing: 7) {
        Label(reason, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        if let settingsURL = availability.settingsURL {
          Button("Open System Settings") {
            WorkspaceOpener.openSettings(settingsURL)
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if !isNew {
        Button("Delete Shortcut", role: .destructive) {
          onDelete(draft.id)
          dismiss()
        }
      }

      Spacer(minLength: 0)

      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)

      Button("Save") {
        onSave(draft.normalized)
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .disabled(!validation.isValid)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  private var items: [ActionCatalogItem] {
    ActionCatalog.items(surface: .hotkey, shortcuts: model.quickActionService.shortcuts)
  }

  private var validation: HotkeyBindingValidation {
    HotkeyBindingPolicy.validate(
      draft,
      against: others,
      actionTitles: Dictionary(
        items.map { ($0.id, $0.title) },
        uniquingKeysWith: { first, _ in first }
      )
    )
  }
}

extension AppModel {
  /// Whether the action a binding names could run right now, asked the same way each
  /// surface asks it: the Quick Action's own state, or the executor's permission check.
  fileprivate func hotkeyActionAvailability(_ itemID: String) -> ActionAvailability {
    guard !itemID.isEmpty, let route = ActionCatalog.route(forItemID: itemID) else {
      return .unavailable(L10n.string("This action is no longer available."))
    }
    switch route {
    case .quickAction(let reference):
      return quickActionService.item(for: reference).state.availability
    case .trackpad(let action):
      return trackpadGestureService.availability(for: action)
    case .trackpadPointerWindow:
      return .available
    case .tabNavigation:
      return trackpadGestureService.availability(
        for: TrackpadGestureAction(kind: .keyboardShortcut)
      )
    }
  }
}
