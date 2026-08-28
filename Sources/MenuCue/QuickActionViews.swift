import SwiftUI

/// Column layout shared by every quick-action grid inside the popover.
private let popoverActionColumns = Array(
  repeating: GridItem(.flexible(), spacing: 6), count: 4)

/// Grid of just the pinned actions, for embedding under other popover content.
struct PinnedQuickActionGrid: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
  }

  var body: some View {
    let items = service.pinnedItems(for: model.settings.pinnedQuickActions)
    VStack(alignment: .leading, spacing: 7) {
      if items.isEmpty {
        CardPlaceholder(message: L10n.string("Pin actions in Settings to reach them from here."))
      } else {
        LazyVGrid(columns: popoverActionColumns, spacing: 6) {
          ForEach(items) { item in
            QuickActionTile(item: item) {
              service.perform(item.reference)
            }
          }
        }
      }

      if let feedbackMessage = service.feedbackMessage {
        Text(feedbackMessage)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Popover tab for running actions: pinned ones as tiles, everything else as searchable
/// groups. This is the execution surface — a row runs its action, and the Action Center
/// in Settings is where the same actions are arranged.
struct ActionsTabView: View {
  @Environment(\.menuCueMotion) private var motion
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService

  @State private var query = ""
  /// Shortcuts start closed: they are the user's own list and can be long, while the
  /// built-in categories are a fixed short set.
  @State private var collapsedGroups: Set<String> = [ActionSource.shortcut.rawValue]

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        searchRow
        Button { router.openSettings(pane: .actionCenter) } label: {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
        .help("Manage Actions…")
        .accessibilityLabel("Manage Actions…")
      }
      .padding(.horizontal, PopoverMetrics.contentPadding)
      .padding(.top, 4)

      PopoverHapticScrollView {
        VStack(spacing: PopoverMetrics.cardSpacing) {
          if let feedbackMessage = service.feedbackMessage {
            Label(feedbackMessage, systemImage: "info.circle")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(9)
              .background(
                Color.accentColor.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
              )
              .transition(motion.revealTransition(edge: .top))
          }

          if !pinnedItems.isEmpty || !isSearching {
            PopoverCard(title: "Pinned", systemImage: "pin.fill", tint: .accentColor) {
              Text("\(model.settings.pinnedQuickActions.count)/7")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .menuCueNumericTransition(value: model.settings.pinnedQuickActions.count)
            } content: {
              if pinnedItems.isEmpty {
                CardPlaceholder(message: "Nothing pinned yet. Pin actions in Settings.")
              } else {
                LazyVGrid(columns: popoverActionColumns, spacing: 6) {
                  ForEach(pinnedItems) { item in
                    QuickActionTile(item: item) {
                      service.perform(item.reference)
                    }
                  }
                }
              }
            }
          }

          ForEach(groups) { group in
            PopoverActionGroup(
              group: group,
              // A search result that stayed folded away would read as no result at all.
              isExpanded: isSearching || !collapsedGroups.contains(group.id),
              onToggleExpanded: { toggle(group) },
              run: { item in service.perform(item.reference) }
            )
          }

          if groups.isEmpty, isSearching {
            CardPlaceholder(message: "No action matches this search.")
              .padding(.vertical, 6)
          }

          Button { router.openSettings(pane: .actionCenter) } label: {
            Label("Manage Actions…", systemImage: "slider.horizontal.3")
              .font(.system(size: 11, weight: .medium))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 7)
              .contentShape(Rectangle())
          }
          .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
          .foregroundStyle(.secondary)
          .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .continuous)
          )
        }
        .animation(motion.stateAnimation, value: model.settings.pinnedQuickActions)
        .animation(motion.stateAnimation, value: service.feedbackMessage)
      }
    }
    .onAppear {
      service.refreshAll()
    }
  }

  private var searchRow: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
      TextField(L10n.string("Search actions"), text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .menuCueFocusEffectDisabled()
      if isSearching {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
  }

  private var isSearching: Bool {
    !query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private var pinnedItems: [QuickActionItem] {
    matching(service.pinnedItems(for: model.settings.pinnedQuickActions))
  }

  /// Everything that is not pinned, split into the built-in categories and one group for
  /// the user's Shortcuts. Empty groups are dropped so a search shows only what it found.
  private var groups: [PopoverActionGroupModel] {
    let pinned = Set(model.settings.pinnedQuickActions)
    let items = matching(service.catalogItems.filter { !pinned.contains($0.reference) })

    var groups: [PopoverActionGroupModel] = BuiltInQuickActionCategory.allCases.map { category in
      PopoverActionGroupModel(
        id: category.rawValue,
        title: category.title,
        systemImage: category.systemImage,
        items: items.filter { item in
          guard case .builtIn(let actionID) = item.reference else { return false }
          return actionID.category == category
        }
      )
    }
    groups.append(
      PopoverActionGroupModel(
        id: ActionSource.shortcut.rawValue,
        title: ActionSource.shortcut.title,
        systemImage: "command.square.fill",
        items: items.filter { item in
          if case .shortcut = item.reference { return true }
          return false
        }
      )
    )
    return groups.filter { !$0.items.isEmpty }
  }

  private func matching(_ items: [QuickActionItem]) -> [QuickActionItem] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return items }
    return items.filter { $0.title.localizedCaseInsensitiveContains(needle) }
  }

  private func toggle(_ group: PopoverActionGroupModel) {
    withAnimation(motion.stateAnimation) {
      if collapsedGroups.contains(group.id) {
        collapsedGroups.remove(group.id)
      } else {
        collapsedGroups.insert(group.id)
      }
    }
  }
}

