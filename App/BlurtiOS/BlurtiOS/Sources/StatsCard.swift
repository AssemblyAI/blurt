import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Lifetime dictations, words, and time saved over typing them, at the top of
/// the Dictate tab. Every dictation counts, from the app or the keyboard; the
/// totals stay on the phone (`DictationStats`).
struct StatsCard: View {
  @AppStorage(DictationStats.defaultsKey) private var raw = Data()

  var body: some View {
    let stats = DictationStats.decode(raw)
    let saved = stats.timeSaved()
    let dictations = [(StatFormat.count(stats.dictations), String?.none)]
    let words = [(StatFormat.count(stats.words), String?.none)]
    let timeSaved = StatFormat.durationParts(saved).map { ($0.value, Optional($0.unit)) }
    let sizes = DesignTokens.Typography.self
    // Under an hour, all three share one row. Once time saved reaches hours
    // ("1 hr 19 min 50 sec") it moves to a full-width second row. Either way
    // every value is the same size: the largest that fits.
    //
    // The candidates are listed out, not generated with ForEach: ViewThatFits
    // traps on generated children whose identities repeat across branches.
    ViewThatFits(in: .horizontal) {
      if saved < .seconds(3_600) {
        oneRow(dictations, words, timeSaved, size: sizes.sizeStatXl)
        oneRow(dictations, words, timeSaved, size: sizes.sizeStatL)
        oneRow(dictations, words, timeSaved, size: sizes.sizeStatM)
        oneRow(dictations, words, timeSaved, size: sizes.sizeStatS)
      }
      twoRows(dictations, words, timeSaved, size: sizes.sizeStatXl)
      twoRows(dictations, words, timeSaved, size: sizes.sizeStatL)
      twoRows(dictations, words, timeSaved, size: sizes.sizeStatM)
      twoRows(dictations, words, timeSaved, size: sizes.sizeStatS)
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  private typealias Parts = [(String, String?)]

  private func oneRow(_ dictations: Parts, _ words: Parts, _ timeSaved: Parts, size: CGFloat) -> some View {
    HStack(alignment: .top, spacing: 0) {
      Stat(label: "Dictations", parts: dictations, size: size)
      Spacer(minLength: DesignTokens.Metrics.appStatGap)
      Stat(label: "Words", parts: words, size: size)
      Spacer(minLength: DesignTokens.Metrics.appStatGap)
      Stat(label: "Time saved", parts: timeSaved, size: size)
    }
  }

  private func twoRows(_ dictations: Parts, _ words: Parts, _ timeSaved: Parts, size: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStatGap) {
      HStack(alignment: .top, spacing: 0) {
        Stat(label: "Dictations", parts: dictations, size: size)
          .frame(maxWidth: .infinity, alignment: .leading)
        Stat(label: "Words", parts: words, size: size)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Stat(label: "Time saved", parts: timeSaved, size: size)
    }
  }
}

/// One stat: a mono eyebrow over its value, drawn as number-and-unit pairs
/// (serif numbers, mono units) so "1 hr 25 min" reads as a measurement. Units
/// scale with the number, so every size keeps the same proportions.
private struct Stat: View {
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
              .font(BlurtType.heading(size))
              .tracking(size * metrics.statTrackingRatio)
              .foregroundStyle(BlurtBrand.text)
            if let unit = part.unit {
              Text(unit.uppercased())
                .font(BlurtType.mono((size * metrics.statUnitRatio).rounded(), weight: .medium))
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
