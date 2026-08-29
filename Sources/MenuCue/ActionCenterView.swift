import SwiftUI

/// Action Center settings pane: the whole register of what MenuCue can do, split by where
/// each entry comes from, with what already depends on it.
///
/// Nothing runs from a row tap here. Arranging actions and running them are different
/// jobs, and one of these actions empties the Trash — the popover is the execution
/// surface, and this pane's Run button is the only way to fire an action from Settings.
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
    VStack(alignment: .leading, spacing: 20) {
      pinnedGroup
      catalogGroup
    }
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

  private var pinnedGroup: some View {
    SettingsGroup(spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Pinned actions")
            .font(.headline)
          Text("The menu-bar popover shows these actions before the fixed More button.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(L10n.format("%d / 7", model.settings.pinnedQuickActions.count))
          .font(.subheadline.weight(.semibold))
          .menuCueNumericTransition(value: model.settings.pinnedQuickActions.count)
          .foregroundStyle(
            model.settings.pinnedQuickActions.count == 7 ? Color.orange : Color.secondary)
      }

      if model.settings.pinnedQuickActions.isEmpty {
        Text("No actions are pinned. The popover will show only More.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        ForEach(Array(model.settings.pinnedQuickActions.enumerated()), id: \.element.id) {
          index, reference in
          let item = service.item(for: reference)
          HStack(spacing: 10) {
            Image(systemName: item.systemImage)
              .frame(width: 22)
              .foregroundStyle(
                item.state.availability.isAvailable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title)
              if let reason = item.state.availability.reason {
                Text(reason)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            Spacer()
            Button {
              model.movePinnedQuickAction(at: index, by: -1)
            } label: {
              Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")

            Button {
              model.movePinnedQuickAction(at: index, by: 1)
            } label: {
              Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == model.settings.pinnedQuickActions.count - 1)
            .help("Move down")

            Button(role: .destructive) {
              model.removePinnedQuickAction(reference)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
          }
          .padding(.vertical, 4)
          .transition(motion.revealTransition(edge: .top))
        }
      }
    }
    .animation(motion.stateAnimation, value: model.settings.pinnedQuickActions)
  }

  private var catalogGroup: some View {
    // Resolved once for the whole pane: each section filters this list rather than
    // re-reading system state for every row it draws.
    let entries = self.entries
    return SettingsGroup(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string("All actions"))
          .font(.headline)
        Text(
          L10n.string(
            "Run an action with its Run button. Pin it to reach it from the menu-bar popover."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Picker("Source", selection: $selectedSource) {
        Text("All").tag(ActionSource?.none)
        ForEach(ActionSource.allCases) { source in
          Text(source.title).tag(ActionSource?.some(source))
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if let feedbackMessage = service.feedbackMessage {
        Label(feedbackMessage, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
          .transition(motion.revealTransition(edge: .top))
      }

      ForEach(visibleSources) { source in
        VStack(alignment: .leading, spacing: 4) {
          Text(source.title)
            .font(.subheadline.weight(.semibold))
          if let note = source.note {
            Text(note)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          let sourceEntries = entries.filter { $0.item.source == source }
          if sourceEntries.isEmpty {
            Text("No actions are registered here yet.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.vertical, 6)
          } else {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(sourceEntries.enumerated()), id: \.element.id) { index, entry in
                ActionCenterRow(
                  entry: entry,
                  isPinned: isPinned(entry),
                  canPin: canPin(entry),
                  run: { run(entry) },
                  togglePin: { togglePin(entry) }
                )
                if index < sourceEntries.count - 1 {
                  Divider()
                }
              }
            }
          }
        }
        .padding(.top, 4)
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

/// One action, with everything that already depends on it and no way to fire it by
/// accident: the row is not a control, and Run is a button of its own.
private struct ActionCenterRow: View {
  let entry: ActionCenterEntry
  let isPinned: Bool
  let canPin: Bool
  let run: () -> Void
  let togglePin: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(entry.isOn == true ? Color.accentColor : Color.primary.opacity(0.06))
          .frame(width: 26, height: 26)
        Image(systemName: entry.item.systemImage)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(iconForeground)
      }

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(entry.item.title)
            .font(.body)
            .foregroundStyle(entry.availability.isAvailable ? .primary : .secondary)
            .lineLimit(1)
          if entry.isOn == true {
            Text("On")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(Color.accentColor)
          }
        }
        referenceBadges
      }

      Spacer(minLength: 8)

      if entry.isRunning {
        MotionAwareProgressIndicator(scale: 0.7)
      } else if !entry.availability.isAvailable {
        ActionUnavailableBadge(reason: entry.availability.reason)
        if let settingsURL = entry.availability.settingsURL {
          Button("Open System Settings") {
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

        Button("Run", action: run)
          .disabled(!entry.availability.isAvailable || entry.isRunning)
          .accessibilityLabel(L10n.format("Run %@", entry.item.title))
      }
    }
    .padding(.vertical, 7)
  }

  private var iconForeground: Color {
    if entry.isOn == true { return .white }
    return entry.availability.isAvailable ? .primary : .secondary
  }

  @ViewBuilder
  private var referenceBadges: some View {
    if entry.references.isEmpty {
      Text("Not used yet")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    } else {
      HStack(spacing: 5) {
        ForEach(Array(entry.references.enumerated()), id: \.offset) { _, reference in
          switch reference {
          case .pinned:
            ActionReferenceBadge(title: L10n.string("Pinned"), systemImage: "pin.fill")
          case .gestureRule(let name):
            ActionReferenceBadge(title: name, systemImage: "hand.tap")
          case .hotkey(let shortcut):
            ActionReferenceBadge(title: shortcut, systemImage: "keyboard")
          }
        }
      }
    }
  }
}

private struct ActionReferenceBadge: View {
  let title: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: systemImage)
        .font(.system(size: 8, weight: .semibold))
      Text(title)
        .font(.caption2)
        .lineLimit(1)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      Color.primary.opacity(0.06),
      in: Capsule()
    )
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

