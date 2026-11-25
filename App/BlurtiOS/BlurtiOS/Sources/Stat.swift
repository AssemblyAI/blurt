import BlurtDesign
import SwiftUI

/// One stat: a mono eyebrow over its value, drawn as number-and-unit pairs
/// (serif numbers, mono units) so "1 hr 25 min" reads as a measurement. Units
/// scale with the number, so every size keeps the same proportions.
struct Stat: View {
  let label: String
  let parts: [(value: String, unit: String?)]
  let size: CGFloat

  var body: some View {
    let metrics = DesignTokens.Metrics.self
    VStack(alignment: .leading, spacing: metrics.appLineGap) {
      Eyebrow(label)
      HStack(alignment: .firstTextBaseline, spacing: size * metrics.statPartGapRatio) {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
          HStack(alignment: .firstTextBaseline, spacing: size * metrics.statUnitGapRatio) {
            Text(part.value)
              .headingFont(size)
              .tracking(size * metrics.statTrackingRatio)
              .foregroundStyle(BlurtBrand.text)
            if let unit = part.unit {
              Text(unit.uppercased())
                .monoFont((size * metrics.statUnitRatio).rounded(), weight: .medium)
                .foregroundStyle(BlurtBrand.muted)
            }
          }
        }
      }
    }
    .lineLimit(1)
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}
