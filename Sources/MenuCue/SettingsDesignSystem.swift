import SwiftUI

/// Shared visual language for the Settings window, transcribed from the v1.0.0 design
/// document (`design/v1.0.0.pen`, panes C–O).
///
/// Every pane is built from cards, and every card is a stack of rows. The surface is
/// opaque on purpose: `SettingsRows` leaves a 1pt gap between rows and paints the
/// hairline colour behind them, so the rows occlude it and the gaps *become* the
/// separators. That is what keeps callers from threading dividers between rows by hand.
///
/// Callers pass **already-localized** strings — they resolve their own keys through
/// `L10n` before handing them over: these components render what they are given, so a
/// translated value can never be looked up twice.
enum SettingsMetrics {
  /// The design document's content column inside a 900pt window.
  static let contentWidth: CGFloat = 640
  static let cardSpacing: CGFloat = 14
  static let cardCornerRadius: CGFloat = 10
  static let rowPaddingH: CGFloat = 14
  static let rowPaddingV: CGFloat = 10
  static let rowSpacing: CGFloat = 12
  static let labelSpacing: CGFloat = 3
  static let tableCellGap: CGFloat = 12
}

extension Color {
  /// Card fill. Opaque so rows can occlude the separator layer behind them.
  static var settingsCardSurface: Color { Color(nsColor: .controlBackgroundColor) }
  /// Recessed card fill, for a card nested inside another card.
  static var settingsInsetSurface: Color { Color(nsColor: .underPageBackgroundColor) }
  static var settingsHairline: Color { Color(nsColor: .separatorColor) }
  /// A chip or pill sitting on top of a card.
  static var settingsRaisedSurface: Color { Color.primary.opacity(0.09) }
  static var settingsAccentSoft: Color { Color.accentColor.opacity(0.18) }
  static var settingsCardStroke: Color { Color.primary.opacity(0.07) }
}

private struct SettingsSurfaceKey: EnvironmentKey {
  static let defaultValue: Color = .settingsCardSurface
}

extension EnvironmentValues {
  var settingsSurface: Color {
    get { self[SettingsSurfaceKey.self] }
    set { self[SettingsSurfaceKey.self] = newValue }
  }
}

enum SettingsCardTone {
  case card
  case inset

  var surface: Color {
    switch self {
    case .card: return .settingsCardSurface
    case .inset: return .settingsInsetSurface
    }
  }
}

enum SettingsButtonKind {
  case primary
  case secondary
  case danger
  case link
}

/// A titled card. `action` sits on the title line, right-aligned (the design document's
/// "reset format" style control). Put `SettingsRow`s in `content`, wrapped in
/// `SettingsRows`.
struct SettingsCard<Action: View, Content: View>: View {
  let title: String
  let desc: String?
  let tone: SettingsCardTone
  @ViewBuilder let action: Action
  @ViewBuilder let content: Content

  init(
    _ title: String,
    desc: String? = nil,
    tone: SettingsCardTone = .card,
    @ViewBuilder action: () -> Action = { EmptyView() },
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.desc = desc
    self.tone = tone
    self.action = action()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.rowSpacing) {
        VStack(alignment: .leading, spacing: SettingsMetrics.labelSpacing) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
          if let desc {
            Text(desc)
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        action
      }
      .padding(.horizontal, SettingsMetrics.rowPaddingH)
      .padding(.top, 12)
      .padding(.bottom, 10)

      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.surface)
    .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
        .stroke(Color.settingsCardStroke, lineWidth: 1)
    )
    .environment(\.settingsSurface, tone.surface)
  }
}

/// Row stack that owns the separators: rows sit on the card surface, the hairline
/// colour shows through the 1pt gaps between them.
struct SettingsRows<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      content
    }
    .background(Color.settingsHairline)
  }
}

/// One settings row: label (+ explanation) on the left, control on the right.
/// `SettingsCard` supplies the surface through the environment, so a row never needs to
/// know which card it lives in.
struct SettingsRow<Control: View>: View {
  @Environment(\.settingsSurface) private var surface
  let title: String
  let desc: String?
  let controlWidth: CGFloat?
  @ViewBuilder let control: Control

  init(
    _ title: String,
    desc: String? = nil,
    controlWidth: CGFloat? = nil,
    @ViewBuilder control: () -> Control = { EmptyView() }
  ) {
    self.title = title
    self.desc = desc
    self.controlWidth = controlWidth
    self.control = control()
  }

