import AppKit
import SwiftUI

/// A single sampled pixel, reduced to the only components the picker cares about.
struct FlagPixel: Equatable {
  var hue: Double
  var saturation: Double
  var brightness: Double
}

/// One or two hues lifted from a flag. `secondary` is nil for single-hue flags such
/// as Japan, where a gradient would invent a color the flag does not have.
struct FlagTint {
  var primary: Color
  var secondary: Color?
  /// Share of the flag covered by the primary hue, 0...1. Japan's small disc and
  /// China's full red field both resolve to the same hue; this is what keeps their
  /// cards from looking identical.
  var intensity: Double = 0.5

  var gradient: LinearGradient {
    let strength = 0.14 + 0.26 * min(1, max(0, intensity))
    return LinearGradient(
      colors: [
        primary.opacity(strength),
        // Two-tone flags hold their second color at nearly full strength so the
        // card reads bi-color; single-hue flags fade out instead.
        (secondary ?? primary).opacity(secondary == nil ? strength * 0.15 : strength * 0.9),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

/// Derives a per-region accent from the flag emoji itself, so adding a time zone
/// needs no palette entry. A hand-maintained country table would be ~250 rows and
/// would still miss whatever Unicode adds next.
enum FlagPalette {
  /// Bucket count for the hue histogram. Twelve is coarse enough that the red bands
  /// of a striped flag land together, fine enough to keep red apart from orange.
  static let hueBucketCount = 12

  /// Pixels below these are flag whites, blacks, and antialiasing fringes — every
  /// flag has them, so they carry no identity.
  static let minimumSaturation = 0.35
  static let minimumBrightness = 0.25

  /// Tints are clamped into a band that stays legible as a card wash in both light
  /// and dark appearance.
  static let tintSaturation: ClosedRange<Double> = 0.55...0.9
  static let tintBrightness: ClosedRange<Double> = 0.55...0.9

  /// A second hue only counts if it carries at least this share of the winner's
  /// weight — otherwise an emblem's few stray pixels would drive half the gradient.
  static let secondaryWeightShare = 0.22
  /// Hue buckets must be this far apart to count as genuinely different colors, so
  /// red and orange-red do not read as a two-tone flag.
  static let minimumBucketSeparation = 2

  private static let lock = NSLock()
  private static var cache: [String: FlagTint] = [:]

  static func tint(for flag: String) -> FlagTint {
    lock.lock()
    defer { lock.unlock() }
    if let cached = cache[flag] { return cached }
    let tint = pixels(of: flag).flatMap(self.tint(from:)) ?? FlagTint(primary: .accentColor)
    cache[flag] = tint
    return tint
  }

  /// Returns the two heaviest saturated hues. Picking only one made every red-heavy
  /// flag — US, China, UK, Japan, Germany — collapse to the same pink card; the
  /// second hue is what actually tells them apart.
  ///
  /// Weighting by saturation × brightness keeps a small vivid emblem from losing to
  /// a large washed-out field.
  static func tint(from pixels: [FlagPixel]) -> FlagTint? {
    var weights = [Double](repeating: 0, count: hueBucketCount)
    var hueSums = [Double](repeating: 0, count: hueBucketCount)
    var saturationSums = [Double](repeating: 0, count: hueBucketCount)
    var counts = [Int](repeating: 0, count: hueBucketCount)

    for pixel in pixels
    where pixel.saturation >= minimumSaturation && pixel.brightness >= minimumBrightness {
      let bucket = min(hueBucketCount - 1, Int(pixel.hue * Double(hueBucketCount)))
      let weight = pixel.saturation * pixel.brightness
      weights[bucket] += weight
      hueSums[bucket] += pixel.hue * weight
      saturationSums[bucket] += pixel.saturation * weight
      counts[bucket] += 1
    }

    guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
      weights[best] > 0
    else { return nil }

    func color(at bucket: Int) -> Color {
      Color(
        hue: hueSums[bucket] / weights[bucket],
        saturation: tintSaturation.clamped(saturationSums[bucket] / weights[bucket]),
        brightness: tintBrightness.upperBound
      )
    }

    let runnerUp = weights.indices
      .filter { separation(from: best, to: $0) >= minimumBucketSeparation }
      .filter { weights[$0] >= weights[best] * secondaryWeightShare }
      .max(by: { weights[$0] < weights[$1] })

    // Measured against every sampled pixel, not just the saturated ones, so a flag
    // that is mostly white scores low even though its one color is vivid.
    let coverage = pixels.isEmpty ? 0.5 : Double(counts[best]) / Double(pixels.count)
    return FlagTint(
      primary: color(at: best),
      secondary: runnerUp.map(color(at:)),
      intensity: coverage
    )
  }

  /// Hue is circular, so bucket 0 and bucket 11 are neighbours, not opposites.
  static func separation(from lhs: Int, to rhs: Int) -> Int {
    let direct = abs(lhs - rhs)
    return min(direct, hueBucketCount - direct)
  }

  /// Renders the emoji into a small bitmap and reads it back as HSB samples.
  private static func pixels(of flag: String) -> [FlagPixel]? {
    let side = 24
    guard
      let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      )
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    (flag as NSString).draw(
      in: NSRect(x: 0, y: 0, width: side, height: side),
      withAttributes: [.font: NSFont.systemFont(ofSize: CGFloat(side) * 0.85)]
    )
    NSGraphicsContext.restoreGraphicsState()

    var samples: [FlagPixel] = []
    samples.reserveCapacity(side * side)
    for y in 0..<side {
      for x in 0..<side {
        guard let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0.5 else {
          continue
        }
        guard let rgb = color.usingColorSpace(.deviceRGB) else { continue }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        samples.append(
          FlagPixel(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
        )
      }
    }
    return samples.isEmpty ? nil : samples
  }
}

extension ClosedRange where Bound == Double {
  fileprivate func clamped(_ value: Double) -> Double {
    Swift.min(upperBound, Swift.max(lowerBound, value))
  }
}
