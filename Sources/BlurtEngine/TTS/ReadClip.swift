#if os(macOS)
  public import Foundation

  /// One finished read: what was read aloud, the audio as it played, and —
  /// for an answer — the spoken request it replied to. The app keeps it in its
  /// history (`SavedTranscript.Kind.readAloud`), findable and playable again.
  ///
  /// Where its audio is written lives beside it: `ReadClipSink`,
  /// `ClipRecordingSink` and `WAVWriter`.
  public struct ReadClip: Sendable, Equatable {
    /// The text read: the selection, or the answer.
    public let text: String
    /// The audio, a 16-bit mono WAV at the voice's sample rate. Holds what
    /// was synthesized, which for a read stopped early is where it stopped.
    public let audioURL: URL
    /// The request an answer replied to; nil for a plain read.
    public let request: String?
  }
#endif
