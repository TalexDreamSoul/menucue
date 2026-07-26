import SwiftUI

/// Grid of just the pinned actions, for embedding under other popover content.
struct PinnedQuickActionGrid: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

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
        LazyVGrid(columns: columns, spacing: 6) {
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
  let openMore: () -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

  init(model: AppModel, openSettings: @escaping () -> Void, openMore: @escaping () -> Void) {
    self.model = model
    self.openSettings = openSettings
    self.openMore = openMore
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
            .transition(.opacity)
        }

        PopoverCard(title: "Pinned", systemImage: "pin.fill", tint: .accentColor) {
          Text("\(model.settings.pinnedQuickActions.count)/7")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
        } content: {
          if pinnedItems.isEmpty {
            CardPlaceholder(message: "Nothing pinned yet. Pin actions in Settings.")
          } else {
            LazyVGrid(columns: columns, spacing: 6) {
              ForEach(pinnedItems) { item in
                QuickActionTile(item: item, style: .compact) {
                  service.perform(item.reference)
                }
              }
            }
          }
        }

        PopoverCard(title: "More Actions", systemImage: "square.grid.2x2", tint: .secondary) {
          Button("Manage", action: openSettings)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        } content: {
          if unpinnedItems.isEmpty {
            CardPlaceholder(message: "Every available action is pinned.")
          } else {
            LazyVGrid(columns: columns, spacing: 6) {
              ForEach(unpinnedItems) { item in
                QuickActionTile(item: item, style: .compact) {
                  service.perform(item.reference)
                }
              }
            }
          }
        }

        Button(action: openMore) {
          Label("Open Quick Actions Window", systemImage: "macwindow")
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
          Color.primary.opacity(0.045),
          in: RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .continuous)
        )
      }
      .padding(.horizontal, PopoverMetrics.contentPadding)
      .padding(.vertical, 2)
    }
    .scrollBounceBehavior(.basedOnSize)
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

struct QuickActionsWindowView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService
  let openSettings: () -> Void

  private let columns = [
    GridItem(.adaptive(minimum: 118, maximum: 142), spacing: 14)
  ]

  init(model: AppModel, openSettings: @escaping () -> Void) {
    self.model = model
    self.openSettings = openSettings
    self.service = model.quickActionService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Quick Actions")
            .font(.title2.weight(.semibold))
          Text("Run built-in actions and Apple Shortcuts without pinning them.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Manage") {
          openSettings()
        }
      }

      if let feedbackMessage = service.feedbackMessage {
        Label(feedbackMessage, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.secondary.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }

      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
          ForEach(service.catalogItems) { item in
            QuickActionTile(item: item, style: .catalog) {
              service.perform(item.reference)
            }
          }
        }
        .padding(.vertical, 2)
      }
    }
    .padding(22)
    .frame(minWidth: 620, minHeight: 520, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      service.refreshAll()
    }
  }
}

struct QuickActionSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService
  @ObservedObject private var powerHelper: PowerHelperManager
  @State private var helperFeedback: String?

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
    self.powerHelper = model.quickActionService.powerHelperManager
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
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
          }
        }
      }

      SettingsGroup(spacing: 12) {
        HStack(alignment: .top, spacing: 10) {
          Image(
            systemName: powerHelper.registrationState.isEnabled
              ? "checkmark.shield.fill" : "shield.lefthalf.filled"
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
            Text(
              "Low Power Mode applies to battery and adapter power. Don't Sleep When Closed can increase heat and battery use."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
        }

        if let helperFeedback {
          Text(helperFeedback)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        HStack {
          Spacer()
          helperActionButton
        }
      }

      SettingsGroup(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Available actions")
            .font(.headline)
          Text("Built-in actions and Apple Shortcuts can be added once and reordered above.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        ForEach(availableItems) { item in
          HStack(spacing: 10) {
            Image(systemName: item.systemImage)
              .frame(width: 22)
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
            Button("Add") {
              model.addPinnedQuickAction(item.reference)
            }
            .disabled(
              model.settings.pinnedQuickActions.count >= 7
                || !item.state.availability.isAvailable
            )
          }
          .padding(.vertical, 3)
        }
      }
    }
    .onAppear {
      service.refreshAll()
    }
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
      Button("Cancel Install", role: .destructive, action: removePowerHelper)
        .disabled(powerHelper.isWorking)
    case .refreshRequired:
      Button("Refresh Helper") {
        helperFeedback = nil
        powerHelper.refreshHelperRegistration()
      }
      .disabled(powerHelper.isWorking)
    case .unavailable:
      Button("Install Helper") {}
        .disabled(true)
    case .notRegistered, .failed:
      Button("Install Helper") {
        helperFeedback = nil
        powerHelper.requestRegistration()
      }
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

  private var availableItems: [QuickActionItem] {
    let pinned = Set(model.settings.pinnedQuickActions)
    return service.catalogItems.filter { !pinned.contains($0.reference) }
  }
}

private enum QuickActionTileStyle {
  case compact
  case catalog

  var height: CGFloat {
    switch self {
    case .compact: return 60
    case .catalog: return 126
    }
  }

  var iconSize: CGFloat {
    switch self {
    case .compact: return 24
    case .catalog: return 34
    }
  }
}

private struct QuickActionTile: View {
  let item: QuickActionItem
  let style: QuickActionTileStyle
  let action: () -> Void

  @State private var confirmsDestructiveAction = false

  var body: some View {
    Button {
      if item.isDestructive {
        confirmsDestructiveAction = true
      } else {
        action()
      }
    } label: {
      VStack(spacing: style == .compact ? 3 : 8) {
        ZStack {
          Circle()
            .fill(iconBackground)
          if item.state.isRunning {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: item.systemImage)
              .font(.system(size: style.iconSize, weight: .medium))
              .foregroundStyle(iconForeground)
          }
        }
        .frame(width: style == .compact ? 34 : 54, height: style == .compact ? 34 : 54)

        Text(item.title)
          .font(style == .compact ? .caption2 : .caption)
          .fontWeight(.medium)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.72)

        if style == .catalog,
          let reason = item.state.availability.reason
        {
          Text(reason)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, minHeight: style.height, alignment: .top)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(item.state.availability.isAvailable ? 1 : 0.62)
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

  private var iconBackground: Color {
    guard item.state.availability.isAvailable else { return Color.secondary.opacity(0.12) }
    if item.state.isOn == true {
      return Color.accentColor
    }
    return Color.secondary.opacity(0.13)
  }

  private var iconForeground: Color {
    item.state.isOn == true ? .white : .primary
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
