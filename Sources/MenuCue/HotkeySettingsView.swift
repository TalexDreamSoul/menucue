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

  init(model: AppModel) {
    self.model = model
    self.hotkeyService = model.hotkeyService
    self.quickActionService = model.quickActionService
  }

  var body: some View {
    SettingsGroup(spacing: 12) {
      header

      if bindings.isEmpty {
        emptyState
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            HotkeyBindingRow(
              entry: entry,
              onToggle: { model.setHotkeyBinding(id: entry.binding.id, isEnabled: $0) },
              onEdit: { sheetTarget = HotkeySheetTarget(binding: entry.binding, isNew: false) },
              onDelete: { model.removeHotkeyBinding(id: entry.binding.id) }
            )
            if index < bindings.count - 1 {
              Divider()
            }
          }
        }
      }
    }
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

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Global shortcuts")
          .font(.headline)
        Text("Each shortcut runs its action from anywhere, whichever app is in front.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button {
        sheetTarget = HotkeySheetTarget(binding: HotkeyBinding(), isNew: true)
      } label: {
        Label("Add Shortcut", systemImage: "plus")
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No global shortcuts yet.")
        .font(.subheadline)
      Text("Add one to run a Quick Action, a Shortcut, or a window action from the keyboard.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 14)
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

private struct HotkeyBindingRow: View {
  let entry: HotkeyBindingEntry
  let onToggle: (Bool) -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Toggle(
        "Enabled",
        isOn: Binding(get: { entry.binding.isEnabled }, set: onToggle)
      )
      .labelsHidden()
      .accessibilityLabel(
        L10n.format("Enable %@", entry.binding.settingsDisplayName(actionTitle: entry.item?.title))
      )

      Button(action: onEdit) {
        HStack(spacing: 10) {
          HotkeyShortcutChip(shortcut: entry.binding.shortcut)

          VStack(alignment: .leading, spacing: 3) {
            if !entry.binding.name.isEmpty {
              Text(entry.binding.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            }
            Label(entry.actionTitle, systemImage: entry.item?.systemImage ?? "questionmark.circle")
              .font(entry.binding.name.isEmpty ? .subheadline : .caption)
              .foregroundStyle(entry.item == nil ? .secondary : .primary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Edit shortcut")

      // Two different failures, and a row has to tell them apart: the action cannot run,
      // or the combination was never granted in the first place.
      if let registrationFailure = entry.registrationFailure {
        ActionUnavailableBadge(reason: registrationFailure)
      } else if !entry.availability.isAvailable {
        ActionUnavailableBadge(
          reason: entry.availability.reason,
          settingsURL: entry.availability.settingsURL
        )
      }

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
    .padding(.vertical, 8)
    .opacity(entry.binding.isEnabled ? 1 : 0.68)
  }
}

/// The combination itself, drawn the way a menu draws one: the modifier glyphs and the key,
/// monospaced so a column of them lines up.
private struct HotkeyShortcutChip: View {
  let shortcut: TrackpadKeyboardShortcut

  var body: some View {
    Text(shortcut.isUnset ? L10n.string("Not set") : shortcut.displayText)
      .font(.subheadline.monospaced())
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Color.primary.opacity(0.07),
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .frame(minWidth: 76, alignment: .leading)
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
