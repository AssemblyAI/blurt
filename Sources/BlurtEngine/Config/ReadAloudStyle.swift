/// How one read-aloud press should sound: the voice, the playback rate, and
/// whether the text is rewritten for listening before it is spoken
/// (`ReadAloudLLM.rewriteForListening`).
/// `ReadAloudStyleStore.style` resolves it from the settings at each press.
public struct ReadAloudStyle: Sendable, Equatable {
  /// Read-aloud untouched: the default voice at natural pace, the selection verbatim.
  public static let standard = Self(rate: 1, skipsJargon: false)

  /// Playback speed, where 1 is the voice's natural pace. Pitch is held (see
  /// `StreamingPCMPlayer`), so 2 sounds like someone talking fast, not a chipmunk.
  public let rate: Double
  /// Leave out what sounds like noise read aloud: code, file paths, links,
  /// email addresses, long numbers.
  public let skipsJargon: Bool
  /// The chosen voice's id (`ReadAloudVoice.id`), or nil for the provider's
  /// default. Passed to the provider as stored; one it doesn't know speaks the
  /// default (`SpeechSynthesizing.speech(for:voiceID:)`).
  public let voiceID: String?

  /// The same voice and speed, reading the text as given: for text already
  /// written to be heard (an answer, a voice sample).
  public var verbatim: Self { Self(rate: rate, skipsJargon: false, voiceID: voiceID) }

  public init(rate: Double, skipsJargon: Bool, voiceID: String? = nil) {
    self.rate = rate
    self.skipsJargon = skipsJargon
    self.voiceID = voiceID
  }
}
