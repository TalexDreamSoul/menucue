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
            QuickActionTile(item: item, style: .compact) {
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

/// Popover tab listing every quick action: pinned ones first, then the rest of the catalog.
struct ActionsTabView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService
  let openSettings: () -> Void

  init(model: AppModel, openSettings: @escaping () -> Void) {
    self.model = model
    self.openSettings = openSettings
    self.service = model.quickActionService
  }

  var body: some View {
    ScrollView {
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
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        PopoverCard(title: "Pinned", systemImage: "pin.fill", tint: .accentColor) {
          Text("\(model.settings.pinnedQuickActions.count)/7")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .contentTransition(.numericText())
        } content: {
          if pinnedItems.isEmpty {
            CardPlaceholder(message: "Nothing pinned yet. Pin actions in Settings.")
          } else {
            LazyVGrid(columns: popoverActionColumns, spacing: 6) {
              ForEach(pinnedItems) { item in
                QuickActionTile(item: item, style: .compact) {
                  service.perform(item.reference)
                }
              }
            }
          }
        }

        PopoverCard(title: "More Actions", systemImage: "square.grid.2x2", tint: .secondary) {
          if unpinnedItems.isEmpty {
            CardPlaceholder(message: "Every available action is pinned.")
          } else {
            LazyVGrid(columns: popoverActionColumns, spacing: 6) {
              ForEach(unpinnedItems) { item in
                QuickActionTile(item: item, style: .compact) {
                  service.perform(item.reference)
                }
              }
            }
          }
        }

        Button(action: openSettings) {
          Label("Manage in Settings", systemImage: "slider.horizontal.3")
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
      .padding(.horizontal, PopoverMetrics.contentPadding)
      .padding(.vertical, 2)
      .animation(PopoverMotion.state, value: model.settings.pinnedQuickActions)
      .animation(PopoverMotion.state, value: service.feedbackMessage)
    }
    .onAppear {
      service.refreshAll()
    }
  }

  private var pinnedItems: [QuickActionItem] {
    service.pinnedItems(for: model.settings.pinnedQuickActions)
  }

  private var unpinnedItems: [QuickActionItem] {
    let pinned = Set(model.settings.pinnedQuickActions)
    return service.catalogItems.filter { !pinned.contains($0.reference) }
  }
}

/// Quick Actions settings pane. This is also where the full catalog is run from —
/// there is no separate Quick Actions window, so managing and running live together.
struct QuickActionSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService
  @ObservedObject private var powerHelper: PowerHelperManager
  @State private var helperFeedback: String?

  private let catalogColumns = [
    GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10)
  ]

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
    self.powerHelper = model.quickActionService.powerHelperManager
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if powerHelper.registrationState.needsProminentRemediation {
        powerHelperSection(isProminent: true)
      }

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
            .contentTransition(.numericText())
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
            .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
      }
      .animation(PopoverMotion.state, value: model.settings.pinnedQuickActions)

      SettingsGroup(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.string("All actions"))
            .font(.headline)
          Text(
            L10n.string(
              "Click a tile to run it now. Use the pin button to show it in the menu-bar popover."
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

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
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        LazyVGrid(columns: catalogColumns, alignment: .leading, spacing: 10) {
          ForEach(service.catalogItems) { item in
            QuickActionTile(item: item, style: .catalog) {
              service.perform(item.reference)
            }
            .overlay(alignment: .topTrailing) {
              pinToggle(for: item)
                .padding(5)
            }
          }
        }
        .animation(PopoverMotion.state, value: service.feedbackMessage)
      }

      if !powerHelper.registrationState.needsProminentRemediation {
        powerHelperSection(isProminent: false)
      }
    }
    .onAppear {
      service.refreshAll()
    }
  }

  private func powerHelperSection(isProminent: Bool) -> some View {
    SettingsGroup(spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: powerHelper.registrationState.isEnabled
            ? "checkmark.shield.fill"
            : isProminent ? "exclamationmark.shield.fill" : "shield.lefthalf.filled"
        )
        .font(.title3)
        .foregroundStyle(powerHelper.registrationState.isEnabled ? Color.green : Color.orange)
        .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text("Power Helper")
              .font(.headline)
            Spacer()
            Text(powerHelper.registrationState.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(powerHelper.registrationState.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            "Low Power Mode applies to battery and adapter power. Don't Sleep When Closed can increase heat and battery use."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let helperFeedback {
        Text(helperFeedback)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .transition(.opacity)
      }

      HStack {
        Spacer()
        helperActionButton
      }
    }
    .padding(isProminent ? 14 : 0)
    .background(
      isProminent ? Color.orange.opacity(0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isProminent ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1)
    }
    .animation(PopoverMotion.state, value: powerHelper.registrationState)
  }

  /// Pin/unpin control layered on a catalog tile. Kept outside the tile's own
  /// Button label so the two hit areas stay independent.
  @ViewBuilder
  private func pinToggle(for item: QuickActionItem) -> some View {
    let isPinned = model.settings.pinnedQuickActions.contains(item.reference)
    let isFull = model.settings.pinnedQuickActions.count >= 7

    Button {
      if isPinned {
        model.removePinnedQuickAction(item.reference)
      } else {
        model.addPinnedQuickAction(item.reference)
      }
    } label: {
      Image(systemName: isPinned ? "pin.fill" : "pin")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
        .frame(width: 18, height: 18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9), in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
    .disabled(!isPinned && (isFull || !item.state.availability.isAvailable))
    .help(
      L10n.string(
        isPinned ? "Unpin from popover" : isFull ? "Pin limit reached (7)" : "Pin to popover"
      )
    )
    .accessibilityLabel(
      isPinned
        ? L10n.format("Unpin %@", item.title)
        : L10n.format("Pin %@", item.title)
    )
  }

  @ViewBuilder
  private var helperActionButton: some View {
    switch powerHelper.registrationState {
    case .enabled:
      Button("Remove Helper", role: .destructive, action: removePowerHelper)
        .disabled(powerHelper.isWorking)
    case .requiresApproval:
      Button("Open System Settings") {
        powerHelper.openSystemSettings()
      }
      .buttonStyle(.borderedProminent)
      Button("Cancel Install", role: .destructive, action: removePowerHelper)
        .disabled(powerHelper.isWorking)
    case .refreshRequired:
      Button("Refresh Helper") {
        helperFeedback = nil
        powerHelper.refreshHelperRegistration()
      }
      .buttonStyle(.borderedProminent)
      .disabled(powerHelper.isWorking)
    case .unavailable:
      Button("Install Helper") {}
        .buttonStyle(.borderedProminent)
        .disabled(true)
    case .notRegistered, .failed:
      Button("Install Helper") {
        helperFeedback = nil
        powerHelper.requestRegistration()
      }
      .buttonStyle(.borderedProminent)
      .disabled(powerHelper.isWorking)
    }
  }

  private func removePowerHelper() {
    powerHelper.removeHelper { result in
      switch result {
      case .success:
        helperFeedback = L10n.string("Power Helper removed.")
      case .failure(let error):
        helperFeedback = L10n.format(
          "Could not remove Power Helper: %@",
          error.localizedDescription
        )
      }
      service.refreshAll()
    }
  }
}

private enum QuickActionTileStyle {
  /// Menu-bar popover: four to a row, so the label carries the meaning and the
  /// glyph is only a landmark.
  case compact
  /// Settings pane: room for the availability reason under the label.
  case catalog

  var height: CGFloat {
    switch self {
    case .compact: return 60
    case .catalog: return 86
    }
  }

  var cornerRadius: CGFloat {
    switch self {
    case .compact: return 11
    case .catalog: return 12
    }
  }

  var iconSize: CGFloat {
    switch self {
    case .compact: return 13
    case .catalog: return 16
    }
  }

  var labelSize: CGFloat {
    switch self {
    case .compact: return 10
    case .catalog: return 11
    }
  }

  var verticalPadding: CGFloat {
    switch self {
    case .compact: return 7
    case .catalog: return 10
    }
  }
}

/// A Control Center style tile: the whole rounded rect is the control surface,
/// and an active toggle fills it with the accent color rather than tinting a puck.
private struct QuickActionTile: View {
  let item: QuickActionItem
  let style: QuickActionTileStyle
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
      VStack(spacing: style == .compact ? 5 : 6) {
        ZStack {
          if item.state.isRunning {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.7)
          } else {
            Image(systemName: item.systemImage)
              .font(.system(size: style.iconSize, weight: .semibold))
              .foregroundStyle(iconForeground)
              .symbolEffect(.bounce, value: isOn)
          }
        }
        .frame(height: style.iconSize + 4)

        Text(item.title)
          .font(.system(size: style.labelSize, weight: .medium))
          .foregroundStyle(labelForeground)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.8)

        if style == .catalog, let reason = item.state.availability.reason {
          Text(reason)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, style.verticalPadding)
      .frame(maxWidth: .infinity, minHeight: style.height)
      .background(tileFill, in: tileShape)
      .overlay(tileShape.strokeBorder(tileStroke, lineWidth: 1))
      .contentShape(tileShape)
    }
    .buttonStyle(PressableButtonStyle())
    .opacity(isAvailable ? 1 : 0.55)
    .onHover { hovering in
      guard isAvailable else { return }
      withAnimation(PopoverMotion.hover) { isHovering = hovering }
    }
    .animation(PopoverMotion.state, value: item.state)
    .help(item.state.availability.reason ?? item.title)
    .accessibilityLabel(item.title)
    .accessibilityValue(accessibilityValue)
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
    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
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

  private var accessibilityValue: String {
    if let reason = item.state.availability.reason {
      return L10n.format("Unavailable. %@", reason)
    }
    if item.state.isRunning {
      return L10n.string("Running")
    }
    if let isOn = item.state.isOn {
      return L10n.string(isOn ? "On" : "Off")
    }
    return L10n.string(item.kind == .button ? "Button" : "Action")
  }
}
