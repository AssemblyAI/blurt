public import Foundation

/// The text-to-speech seam: read-aloud's voice (`SelectionSpeaker`,
/// `TextReader`). A provider package conforms (`BlurtAssemblyAI`'s
/// `AssemblyAISpeechSynthesizer`, over AssemblyAI's streaming TTS).
public protocol SpeechSynthesizing: Sendable {
  /// The sample rate of the PCM `speech(for:voiceID:)` yields: raw 16-bit
  /// little-endian mono, whole samples per chunk.
  var sampleRate: Int { get }

  /// The voices `speech(for:voiceID:)` can speak with, the default first, for
  /// the Settings picker and the voice sample's name.
  var voices: [ReadAloudVoice] { get }

  /// PCM chunks of `text` spoken by `voiceID`, in playback order, as they
  /// arrive. Nil, or an id `voices` doesn't hold, speaks the default voice: the
  /// setting is a plain string, and which ids the service accepts is the
  /// provider's to know. Blank text finishes at once without a request.
  /// Cancelling the consumer cancels the request, and reads as a
  /// `CancellationError`, never a failure. With no credentials the stream throws
  /// `BlurtError.apiKeyMissing`.
  func speech(for text: String, voiceID: String?) -> AsyncThrowingStream<Data, any Error>

  /// `text` cut at sentence ends into pieces of at most `maxCharacters`, for a
  /// paragraph too long for one request (`ListeningChunks`). Where the voice
  /// reads a cut best is the provider's to say: a piece that starts or ends
  /// mid-sentence is spoken with the wrong intonation at the cut.
  func sentences(of text: String, maxCharacters: Int) -> [String]
}
