public import Foundation

/// Persists how read-aloud sounds in `UserDefaults`: its voice, its playback
/// speed and whether it skips jargon, three independent settings. Untouched, it
/// reads in the default voice at natural pace, skipping jargon: code, paths and
/// long numbers read aloud are mostly noise. That sends the selection to the LLM
/// Gateway before reading it, which the Read Aloud footer says while it's on,
/// and a failed rewrite falls back to the selection verbatim. The Keys tab's Read Aloud section writes every slot through
/// `@AppStorage`, so this store is read-only.
public struct ReadAloudStyleStore {
  /// UserDefaults keys, public so the Settings view can bind them directly.
  public static var speedDefaultsKey: String { DefaultsKey.readAloudSpeed.key }
  /// The "Skip jargon" switch's key.
  public static var skipsJargonDefaultsKey: String { DefaultsKey.readAloudSkipsJargon.key }
  /// The chosen voice's key.
  public static var voiceDefaultsKey: String { DefaultsKey.readAloudVoice.key }

  /// What an unset slot reads as. Public so the Settings view's `@AppStorage`
  /// defaults come from here and can't disagree with the press (the trap
  /// `EnhancedTranscriptsStore.defaultValue` records).
  public static let defaultSpeed = ReadAloudStyle.standard.rate
  /// On, unlike `ReadAloudStyle.standard` (the verbatim style a caller gets
  /// when it names none).
  public static let defaultSkipsJargon = true
  /// The speeds the Settings picker offers. Capped at 3: past that the
  /// time-domain pitch correction smears syllables together.
  public static let speedChoices = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

  private let defaults: UserDefaults

  /// The style the next press reads with.
  public var style: ReadAloudStyle {
    ReadAloudStyle(
      rate: speed,
      skipsJargon: skipsJargon,
      voiceID: defaults.string(forKey: Self.voiceDefaultsKey).trimmedNonEmpty()
    )
  }

  /// The stored speed, snapped to what the picker offers. The slot is a plain
  /// number anyone can `defaults write`, and the renderer accepts any rate, so
  /// a value off the list (or not a number at all) is not passed through.
  private var speed: Double {
    guard let stored = defaults.object(forKey: Self.speedDefaultsKey) as? Double else {
      return Self.defaultSpeed
    }
    return Self.nearestChoice(to: stored)
  }

  private var skipsJargon: Bool {
    defaults.object(forKey: Self.skipsJargonDefaultsKey) as? Bool ?? Self.defaultSkipsJargon
  }

  /// A store over the standard defaults, as the app reads them.
  public init() {
    self.init(defaults: .standard)
  }

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// The entry in `speedChoices` closest to `speed`, or the default for a
  /// non-number. The press reads through this, and so does the picker's
  /// binding, so an off-list value shows as the speed that will actually play
  /// rather than as a blank pop-up.
  public static func nearestChoice(to speed: Double) -> Double {
    guard speed.isFinite else {
      return defaultSpeed
    }
    return speedChoices.min { abs($0 - speed) < abs($1 - speed) } ?? defaultSpeed
  }

  /// The picker's label for a speed: "2×", "1.25×". Localized decimals, so a
  /// German Mac reads "1,5×".
  public static func speedLabel(_ speed: Double, locale: Locale = .current) -> String {
    speed.formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + "×"
  }
}
