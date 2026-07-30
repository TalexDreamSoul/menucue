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
          .font(.headline)
          .foregroundStyle(tint)
        Text(title)
          .font(.headline)
        Spacer(minLength: 6)
        accessory
      }
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Semantic colors rather than an opacity over `primary`, so the card keeps its
    // contrast in dark mode and under Increase Contrast.
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: DashboardMetrics.cardCornerRadius, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DashboardMetrics.cardCornerRadius, style: .continuous)
        .strokeBorder(.quaternary, lineWidth: 1)
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
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(value)
        .font(.title2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText())
        .animation(PopoverMotion.value, value: value)
      if let detail {
        Text(detail)
          .font(.caption)
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
        .font(.body)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text(value)
        .font(.body.weight(.medium))
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
        .font(.callout)
      Text(message)
        .font(.callout)
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
            .font(.callout)
            .foregroundStyle(.secondary)
          Text(format(band.values.last ?? 0))
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .contentTransition(.numericText())
        }
      }
      Spacer(minLength: 0)
    }
  }
}

/// Tab switcher across the top of the Dashboard.
///
/// Drawn rather than a stock segmented `Picker`. A segmented control is the closer
/// platform idiom, but on macOS it renders either the icon or the label, not both,
/// and it cannot be snapshot-tested — `ImageRenderer` cannot capture AppKit-backed
/// controls, so its appearance could not be verified before shipping. This keeps the
/// icon-plus-label pairing, matches the popover's bar, and carries the selection
/// semantics a segmented control would have supplied.
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
              .menuCueSymbolBounce(value: selection == section)
            Text(section.title)
          }
          .font(.callout.weight(.medium))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 7)
          .background {
            if selection == section {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                .matchedGeometryEffect(id: "selected-dashboard-tab", in: highlight)
            } else if hovered == section {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
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
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