  var body: some View {
    HStack(alignment: .center, spacing: SettingsMetrics.rowSpacing) {
      VStack(alignment: .leading, spacing: SettingsMetrics.labelSpacing) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let desc {
          Text(desc)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      control.frame(width: controlWidth)
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, SettingsMetrics.rowPaddingV)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface)
  }
}

/// Row whose control stacks *under* the label — for wide controls (tables, previews).
struct SettingsStackedRow<Content: View>: View {
  @Environment(\.settingsSurface) private var surface
  let title: String
  let desc: String?
  @ViewBuilder let content: Content

  init(_ title: String, desc: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.desc = desc
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: SettingsMetrics.labelSpacing) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
        if let desc {
          Text(desc)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      content
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, SettingsMetrics.rowPaddingV)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface)
  }
}

struct SettingsRowToggle: View {
  let title: String
  let desc: String?
  @Binding var isOn: Bool

  init(_ title: String, desc: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.desc = desc
    self._isOn = isOn
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      Toggle("", isOn: $isOn)
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }
}

/// A pop-up-menu row. `options` is `(value, display)`; display strings are already localized.
struct SettingsRowSelect<Value: Hashable>: View {
  let title: String
  let desc: String?
  @Binding var selection: Value
  let options: [(value: Value, label: String)]

  init(
    _ title: String,
    desc: String? = nil,
    selection: Binding<Value>,
    options: [(value: Value, label: String)]
  ) {
    self.title = title
    self.desc = desc
    self._selection = selection
    self.options = options
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      Picker("", selection: $selection) {
        ForEach(options, id: \.value) { option in
          Text(option.label).tag(option.value)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
    }
  }
}

struct SettingsRowSegmented: View {
  let title: String
  let desc: String?
  @Binding var selection: Int
  let options: [String]

  init(_ title: String, desc: String? = nil, selection: Binding<Int>, options: [String]) {
    self.title = title
    self.desc = desc
    self._selection = selection
    self.options = options
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      Picker("", selection: $selection) {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
          Text(option).tag(index)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
    }
  }
}

struct SettingsRowField: View {
  let title: String
  let desc: String?
  @Binding var text: String
  let fieldWidth: CGFloat
  let monospaced: Bool

  init(
    _ title: String,
    desc: String? = nil,
    text: Binding<String>,
    fieldWidth: CGFloat = 190,
    monospaced: Bool = true
  ) {
    self.title = title
    self.desc = desc
    self._text = text
    self.fieldWidth = fieldWidth
    self.monospaced = monospaced
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      TextField("", text: $text)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: monospaced ? .monospaced : .default))
        .frame(width: fieldWidth)
    }
  }
}

/// Read-only value on the right of a row.
struct SettingsRowValue: View {
  let title: String
  let desc: String?
  let value: String
  let tint: Color

  init(_ title: String, desc: String? = nil, value: String, tint: Color = .secondary) {
    self.title = title
    self.desc = desc
    self.value = value
    self.tint = tint
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      Text(value)
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SettingsRowButton: View {
  let title: String
  let desc: String?
  let buttonTitle: String
  let kind: SettingsButtonKind
  let action: () -> Void

  init(
    _ title: String,
    desc: String? = nil,
    buttonTitle: String,
    kind: SettingsButtonKind = .secondary,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.desc = desc
    self.buttonTitle = buttonTitle
    self.kind = kind
    self.action = action
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      Button(buttonTitle, action: action)
        .applySettingsButtonStyle(kind)
    }
  }
}

struct SettingsRowSlider: View {
  let title: String
  let desc: String?
  @Binding var value: Double
  let range: ClosedRange<Double>
  let valueLabel: String
  let sliderWidth: CGFloat

  init(
    _ title: String,
    desc: String? = nil,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    valueLabel: String,
    sliderWidth: CGFloat = 200
  ) {
    self.title = title
    self.desc = desc
    self._value = value
    self.range = range
    self.valueLabel = valueLabel
    self.sliderWidth = sliderWidth
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      HStack(spacing: 10) {
        Text(valueLabel)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(minWidth: 46, alignment: .trailing)
        Slider(value: $value, in: range)
          .frame(width: sliderWidth)
      }
    }
  }
}

/// A pill of metadata: "自定义标签", "被引用", "默认打开".
struct SettingsChip: View {
  let label: String
  let systemImage: String?
  let tint: Color?
  let prominent: Bool

