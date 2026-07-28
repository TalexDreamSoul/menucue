import SwiftUI

/// Window-scale sibling of `PopoverMetrics`. The popover vocabulary is tuned for a
/// 360pt column and 9–11pt type; reused verbatim in a 700pt window it reads as
/// undersized. Tints, corner radii, and motion stay shared.
enum DashboardMetrics {
  static let cardSpacing: CGFloat = 12
  static let contentPadding: CGFloat = 20
  static let cardCornerRadius: CGFloat = 12
  static let chartHeight: CGFloat = 120
}

/// A titled panel in the Dashboard. `accessory` sits opposite the title.
struct DashboardCard<Content: View, Accessory: View>: View {
  let title: String
  let systemImage: String
  var tint: Color = .accentColor
  @ViewBuilder let accessory: Accessory
  @ViewBuilder let content: Content

  init(
    title: String,
    systemImage: String,
    tint: Color = .accentColor,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(tint)
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .kerning(0.4)
        Spacer(minLength: 6)
        accessory
      }
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: DashboardMetrics.cardCornerRadius, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DashboardMetrics.cardCornerRadius, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }
}

/// A large headline figure with a caption, for the top of a tab.
struct StatTile: View {
  let title: String
  let value: String
  var detail: String?
  var tint: Color = .accentColor

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .kerning(0.4)
        .lineLimit(1)
      Text(value)
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText())
        .animation(PopoverMotion.value, value: value)
      if let detail {
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A label/value line. `label` is passed through verbatim — unlike the popover's
/// `DetailRow` it never runs the label through the string table, because Dashboard
/// rows carry runtime text (process, volume and interface names) that must not be
/// silently "translated" when it happens to collide with a catalog key.
struct DataRow: View {
  let label: String
  let value: String
  var valueColor: Color = .primary
  var isMonospaced = true

  var body: some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: isMonospaced ? .rounded : .default))
        .monospacedDigit()
        .foregroundStyle(valueColor)
        .lineLimit(1)
    }
  }
}

/// Shown wherever this Mac cannot report something, so a missing reading never
/// renders as a zero that looks like a measurement.
struct UnsupportedNote: View {
  let message: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "minus.circle")
        .font(.system(size: 11))
      Text(message)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(.tertiary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A colored key for one chart band.
struct ChartLegend: View {
  let series: [ChartSeries]
  let format: (Double) -> String

  var body: some View {
    HStack(spacing: 16) {
      ForEach(series) { band in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(band.color)
            .frame(width: 8, height: 8)
          Text(band.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
          Text(format(band.values.last ?? 0))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
        }
      }
      Spacer(minLength: 0)
    }
  }
}

/// Horizontal tab switcher across the top of the Dashboard. Same idiom as
/// `PopoverTabBar`, sized for the settings window.
struct DashboardTabBar: View {
  @Binding var selection: DashboardSection
  @Namespace private var highlight
  @State private var hovered: DashboardSection?

  var body: some View {
    HStack(spacing: 2) {
      ForEach(DashboardSection.allCases) { section in
        Button {
          guard selection != section else { return }
          withAnimation(PopoverMotion.navigation) { selection = section }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: section.systemImage)
              .font(.system(size: 12, weight: .semibold))
              .symbolEffect(.bounce, value: selection == section)
            Text(section.title)
              .font(.system(size: 12, weight: .semibold))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 7)
          .background {
            if selection == section {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                .matchedGeometryEffect(id: "selected-dashboard-tab", in: highlight)
            } else if hovered == section {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == section ? .primary : .secondary)
        .onHover { isHovering in
          withAnimation(PopoverMotion.hover) {
            hovered = isHovering ? section : (hovered == section ? nil : hovered)
          }
        }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selection == section ? [.isSelected, .isButton] : .isButton)
      }
    }
    .padding(3)
    .background(
      Color.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    // Selection is already shown by the filled pill; the focus ring would read as
    // a second selected tab.
    .focusEffectDisabled()
  }
}

/// Temperature coloring, shared by every tab that shows a sensor.
enum DashboardPalette {
  static func temperature(_ celsius: Double) -> Color {
    switch celsius {
    case ..<65: return .green
    case ..<85: return .orange
    default: return .red
    }
  }

  static func load(_ fraction: Double) -> Color {
    switch fraction {
    case ..<0.6: return .accentColor
    case ..<0.85: return .orange
    default: return .red
    }
  }
}
