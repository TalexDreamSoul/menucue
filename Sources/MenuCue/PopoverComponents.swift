import SwiftUI

/// Shared visual language for the popover: every panel is a rounded card on a neutral fill.
enum PopoverMetrics {
  static let width: CGFloat = 360
  static let height: CGFloat = 620
  static let contentPadding: CGFloat = 14
  static let cardSpacing: CGFloat = 10
  static let cardCornerRadius: CGFloat = 13
}

/// Plain button that dips slightly while held. Used for every tappable tile so
/// press feedback is consistent and doesn't rely on a background color change.
struct PressableButtonStyle: ButtonStyle {
  @Environment(\.menuCueMotion) private var motion
  var pressedScale: CGFloat = 0.95
  var pressedOpacity: Double = 0.9

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? pressedScale : 1)
      .opacity(configuration.isPressed ? pressedOpacity : 1)
      .animation(motion.pressAnimation, value: configuration.isPressed)
  }
}

/// A titled panel. `accessory` sits opposite the title and is usually a value or a control.
struct PopoverCard<Content: View, Accessory: View>: View {
  @Environment(\.menuCueMotion) private var motion
  let title: String
  let systemImage: String
  let tint: Color
  /// Set on cards that share a row so neighbours of unequal content match height.
  let fillsHeight: Bool
  @ViewBuilder let accessory: Accessory
  @ViewBuilder let content: Content
  @State private var isHovering = false

  init(
    title: String,
    systemImage: String,
    tint: Color = .accentColor,
    fillsHeight: Bool = false,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.fillsHeight = fillsHeight
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
          .scaleEffect(isHovering ? 1.12 : 1)
        Text(L10n.string(title))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(isHovering ? .secondary : .tertiary)
          .textCase(.uppercase)
          .kerning(0.4)
        Spacer(minLength: 4)
        accessory
      }
      content
    }
    .padding(10)
    // Inside a GridRow, `.infinity` resolves to the row height — the tallest sibling —
    // rather than to all remaining space, which is what makes neighbours match.
    .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
    .background(Color.primary.opacity(isHovering ? 0.065 : 0.045))
    .clipShape(RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .continuous)
        .stroke(tint.opacity(isHovering ? 0.28 : 0), lineWidth: 1)
    )
    .overlay(
      RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .continuous)
        .stroke(Color.primary.opacity(isHovering ? 0 : 0.06), lineWidth: 1)
    )
    .onHover { hovering in
      withAnimation(motion.hoverAnimation) { isHovering = hovering }
    }
  }
}

/// A horizontal capacity bar. `fraction` is clamped, so callers can pass raw ratios.
struct MetricBar: View {
  @Environment(\.menuCueMotion) private var motion
  let fraction: Double
  var tint: Color = .accentColor
  var height: CGFloat = 6

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.primary.opacity(0.10))
        Capsule()
          .fill(tint.gradient)
          .frame(width: max(0, min(1, fraction)) * proxy.size.width)
      }
    }
    .frame(height: height)
    .animation(motion.barAnimation, value: fraction)
  }
}

/// A label above a value, used for the paired readouts inside metric cards.
struct MetricReadout: View {
  let label: String
  let value: String
  var valueColor: Color = .primary
  var alignment: HorizontalAlignment = .leading

  var body: some View {
    VStack(alignment: alignment, spacing: 1) {
      Text(L10n.string(label))
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(valueColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .menuCueNumericTransition(value: value)
    }
    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
  }
}

/// A colored dot with a name and value, used for the CPU chart legend.
struct LegendItem: View {
  let color: Color
  let label: String
  let value: String

  var body: some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(color)
        .frame(width: 7, height: 7)
      Text(L10n.string(label))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .menuCueNumericTransition(value: value)
    }
  }
}

/// Placeholder shown when a card has nothing to display yet.
struct CardPlaceholder: View {
  let message: String

  var body: some View {
    Text(L10n.string(message))
      .font(.system(size: 11))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Segmented switcher across the top of the popover.
struct PopoverTabBar: View {
  @Environment(\.menuCueMotion) private var motion
  let tabs: [PopoverTab]
  @Binding var selection: PopoverTab
  @Namespace private var highlight
  @State private var hoveredTab: PopoverTab?

  var body: some View {
    HStack(spacing: 2) {
      ForEach(tabs) { tab in
        Button {
          guard selection != tab else { return }
          withAnimation(motion.navigationAnimation) { selection = tab }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: tab.systemImage)
              .font(.system(size: 11, weight: .semibold))
              // Nudges the glyph when its tab becomes active.
              .menuCueSymbolBounce(value: selection == tab)
            Text(tab.title)
              .font(.system(size: 12, weight: .semibold))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
          .background {
            if selection == tab {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                .menuCueMatchedGeometryEffect(id: "selected-tab", in: highlight)
            } else if hoveredTab == tab {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tabForeground(for: tab))
        .onHover { isHovering in
          withAnimation(motion.hoverAnimation) {
            hoveredTab = isHovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
          }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? [.isSelected, .isButton] : .isButton)
      }
    }
    .padding(3)
    .background(
      Color.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 11, style: .continuous)
    )
    // SwiftUI parks initial focus on the first button, and its ring reads as a
    // second selected tab. Selection is already shown by the filled pill.
    .menuCueFocusEffectDisabled()
  }

  private func tabForeground(for tab: PopoverTab) -> Color {
    if selection == tab { return .primary }
    return hoveredTab == tab ? .primary.opacity(0.75) : .secondary
  }
}

/// Persistent footer: uptime on the left, an overflow menu on the right.
struct PopoverFooter: View {
  let bootDate: Date?
  let openSettings: () -> Void
  let openQuickActionSettings: () -> Void
  let newEvent: () -> Void
  let quitApp: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "power")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
      Text("Uptime")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)

      // A minute is the finest resolution the label shows, so refresh no faster.
      TimelineView(.periodic(from: Date(), by: 60)) { context in
        Text(uptimeText(at: context.date))
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .menuCueNumericTransition(value: uptimeText(at: context.date))
      }

      Spacer(minLength: 8)

      Menu {
        Button("New Event…", action: newEvent)
        Button("Manage Actions…", action: openQuickActionSettings)
        Divider()
        Button("Settings…", action: openSettings)
        Divider()
        Button("Quit MenuCue", action: quitApp)
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 18)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("More options")

      Button(action: openSettings) {
        Image(systemName: "gearshape")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Settings")
      .accessibilityLabel("Settings")
    }
  }

  private func uptimeText(at date: Date) -> String {
    guard let bootDate else { return "—" }
    return SystemMetricsFormatter.uptime(date.timeIntervalSince(bootDate))
  }
}
