import BlurtEngine
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

  // MARK: - Persistence

  /// The JSON-encoded totals, a `Data` slot so a view can observe it with
  /// `@AppStorage` and redraw as dictations land.
  package static let defaultsKey = "DictationStats"

  package private(set) var dictations = 0
  package private(set) var words = 0
  package private(set) var secondsSpoken: Double = 0

  package init() {
    // Nothing to set: every tally starts at zero.
  }

  package static func load(from defaults: UserDefaults = .standard) -> Self {
    decode(defaults.data(forKey: defaultsKey))
  }

  /// The totals behind a slot value a view already observed; blank or
  /// unreadable is no dictations yet.
  package static func decode(_ data: Data?) -> Self {
    data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
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

  /// How long typing every dictated word would have taken at `wordsPerMinute`,
  /// minus the time actually spent talking. Never negative.
  package func timeSaved(typingWordsPerMinute wordsPerMinute: Double = averageTypingWordsPerMinute) -> Duration {
    guard wordsPerMinute > 0 else {
      return .zero
    }
    let typingSeconds = Double(words) / wordsPerMinute * 60
    return .seconds(max(0, typingSeconds - secondsSpoken))
  }

  /// One delivered dictation: the words as inserted (text shortcuts expanded,
  /// since that's what wasn't typed) and how long the user spoke. Empty text
  /// isn't a dictation.
  package mutating func record(_ text: String, spokenFor seconds: Double) {
    // The engine's one definition of a word, which the Mac's Library counts by too.
    let count = text.wordCount
    guard count > 0 else {
      return
    }
    dictations += 1
    words += count
    secondsSpoken += max(0, seconds)
  }

  package func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
  }
}
