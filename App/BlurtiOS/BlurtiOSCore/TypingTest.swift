import Foundation

/// The easter egg behind Settings: a 30-second sprint over random common words
/// that measures how fast the user types. Pure state, so the scoring is
/// tested; `TypingTestView` owns the clock and the theatrics.
///
/// Scored the standard way: a "word" is five characters, and only correctly
/// typed words count, each with its trailing space. The word being typed when
/// time runs out doesn't count.
package nonisolated struct TypingTest: Sendable {
  package static let duration: Duration = .seconds(30)
  /// Seconds left when the clock turns and starts to thump.
  package static let finalStretch: Duration = .seconds(5)
  /// Conversational speech runs about 150 words a minute, the comparison the
  /// results end on.
  package static let speakingWordsPerMinute: Double = 150

  package let words: [String]
  package private(set) var index = 0
  package private(set) var outcomes: [Bool] = []
  private var correctCharacters = 0

  package init(words: [String] = TypingTest.randomWords()) {
    self.words = words.isEmpty ? ["blurt"] : words
  }

  package var currentWord: String { words[index % words.count] }

  /// Scores `typed` against the current word and moves on. Returns whether it
  /// was right.
  @discardableResult
  package mutating func submit(_ typed: String) -> Bool {
    let isCorrect = typed == currentWord
    outcomes.append(isCorrect)
    if isCorrect { correctCharacters += typed.count + 1 }
    index += 1
    return isCorrect
  }

  /// Whether what's typed so far could still become the current word: the
  /// field turns orange mid-word when it can't.
  package func isOnTrack(_ partial: String) -> Bool { currentWord.hasPrefix(partial) }

  package func wordsPerMinute(after elapsed: Duration) -> Double {
    let minutes = Double(elapsed.components.seconds) / 60 + Double(elapsed.components.attoseconds) / 6e19
    guard minutes > 0 else { return 0 }
    return Double(correctCharacters) / 5 / minutes
  }

  package var accuracy: Double {
    guard !outcomes.isEmpty else { return 0 }
    return Double(outcomes.filter { $0 }.count) / Double(outcomes.count)
  }

  package struct Rank: Equatable, Sendable {
    package let title: String
    package let line: String
  }

  package static func rank(for wordsPerMinute: Double) -> Rank {
    switch wordsPerMinute {
    case ..<25: Rank(title: "Thumb wrestler", line: "Your thumbs are doing their best.")
    case ..<40: Rank(title: "Steady thumbs", line: "Right around the phone average.")
    case ..<55: Rank(title: "Speed thumbs", line: "Faster than most people on a phone.")
    case ..<75: Rank(title: "Thumb demon", line: "Seriously quick.")
    default: Rank(title: "Are you even human?", line: "We'd like to study your thumbs.")
    }
  }

  /// Plenty for a 30-second sprint even at 200 wpm.
  package static func randomWords(count: Int = 120) -> [String] {
    (0..<count).compactMap { _ in wordList.randomElement() }
  }

  static let wordList = """
    the of and to in is you that it he was for on are as with his they at be this have from or one had \
    by word but not what all were we when your can said there use an each which she do how their if will \
    up other about out many then them these so some her would make like him into time has look two more \
    write go see number no way could people my than first water been call who oil its now find long down \
    day did get come made may part over new sound take only little work know place year live me back give \
    most very after thing our just name good sentence man think say great where help through much before \
    line right too mean old any same tell boy follow came want show also around form three small set put \
    end does another well large must big even such because turn here why ask went men read need land \
    different home us move try kind hand picture again change off play spell air away animal house point \
    page letter mother answer found study still learn should world high every near add food between own \
    below country plant last school father keep tree never start city earth eye light thought head under \
    story saw left few while along might close something seem next hard open example begin life always \
    those both paper together got group often run important until children side feet car mile night walk
    """.split(whereSeparator: \.isWhitespace).map(String.init)
}

/// The typing speed time saved is measured against: the phone average until
/// the user takes the easter egg's sprint, then their latest result (how they
/// type now, not their best). Also keeps the best, for the results screen. In
/// the app's own defaults, beside `DictationStats`.
package nonisolated enum TypingSpeed {
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

  package struct Result: Equatable, Sendable {
    package let isBest: Bool
    package let setsSpeed: Bool
  }
}
