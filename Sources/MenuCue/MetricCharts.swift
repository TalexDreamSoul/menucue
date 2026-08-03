import SwiftUI

/// Stacked area chart of recent CPU load: user time on the bottom band, system time above it.
/// Shared by the popover Status tab and the Dashboard CPU tab.
struct CPUUsageChart: View {
  let samples: [CPULoadSample]
  let capacity: Int
  let userColor: Color
  let systemColor: Color

  var body: some View {
    Canvas { context, size in
      let baseline = Path(
        roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8, style: .continuous)
      context.fill(baseline, with: .color(.primary.opacity(0.05)))

      guard !samples.isEmpty else { return }
      context.clip(to: baseline)

      // Drawn back to front: the combined band first, then user on top of it.
      let combinedPoints = Self.points(
        samples: samples, capacity: capacity, in: size
      ) { $0.userBand + $0.systemBand }
      let userPoints = Self.points(
        samples: samples, capacity: capacity, in: size
      ) { $0.userBand }
      context.fill(Self.areaPath(points: combinedPoints, in: size), with: .color(systemColor.opacity(0.55)))
      context.fill(Self.areaPath(points: userPoints, in: size), with: .color(userColor.opacity(0.55)))

      context.stroke(
        Self.linePath(points: combinedPoints),
        with: .color(systemColor),
        lineWidth: 1.2)
      context.stroke(
        Self.linePath(points: userPoints),
        with: .color(userColor),
        lineWidth: 1.2)
    }
    .accessibilityHidden(true)
  }

  static func points(
    samples: [CPULoadSample],
    capacity: Int,
    in size: CGSize,
    value: (CPULoadSample) -> Double
  ) -> [CGPoint] {
    func y(_ sample: CPULoadSample) -> CGFloat {
      size.height * (1 - min(1, max(0, value(sample))))
    }

    // A lone sample is drawn flat across the width so the first frame after opening
    // shows a real level instead of an empty box.
    guard samples.count > 1 else {
      return samples.first.map { [CGPoint(x: 0, y: y($0)), CGPoint(x: size.width, y: y($0))] } ?? []
    }

    // Spread whatever history exists across the full width. Once the buffer is
    // saturated this is a fixed window, so the series scrolls instead of rescaling.
    let slot = size.width / CGFloat(min(samples.count, capacity) - 1)
    return samples.enumerated().map { index, sample in
      CGPoint(x: CGFloat(index) * slot, y: y(sample))
    }
  }

  private static func linePath(points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() {
      path.addLine(to: point)
    }
    return path
  }

  private static func areaPath(points: [CGPoint], in size: CGSize) -> Path {
    var path = linePath(points: points)
    guard let first = points.first, let last = points.last else { return path }
    path.addLine(to: CGPoint(x: last.x, y: size.height))
    path.addLine(to: CGPoint(x: first.x, y: size.height))
    path.closeSubpath()
    return path
  }
}

/// One band of a `SeriesChart`.
struct ChartSeries: Identifiable, Equatable {
  let label: String
  let values: [Double]
  let color: Color

  var id: String { label }
}

/// General time-series chart for the Dashboard: one or two filled bands over a
/// shared window. Follows `CPUUsageChart`'s conventions so the two read as one
/// system — same rounded baseline, same "a single sample draws flat across the
/// width" rule, so a freshly opened tab never shows an empty box.
struct SeriesChart: View {
  let series: [ChartSeries]
  let capacity: Int
  /// `nil` autoscales to the window maximum; pass 1 for a fraction, or a fan's
  /// ceiling RPM, when the axis has a meaningful fixed top.
  var upperBound: Double?
  var cornerRadius: CGFloat = 8

  var body: some View {
    Canvas { context, size in
      let baseline = Path(
        roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius,
        style: .continuous)
      context.fill(baseline, with: .color(.primary.opacity(0.05)))

      guard series.contains(where: { !$0.values.isEmpty }) else { return }
      context.clip(to: baseline)

      let scale = resolvedUpperBound
      for band in series {
        let points = Self.points(
          band.values, capacity: capacity, in: size, scale: scale)
        context.fill(
          Self.areaPath(points: points, in: size),
          with: .color(band.color.opacity(0.28)))
        context.stroke(
          Self.linePath(points: points), with: .color(band.color), lineWidth: 1.4)
      }
    }
    .accessibilityHidden(true)
  }

  /// Autoscale never collapses to zero height: an idle interface would otherwise
  /// divide by zero and paint a full-height block.
  private var resolvedUpperBound: Double {
    if let upperBound, upperBound > 0 { return upperBound }
    let peak = series.flatMap(\.values).max() ?? 0
    return peak > 0 ? peak : 1
  }

  static func points(
    _ values: [Double], capacity: Int, in size: CGSize, scale: Double
  ) -> [CGPoint] {
    func y(_ value: Double) -> CGFloat {
      size.height * (1 - CGFloat(min(1, max(0, value / scale))))
    }
    guard values.count > 1 else {
      return values.first.map { [CGPoint(x: 0, y: y($0)), CGPoint(x: size.width, y: y($0))] } ?? []
    }
    let slot = size.width / CGFloat(min(values.count, capacity) - 1)
    return values.enumerated().map { CGPoint(x: CGFloat($0.offset) * slot, y: y($0.element)) }
  }

  private static func linePath(points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() { path.addLine(to: point) }
    return path
  }

  private static func areaPath(points: [CGPoint], in size: CGSize) -> Path {
    var path = linePath(points: points)
    guard let first = points.first, let last = points.last else { return path }
    path.addLine(to: CGPoint(x: last.x, y: size.height))
    path.addLine(to: CGPoint(x: first.x, y: size.height))
    path.closeSubpath()
    return path
  }
}
