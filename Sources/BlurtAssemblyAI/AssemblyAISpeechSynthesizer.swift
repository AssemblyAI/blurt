import AssemblyAI
import BlurtEngine
import Foundation

/// Read-aloud's voice on AssemblyAI's streaming TTS (`SpeechClient`): the
/// engine's `SpeechSynthesizing`, with Blurt's key and User-Agent.
struct AssemblyAISpeechSynthesizer: SpeechSynthesizing {
  private let apiKeyProvider: @Sendable () -> String?
  private let client: SpeechClient

  var sampleRate: Int { SpeechClient.sampleRate }

  var voices: [ReadAloudVoice] { ReadAloudVoice.assemblyAI }

  /// `transport` is the network seam: production streams through
  /// `URLSession`, and the tests play the service's side.
  init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transport: any SpeechTransport = URLSession.shared
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.client = SpeechClient(transport: transport, userAgent: UserAgent.current)
  }

  /// Nil, or an id the catalog doesn't hold, speaks the default voice
  /// (`ReadAloudVoice.assemblyAIVoice(id:)`): the service refuses a whole read for an
  /// id it doesn't know (`3012`).
  func speech(for text: String, voiceID: String? = nil) -> AsyncThrowingStream<Data, any Error> {
    // Blank text needs no key: it finishes at once, as the client's own does.
    guard text.trimmedNonEmpty() != nil else {
      return AsyncThrowingStream { $0.finish() }
    }
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      return AsyncThrowingStream { $0.finish(throwing: BlurtError.apiKeyMissing) }
    }
    return client.speech(for: text, voiceID: ReadAloudVoice.assemblyAIVoice(id: voiceID).id, apiKey: apiKey)
  }

  /// AssemblyAI's measured rule for where its voice reads a cut best
  /// (`SpeechSegmenter`).
  func sentences(of text: String, maxCharacters: Int) -> [String] {
    SpeechSegmenter.segments(of: text, maxCharacters: maxCharacters)
  }
}
