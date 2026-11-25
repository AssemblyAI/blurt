import Foundation

/// The typing speed time saved is measured against: the phone average until
/// the user takes the easter egg's sprint, then their latest result (how they
/// type now, not their best). Also keeps the best, for the results screen. In
/// the app's own defaults, beside `DictationStats`.
package nonisolated enum TypingSpeed {
  package struct Result: Equatable, Sendable {
    package let isBest: Bool
    package let setsSpeed: Bool
  }

  package static let defaultsKey = "TypingWordsPerMinute"
  package static let bestKey = "TypingTestBestWPM"
  /// Below this the run measured nothing (the user barely typed), so it leaves
  /// the time-saved speed alone.
  package static let minimumMeaningful: Double = 5

  /// The speed a stored value stands for: the average when none is stored.
  package static func resolved(_ stored: Double) -> Double {
    stored > 0 ? stored : DictationStats.averageTypingWordsPerMinute
  }

  package static func current(in defaults: UserDefaults = .standard) -> Double {
    resolved(defaults.double(forKey: defaultsKey))
  }

  package static func best(in defaults: UserDefaults = .standard) -> Double {
    defaults.double(forKey: bestKey)
  }

  /// Records a finished sprint: a new best is kept, and a meaningful result
  /// becomes the time-saved speed, rounded as it's shown.
  package static func record(_ wordsPerMinute: Double, in defaults: UserDefaults = .standard) -> Result {
    let isBest = wordsPerMinute > best(in: defaults)
    if isBest { defaults.set(wordsPerMinute, forKey: bestKey) }
    let setsSpeed = wordsPerMinute >= minimumMeaningful
    if setsSpeed { defaults.set(wordsPerMinute.rounded(), forKey: defaultsKey) }
    return Result(isBest: isBest, setsSpeed: setsSpeed)
  }

  package static func resetToAverage(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: defaultsKey)
  }
}
