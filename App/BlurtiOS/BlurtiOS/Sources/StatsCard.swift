import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Lifetime dictations, words, and time saved over typing them, at the top of
/// the Dictate tab. Every dictation counts, from the app or the keyboard; the
/// totals stay on the phone (`DictationStats`).
struct StatsCard: View {
  private typealias Parts = [(String, String?)]

  @AppStorage(DictationStats.defaultsKey)
  private var raw = Data()
  /// The speed time saved is measured against: the phone average, or the
  /// easter egg's latest result (`TypingSpeed`).
  @AppStorage(TypingSpeed.defaultsKey)
  private var typingSpeed: Double = 0

  var body: some View {
    let stats = DictationStats.decode(raw)
    let saved = stats.timeSaved(typingWordsPerMinute: TypingSpeed.resolved(typingSpeed))
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
