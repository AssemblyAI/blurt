import AssemblyAI
import BlurtEngine
import Foundation

/// Read-aloud's voice on AssemblyAI's streaming TTS (`SpeechClient`): the
/// engine's `SpeechSynthesizing`, with Blurt's key and User-Agent.
struct AssemblyAISpeechSynthesizer: SpeechSynthesizing {
  private let apiKeyProvider: @Sendable () -> String?
  private let client: SpeechClient

  var sampleRate: Int { SpeechClient.sampleRate }

  /// `transport` is the network seam: production streams through
  /// `URLSession`, and the tests play the service's side.
  init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transport: any SpeechTransport = URLSession.shared
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.client = SpeechClient(transport: transport, userAgent: UserAgent.current)
  }

  func speech(for text: String, voiceID: String = ReadAloudVoice.defaultID) -> AsyncThrowingStream<Data, any Error> {
    // Blank text needs no key: it finishes at once, as the client's own does.
    guard text.trimmedNonEmpty() != nil else {
      return AsyncThrowingStream { $0.finish() }
    }
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      return AsyncThrowingStream { $0.finish(throwing: BlurtError.apiKeyMissing) }
    }
    return client.speech(for: text, voiceID: voiceID, apiKey: apiKey)
  }
}
