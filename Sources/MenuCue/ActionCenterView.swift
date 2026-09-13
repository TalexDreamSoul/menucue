import SwiftUI

/// Action Center settings pane: the whole register of what MenuCue can do, split by where
/// each entry comes from, with what already depends on it.
///
/// Nothing runs from a row tap here. Arranging actions and running them are different
/// jobs, and one of these actions empties the Trash — the popover is the execution
/// surface, and this pane's Run button is the only way to fire an action from Settings.
///
/// Presentation follows the v1.0.0 design document's "J · 动作库" pane: a pinned card and
/// one catalog card, both built from the shared settings design system.
struct ActionCenterSettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService

  @State private var selectedSource: ActionSource?
  @State private var pendingDestructiveReference: QuickActionReference?

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      pinnedCard
      catalogCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      service.refreshAll()
    }
    .confirmationDialog(
      "Empty Trash?",
      isPresented: destructiveConfirmationBinding,
      titleVisibility: .visible
    ) {
      Button("Empty Trash", role: .destructive) {
        if let reference = pendingDestructiveReference {
          service.perform(reference)
        }
        pendingDestructiveReference = nil
      }
      Button("Cancel", role: .cancel) { pendingDestructiveReference = nil }
    } message: {
      Text("This permanently removes every item in your user Trash.")
    }
  }

  private var pinnedCard: some View {
    SettingsCard(
      L10n.string("Pinned actions"),
      desc: L10n.string(
        "The menu-bar popover shows these actions before the fixed More button. Limit: 7."
      ),
      action: {
        SettingsChip(
          L10n.format("%d / 7", model.settings.pinnedQuickActions.count),
          tint: model.settings.pinnedQuickActions.count == 7 ? .orange : nil
        )
        .menuCueNumericTransition(value: model.settings.pinnedQuickActions.count)
      }
    ) {
      if model.settings.pinnedQuickActions.isEmpty {
        SettingsRows {
          SettingsEmptyState(
            L10n.string("No pinned actions"),
            desc: L10n.string("The popover will show only its More button."),
            systemImage: "pin"
          )
        }
      } else {
        SettingsRows {
          ForEach(Array(model.settings.pinnedQuickActions.enumerated()), id: \.element.id) {
            index, reference in
            let item = service.item(for: reference)
            PinnedActionRow(
              item: item,
              canMoveUp: index > 0,
              canMoveDown: index < model.settings.pinnedQuickActions.count - 1,
              moveUp: { model.movePinnedQuickAction(at: index, by: -1) },
              moveDown: { model.movePinnedQuickAction(at: index, by: 1) },
              remove: { model.removePinnedQuickAction(reference) }
            )
            .transition(motion.revealTransition(edge: .top))
          }
        }
      }
    }
    .animation(motion.stateAnimation, value: model.settings.pinnedQuickActions)
  }

  private var catalogCard: some View {
    // Resolved once for the whole pane: each section filters this list rather than
    // re-reading system state for every row it draws.
    let entries = self.entries
    return SettingsCard(
      L10n.string("All actions"),
      desc: L10n.string(
        "Run is the only way to fire an action from Settings; destructive actions confirm before running."
      )
    ) {
      SettingsRows {
        SettingsRow(L10n.string("Source")) {
          Picker("", selection: $selectedSource) {
            Text(L10n.string("All")).tag(ActionSource?.none)
            ForEach(ActionSource.allCases) { source in
              Text(source.title).tag(ActionSource?.some(source))
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }

        if let feedbackMessage = service.feedbackMessage {
          SettingsBanner(
            feedbackMessage,
            systemImage: "info.circle",
            tint: .accentColor
          )
          .transition(motion.revealTransition(edge: .top))
        }

        ForEach(visibleSources) { source in
          let sourceEntries = entries.filter { $0.item.source == source }
          ActionCenterGroupHeader(
            title: L10n.format("%@ · %d", source.title, sourceEntries.count),
            note: source.note
          )
          if sourceEntries.isEmpty {
            SettingsTableRow {
              Text(L10n.string("No actions are registered here yet."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
          } else {
            ForEach(sourceEntries) { entry in
              ActionCenterRow(
                entry: entry,
                isPinned: isPinned(entry),
                canPin: canPin(entry),
                run: { run(entry) },
                togglePin: { togglePin(entry) }
              )
            }
          }
        }
      }
      .animation(motion.stateAnimation, value: service.feedbackMessage)
    }
  }

  private var visibleSources: [ActionSource] {
    guard let selectedSource else { return ActionSource.allCases }
    return [selectedSource]
  }

  /// Every registered action, resolved against live state: whether it can run, whether it
  /// is on, and what already points at it.
  private var entries: [ActionCenterEntry] {
    let items = ActionCatalog.allItems(shortcuts: service.shortcuts)
    let trackpadActions = items.compactMap { item -> (String, TrackpadGestureAction)? in
      guard case .trackpad(let action) = item.route else { return nil }
      return (item.id, action)
    }
    // One Accessibility check for the whole trackpad section rather than one per row.
    let trackpadAvailability = Dictionary(
      uniqueKeysWithValues: zip(
        trackpadActions.map(\.0),
        model.trackpadGestureService.availabilities(for: trackpadActions.map(\.1))
      )
    )

    return items.map { item in
      let state = quickActionState(for: item)
      return ActionCenterEntry(
        item: item,
        availability: state?.availability ?? trackpadAvailability[item.id] ?? .available,
        isOn: state.flatMap(\.isOn),
        isRunning: state?.isRunning ?? false,
        references: ActionCatalog.references(
          of: item,
          pinned: model.settings.pinnedQuickActions,
          rules: model.settings.trackpadGestureSettings.rules,
          hotkeys: model.settings.hotkeyBindings
        )
      )
    }
  }

  private func quickActionState(for item: ActionCatalogItem) -> QuickActionState? {
    guard case .quickAction(let reference) = item.route else { return nil }
    return service.item(for: reference).state
  }

  private func isPinned(_ entry: ActionCenterEntry) -> Bool {
    entry.references.contains(.pinned)
  }

  private func canPin(_ entry: ActionCenterEntry) -> Bool {
    guard entry.item.isOffered(on: .panel) else { return false }
    if isPinned(entry) { return true }
    return model.settings.pinnedQuickActions.count < 7 && entry.availability.isAvailable
  }

  private func togglePin(_ entry: ActionCenterEntry) {
    guard let reference = entry.quickActionReference else { return }
    if isPinned(entry) {
      model.removePinnedQuickAction(reference)
    } else {
      model.addPinnedQuickAction(reference)
    }
  }

  private func run(_ entry: ActionCenterEntry) {
    guard let reference = entry.quickActionReference else { return }
    if entry.item.isDestructive {
      pendingDestructiveReference = reference
    } else {
      service.perform(reference)
    }
  }

  private var destructiveConfirmationBinding: Binding<Bool> {
    Binding(
      get: { pendingDestructiveReference != nil },
      set: { isPresented in
        if !isPresented { pendingDestructiveReference = nil }
      }
    )
  }
}

private struct ActionCenterEntry: Identifiable {
  let item: ActionCatalogItem
  let availability: ActionAvailability
  let isOn: Bool?
  let isRunning: Bool
  let references: [ActionReference]

  var id: String { item.id }

  /// Only Quick Actions can be run or pinned from here; the trackpad's own operations run
  /// from a gesture.
  var quickActionReference: QuickActionReference? {
    guard case .quickAction(let reference) = item.route else { return nil }
    return reference
  }
}

/// One pinned action: it is ordered by the two chevrons and removed by the minus, and it
/// carries the same availability reason the popover would report.
private struct PinnedActionRow: View {
  let item: QuickActionItem
  let canMoveUp: Bool
  let canMoveDown: Bool
  let moveUp: () -> Void
  let moveDown: () -> Void
  let remove: () -> Void

  var body: some View {
    SettingsListRow(
      item.title,
      desc: item.state.availability.reason,
      systemImage: item.systemImage
    ) {
      if item.isDestructive {
        SettingsChip(
          L10n.string("Destructive · Confirms before running"),
          systemImage: "exclamationmark.triangle",
          tint: .red
        )
        .lineLimit(1)
      }

      Button(action: moveUp) {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(!canMoveUp)
      .help(L10n.string("Move up"))

      Button(action: moveDown) {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(!canMoveDown)
      .help(L10n.string("Move down"))

      Button(role: .destructive, action: remove) {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help(L10n.string("Remove"))
    }
  }
}

/// Section heading inside the catalog card: where a group of actions comes from, how many
/// there are, and the one line of context that a row would otherwise have to repeat.
private struct ActionCenterGroupHeader: View {
  @Environment(\.settingsSurface) private var surface
  let title: String
  let note: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
      if let note {
        Text(note)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface)
  }
}

/// One action, with everything that already depends on it and no way to fire it by
/// accident: the row is not a control, and Run is a button of its own.
private struct ActionCenterRow: View {
  let entry: ActionCenterEntry
  let isPinned: Bool
  let canPin: Bool
  let run: () -> Void
  let togglePin: () -> Void

  var body: some View {
    SettingsTableRow {
      Image(systemName: entry.item.systemImage)
        .font(.system(size: 14))
        .foregroundStyle(iconTint)

      VStack(alignment: .leading, spacing: 3) {
        Text(entry.item.title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(entry.availability.isAvailable ? .primary : .secondary)
          .lineLimit(1)
        badges
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if entry.isRunning {
        MotionAwareProgressIndicator(scale: 0.7)
      } else if !entry.availability.isAvailable {
        ActionUnavailableBadge(reason: entry.availability.reason)
        if let settingsURL = entry.availability.settingsURL {
          Button(L10n.string("Open System Settings")) {
            WorkspaceOpener.openSettings(settingsURL)
          }
          .buttonStyle(.borderless)
          .font(.caption)
        }
      }

      if entry.quickActionReference != nil {
        Button {
          togglePin()
        } label: {
          Image(systemName: isPinned ? "pin.fill" : "pin")
            .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!canPin)
        .help(
          L10n.string(
            isPinned ? "Unpin from popover" : canPin ? "Pin to popover" : "Pin limit reached (7)"
          )
        )
        .accessibilityLabel(
          isPinned
            ? L10n.format("Unpin %@", entry.item.title)
            : L10n.format("Pin %@", entry.item.title)
        )

        Button(L10n.string("Run"), action: run)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(!entry.availability.isAvailable || entry.isRunning)
          .accessibilityLabel(L10n.format("Run %@", entry.item.title))
      }
    }
  }

  /// Muted for anything that cannot run, warning for a missing platform feature, danger
  /// for the actions that destroy something.
  private var iconTint: Color {
    if !entry.availability.isAvailable { return .orange }
    if entry.item.isDestructive { return .red }
    return .secondary
  }

  @ViewBuilder
  private var badges: some View {
    HStack(spacing: 5) {
      if entry.isOn == true {
        SettingsChip(L10n.string("On"), prominent: true)
      }
      if entry.item.isDestructive {
        SettingsChip(
          L10n.string("Destructive · Confirms before running"),
          systemImage: "exclamationmark.triangle",
          tint: .red
        )
      }
      if !entry.availability.isAvailable {
        SettingsChip(
          entry.availability.reason ?? L10n.string("Unavailable"),
          systemImage: "exclamationmark.triangle",
          tint: .orange
        )
      }
      if entry.references.isEmpty {
        SettingsChip(L10n.string("Not used yet"))
      } else {
        ForEach(Array(entry.references.enumerated()), id: \.offset) { _, reference in
          switch reference {
          case .pinned:
            EmptyView()
          case .gestureRule(let name):
            SettingsChip(L10n.format("Gesture: %@", name), systemImage: "hand.tap")
          case .hotkey(let shortcut):
            SettingsChip(shortcut, systemImage: "keyboard")
          }
        }
      }
    }
    .lineLimit(1)
  }
}

private extension ActionSource {
  /// One line of context per section, so a row does not have to repeat where it runs.
  var note: String? {
    switch self {
    case .builtIn: return nil
    case .shortcut:
      return L10n.string("Discovered from Apple Shortcuts on this Mac.")
    case .trackpadNative:
      return L10n.string("These run from a trackpad gesture rule, not from a pinned action.")
    }
  }
}
