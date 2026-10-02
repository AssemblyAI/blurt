import Foundation

/// Lifetime totals for the Dictate tab's stats card: dictations, words, and
/// time spent talking. On the phone only, in the app's own defaults — from
/// the app and the keyboard alike, since every dictation runs in the app.
///
/// Time saved is derived from the totals rather than stored, so it follows
/// whichever typing speed it's measured against.
package nonisolated struct DictationStats: Codable, Equatable, Sendable {
  /// Average phone typing speed, the baseline for time saved: 36 words per
  /// minute (Palin et al., "How do people type on mobile devices?", MobileHCI
  /// 2019).
  package static let averageTypingWordsPerMinute: Double = 36

  package private(set) var dictations = 0
  package private(set) var words = 0
  package private(set) var secondsSpoken: Double = 0

  package init() {}

  /// How long typing every dictated word would have taken at `wordsPerMinute`,
  /// minus the time actually spent talking. Never negative.
  package func timeSaved(typingWordsPerMinute wordsPerMinute: Double = averageTypingWordsPerMinute) -> Duration {
    guard wordsPerMinute > 0 else { return .zero }
    let typingSeconds = Double(words) / wordsPerMinute * 60
    return .seconds(max(0, typingSeconds - secondsSpoken))
  }

  /// One delivered dictation: the words as inserted (text shortcuts expanded,
  /// since that's what wasn't typed) and how long the user spoke. Empty text
  /// isn't a dictation.
  package mutating func record(_ text: String, spokenFor seconds: Double) {
    let count = Self.wordCount(of: text)
    guard count > 0 else { return }
    dictations += 1
    words += count
    secondsSpoken += max(0, seconds)
  }

  /// Linguistic words, not whitespace runs, so punctuation and languages
  /// written without spaces count sensibly.
  package static func wordCount(of text: String) -> Int {
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
      count += 1
    }
    return count
  }

  // MARK: - Persistence

  /// The JSON-encoded totals, a `Data` slot so a view can observe it with
  /// `@AppStorage` and redraw as dictations land.
  package static let defaultsKey = "DictationStats"

  package static func load(from defaults: UserDefaults = .standard) -> DictationStats {
    decode(defaults.data(forKey: defaultsKey))
  }

  /// The totals behind a slot value a view already observed; blank or
  /// unreadable is no dictations yet.
  package static func decode(_ data: Data?) -> DictationStats {
    data.flatMap { try? JSONDecoder().decode(DictationStats.self, from: $0) } ?? DictationStats()
  }

  package func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
  }

  /// Records one dictation straight into `defaults`. The app calls this and
  /// `reset` from the main actor only, so a reset can't land between a
  /// record's read and its write.
  package static func record(_ text: String, spokenFor seconds: Double, in defaults: UserDefaults = .standard) {
    var stats = load(from: defaults)
    stats.record(text, spokenFor: seconds)
    stats.save(to: defaults)
  }

  package static func reset(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: defaultsKey)
  }
}

/// The stats card's renderings. Counts stay short; time saved is shown in full
/// ("1 hr 25 min 45 sec"), because watching every second add up is the point.
package nonisolated enum StatFormat {
  /// A count, compact past four digits: `9,999`, then `12K`.
  package static func count(_ value: Int) -> String {
    value < 10_000 ? value.formatted() : value.formatted(.number.notation(.compactName))
  }

  /// A duration as number-and-unit parts, largest first, skipping zero parts:
  /// `[("1", "hr"), ("25", "min"), ("45", "sec")]`. Under a second is `0 sec`.
  package static func durationParts(_ duration: Duration) -> [(value: String, unit: String)] {
    var remaining = Int(duration.components.seconds)
    guard remaining > 0 else { return [("0", "sec")] }
    var parts: [(String, String)] = []
    for (unit, size) in [("day", 86_400), ("hr", 3_600), ("min", 60), ("sec", 1)] {
      let amount = remaining / size
      remaining %= size
      if amount > 0 { parts.append((amount.formatted(), unit)) }
    }
    return parts
  }
}