private struct PopoverActionGroupModel: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let items: [QuickActionItem]
}

/// One collapsible run of actions, styled as a popover card whose header is the toggle.
private struct PopoverActionGroup: View {
  let group: PopoverActionGroupModel
  let isExpanded: Bool
  let onToggleExpanded: () -> Void
  let run: (QuickActionItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: isExpanded ? 6 : 0) {
      Button(action: onToggleExpanded) {
        HStack(spacing: 6) {
          Image(systemName: group.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
          Text(group.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .kerning(0.4)
          Spacer(minLength: 4)
          Text("\(group.items.count)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(group.title)
      .accessibilityHint(isExpanded ? "Collapse group" : "Expand group")

      if isExpanded {
        VStack(spacing: 1) {
          ForEach(group.items) { item in
            PopoverActionRow(item: item) { run(item) }
          }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .continuous)
    )
  }
}

/// A one-line action in the popover. The row itself runs the action; unavailable ones stay
/// tappable so the tap can explain why and open the setting that fixes it.
private struct PopoverActionRow: View {
  @Environment(\.menuCueMotion) private var motion
  let item: QuickActionItem
  let action: () -> Void

  @State private var confirmsDestructiveAction = false
  @State private var isHovering = false

  private var isOn: Bool { item.state.isOn == true }
  private var isAvailable: Bool { item.state.availability.isAvailable }

  var body: some View {
    Button {
      if item.isDestructive {
        confirmsDestructiveAction = true
      } else {
        action()
      }
    } label: {
      HStack(spacing: 8) {
        ZStack {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isOn ? Color.accentColor : Color.primary.opacity(0.06))
            .frame(width: 24, height: 24)
          Image(systemName: item.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(iconForeground)
            .menuCueSymbolBounce(value: isOn)
        }

        Text(item.title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isAvailable ? .primary : .secondary)
          .lineLimit(1)

        Spacer(minLength: 6)

        if item.state.isRunning {
          MotionAwareProgressIndicator(scale: 0.6)
        } else if !isAvailable {
          ActionUnavailableBadge(reason: item.state.availability.reason)
        } else if isOn {
          Text("On")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .background(
        Color.primary.opacity(isHovering ? 0.06 : 0),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableButtonStyle(pressedScale: 0.99))
    .onHover { hovering in
      withAnimation(motion.hoverAnimation) { isHovering = hovering }
    }
    .help(item.state.availability.reason ?? item.title)
    .accessibilityLabel(item.title)
    .accessibilityValue(item.state.accessibilityValue(kind: item.kind))
    .confirmationDialog(
      "Empty Trash?",
      isPresented: $confirmsDestructiveAction,
      titleVisibility: .visible
    ) {
      Button("Empty Trash", role: .destructive, action: action)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently removes every item in your user Trash.")
    }
  }

  private var iconForeground: Color {
    if isOn { return .white }
    return isAvailable ? .primary : .secondary
  }
}

/// The shared "cannot run right now" mark: the reason is the tooltip, so the badge stays
/// small enough to sit at the end of a row. When the failure is one the user can fix, the
/// badge is the button that opens the setting that fixes it.
struct ActionUnavailableBadge: View {
  let reason: String?
  var settingsURL: URL?

  var body: some View {
    if let settingsURL {
      Button {
        WorkspaceOpener.openSettings(settingsURL)
      } label: {
        mark
      }
      .buttonStyle(.plain)
      .help(helpText)
      .accessibilityLabel(L10n.string("Open System Settings"))
      .accessibilityValue(helpText)
    } else {
      mark
        .help(helpText)
        .accessibilityLabel(helpText)
    }
  }

  private var mark: some View {
    Image(systemName: "exclamationmark.triangle.fill")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.orange)
  }

  private var helpText: String {
    guard let reason else { return L10n.string("This action is unavailable.") }
    return L10n.format("Unavailable. %@", reason)
  }
}

extension QuickActionState {
  func accessibilityValue(kind: QuickActionKind) -> String {
    if let reason = availability.reason {
      return L10n.format("Unavailable. %@", reason)
    }
    if isRunning {
      return L10n.string("Running")
    }
    if let isOn {
      return L10n.string(isOn ? "On" : "Off")
    }
    return L10n.string(kind == .button ? "Button" : "Action")
  }
}

/// A Control Center style tile: the whole rounded rect is the control surface,
/// and an active toggle fills it with the accent color rather than tinting a puck.
private struct QuickActionTile: View {
  @Environment(\.menuCueMotion) private var motion
  let item: QuickActionItem
  let action: () -> Void

  @State private var confirmsDestructiveAction = false
  @State private var isHovering = false

  private var isOn: Bool { item.state.isOn == true }
  private var isAvailable: Bool { item.state.availability.isAvailable }

  var body: some View {
    Button {
      if item.isDestructive {
        confirmsDestructiveAction = true
      } else {
        action()
      }
    } label: {
      VStack(spacing: 5) {
        ZStack {
          if item.state.isRunning {
            MotionAwareProgressIndicator(scale: 0.7)
          } else {
            Image(systemName: item.systemImage)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(iconForeground)
              .menuCueSymbolBounce(value: isOn)
          }
        }
        .frame(height: 17)

        Text(item.title)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(labelForeground)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.8)
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, minHeight: 60)
      .background(tileFill, in: tileShape)
      .overlay(tileShape.strokeBorder(tileStroke, lineWidth: 1))
      .contentShape(tileShape)
    }
    .buttonStyle(PressableButtonStyle())
    .opacity(isAvailable ? 1 : 0.55)
    .onHover { hovering in
      guard isAvailable else { return }
      withAnimation(motion.hoverAnimation) { isHovering = hovering }
    }
    .animation(motion.stateAnimation, value: item.state)
    .help(item.state.availability.reason ?? item.title)
    .accessibilityLabel(item.title)
    .accessibilityValue(item.state.accessibilityValue(kind: item.kind))
    .confirmationDialog(
      "Empty Trash?",
      isPresented: $confirmsDestructiveAction,
      titleVisibility: .visible
    ) {
      Button("Empty Trash", role: .destructive, action: action)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently removes every item in your user Trash.")
    }
  }

  private var tileShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 11, style: .continuous)
  }

  private var tileFill: Color {
    guard isAvailable else { return Color.primary.opacity(0.03) }
    if isOn { return Color.accentColor }
    return Color.primary.opacity(isHovering ? 0.10 : 0.05)
  }

  private var tileStroke: Color {
    guard isAvailable, !isOn else { return .clear }
    return Color.primary.opacity(isHovering ? 0.12 : 0.06)
  }

  private var iconForeground: Color {
    if isOn { return .white }
    return isAvailable ? .primary : .secondary
  }

  private var labelForeground: Color {
    if isOn { return .white }
    return isAvailable ? .primary.opacity(0.85) : .secondary
  }
}
