public import Foundation

/// The text-to-speech seam: read-aloud's voice (`SelectionSpeaker`,
/// `TextReader`). A provider package conforms (`BlurtAssemblyAI`'s
/// `AssemblyAISpeechSynthesizer`, over AssemblyAI's streaming TTS).
public protocol SpeechSynthesizing: Sendable {
  /// The sample rate of the PCM `speech(for:voiceID:)` yields: raw 16-bit
  /// little-endian mono, whole samples per chunk.
  var sampleRate: Int { get }

  /// PCM chunks of `text` spoken by `voiceID`, in playback order, as they
  /// arrive. Blank text finishes at once without a request. Cancelling the
  /// consumer cancels the request, and reads as a `CancellationError`, never a
  /// failure. With no credentials the stream throws `BlurtError.apiKeyMissing`.
  func speech(for text: String, voiceID: String) -> AsyncThrowingStream<Data, any Error>
}