  init(_ label: String, systemImage: String? = nil, tint: Color? = nil, prominent: Bool = false) {
    self.label = label
    self.systemImage = systemImage
    self.tint = tint
    self.prominent = prominent
  }

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
      }
      Text(label)
        .font(.system(size: 11))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .foregroundStyle(tint ?? .secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule(style: .continuous)
        .fill(prominent ? Color.settingsAccentSoft : Color.settingsRaisedSurface)
    )
    .help(label)
  }
}

/// The document's banner: an icon, a title, an explanation, and an optional action.
struct SettingsBanner<Action: View>: View {
  let title: String
  let desc: String?
  let systemImage: String
  let tint: Color
  @ViewBuilder let action: Action

  init(
    _ title: String,
    desc: String? = nil,
    systemImage: String = "exclamationmark.triangle.fill",
    tint: Color = .orange,
    @ViewBuilder action: () -> Action = { EmptyView() }
  ) {
    self.title = title
    self.desc = desc
    self.systemImage = systemImage
    self.tint = tint
    self.action = action()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: SettingsMetrics.labelSpacing) {
        Text(title)
          .font(.system(size: 12.5, weight: .medium))
        if let desc {
          Text(desc)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      action
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.settingsCardSurface)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(Color.settingsCardStroke, lineWidth: 1)
    )
  }
}

/// Row that jumps to another settings pane. It goes through `AppRouter` like the sidebar
/// and the deep links do, so a cross-pane shortcut is never a second navigation path.
struct SettingsPaneLinkRow: View {
  @EnvironmentObject private var router: AppRouter
  let title: String
  let desc: String?
  let destination: SettingsPane
  let actionTitle: String

  init(_ title: String, desc: String? = nil, destination: SettingsPane, actionTitle: String) {
    self.title = title
    self.desc = desc
    self.destination = destination
    self.actionTitle = actionTitle
  }

  var body: some View {
    SettingsRow(title, desc: desc) {
      Button(actionTitle) {
        router.settingsPane = destination
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }
}

/// A reorderable list entry on the recessed fill — the clock carousel and the
/// time-zone results both use this shape.
struct SettingsListRow<Controls: View>: View {
  let title: String
  let desc: String?
  let systemImage: String?
  let showsHandle: Bool
  @ViewBuilder let controls: Controls

  init(
    _ title: String,
    desc: String? = nil,
    systemImage: String? = nil,
    showsHandle: Bool = false,
    @ViewBuilder controls: () -> Controls = { EmptyView() }
  ) {
    self.title = title
    self.desc = desc
    self.systemImage = systemImage
    self.showsHandle = showsHandle
    self.controls = controls()
  }

  var body: some View {
    HStack(spacing: 10) {
      if showsHandle {
        Image(systemName: "line.3.horizontal")
          .font(.system(size: 14))
          .foregroundStyle(.tertiary)
      }
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
        if let desc {
          Text(desc)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      controls
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.settingsInsetSurface)
  }
}

struct SettingsEmptyState<Action: View>: View {
  let title: String
  let desc: String
  let systemImage: String
  @ViewBuilder let action: Action

  init(
    _ title: String,
    desc: String,
    systemImage: String = "tray",
    @ViewBuilder action: () -> Action = { EmptyView() }
  ) {
    self.title = title
    self.desc = desc
    self.systemImage = systemImage
    self.action = action()
  }

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 22))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
      Text(desc)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      action
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity)
    .background(Color.settingsInsetSurface)
  }
}

/// One column of a `SettingsTable`. Not nested: a call site builds its column list in a
/// property, and naming a nested type would demand the table's view type at that point.
/// `weight` is the column's share of the card's inner width.
struct SettingsTableColumn {
  let title: String
  let weight: CGFloat
  let alignment: HorizontalAlignment

  init(_ title: String, weight: CGFloat = 1, alignment: HorizontalAlignment = .leading) {
    self.title = title
    self.weight = weight
    self.alignment = alignment
  }
}

/// Table header + rows that share one column definition, so a cell can never drift out
/// of its column and the header always sits on the rows' grid.
struct SettingsTable<Content: View>: View {
  let columns: [SettingsTableColumn]
  @ViewBuilder let content: Content

  init(columns: [SettingsTableColumn], @ViewBuilder content: () -> Content) {
    self.columns = columns
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 1) {
      SettingsTableColumns(weights: columnWeights) {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
          Text(column.title)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: alignment(for: column.alignment))
        }
      }
      .padding(.horizontal, SettingsMetrics.rowPaddingH)
      .padding(.vertical, 7)
      .background(Color.settingsInsetSurface)

      content
    }
    .background(Color.settingsHairline)
    .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous))
    .environment(\.settingsTableColumnWeights, columnWeights)
  }

  private var columnWeights: [CGFloat] { columns.map(\.weight) }

  private func alignment(for value: HorizontalAlignment) -> Alignment {
    switch value {
    case .trailing: return .trailing
    case .center: return .center
    default: return .leading
    }
  }
}

/// One table row. Cells are placed on the weights of the enclosing `SettingsTable`, so a
/// row can never drift out of its column.
struct SettingsTableRow<Content: View>: View {
  @Environment(\.settingsSurface) private var surface
  @Environment(\.settingsTableColumnWeights) private var weights
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    Group {
      if weights.isEmpty {
        // Not inside a `SettingsTable`: no shared grid to sit on, so stay an `HStack`.
        HStack(spacing: SettingsMetrics.tableCellGap) {
          content
        }
      } else {
        SettingsTableColumns(weights: weights) {
          content
        }
      }
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface)
  }
}

/// Column weights of the enclosing `SettingsTable`, so a row can place its cells on the
/// header's grid without every call site repeating the column list.
private struct SettingsTableColumnWeightsKey: EnvironmentKey {
  static let defaultValue: [CGFloat] = []
}

extension EnvironmentValues {
  var settingsTableColumnWeights: [CGFloat] {
    get { self[SettingsTableColumnWeightsKey.self] }
    set { self[SettingsTableColumnWeightsKey.self] = newValue }
  }
}

/// Lays a table's cells out on one shared column grid. Each column takes its `weight`
/// share of the available width — a cell can no longer steal width from its neighbours
/// the way a `Spacer` inside one cell used to, and a table's columns line up with the
/// design document's proportions instead of splitting evenly.
struct SettingsTableColumns: Layout {
  var weights: [CGFloat]

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 0
    let widths = Self.columnWidths(weights: weights, total: width, count: subviews.count)
    let height = zip(subviews, widths).reduce(CGFloat.zero) { tallest, pair in
      max(tallest, pair.0.sizeThatFits(ProposedViewSize(width: pair.1, height: proposal.height)).height)
    }
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let widths = Self.columnWidths(weights: weights, total: bounds.width, count: subviews.count)
    var x = bounds.minX
    for (subview, width) in zip(subviews, widths) {
      subview.place(
        at: CGPoint(x: x, y: bounds.midY),
        anchor: .leading,
        proposal: ProposedViewSize(width: width, height: bounds.height)
      )
      x += width + SettingsMetrics.tableCellGap
    }
  }

  /// Shares the usable width (total minus the inter-column gaps) in proportion to each
  /// column's weight. A column without a declared weight shares evenly with its peers,
  /// and a weight is never allowed to collapse to zero — a zero-width column would let
  /// two cells overlap in the same pixels.
  static func columnWidths(weights: [CGFloat], total: CGFloat, count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    let gaps = SettingsMetrics.tableCellGap * CGFloat(count - 1)
    let usable = max(0, total - gaps)
    let shares = (0..<count).map { index -> CGFloat in
      index < weights.count ? max(0.01, weights[index]) : 1
    }
    let sum = shares.reduce(0, +)
    return shares.map { usable * $0 / sum }
  }
}

/// Pane title block. `status` renders the design document's live status pill
/// ("时钟运行中") opposite the title.
struct SettingsPaneHeader<Accessory: View>: View {
  let title: String
  let subtitle: String
  let systemImage: String
  @ViewBuilder let accessory: Accessory

  init(
    _ title: String,
    subtitle: String,
    systemImage: String,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() }
  ) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.accessory = accessory()
  }

  var body: some View {
    HStack(alignment: .center, spacing: SettingsMetrics.rowSpacing) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
          Text(title)
            .font(.system(size: 19, weight: .semibold))
        }
        Text(subtitle)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      accessory
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SettingsButtonStyle: ViewModifier {
  let kind: SettingsButtonKind

  func body(content: Content) -> some View {
    switch kind {
    case .primary:
      content.buttonStyle(.borderedProminent).controlSize(.small)
    case .secondary:
      content.buttonStyle(.bordered).controlSize(.small)
    case .danger:
      content.buttonStyle(.bordered).controlSize(.small).tint(.red)
    case .link:
      content.buttonStyle(.link).controlSize(.small)
    }
  }
}

private extension View {
  @ViewBuilder
  func applySettingsButtonStyle(_ kind: SettingsButtonKind) -> some View {
    modifier(SettingsButtonStyle(kind: kind))
  }
}
